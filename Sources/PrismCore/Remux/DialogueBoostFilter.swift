import Foundation
import Libavfilter
import Libavutil

/// How hard a dialogue-boost rendition favours the centre channel.
///
/// The boost is implemented as *attenuation of everything except the centre*,
/// never as gain on the centre itself: decoded floats routinely sit near full
/// scale, so multiplying the centre up would clip exactly on the loud dialogue
/// the feature exists to rescue, while pulling the bed down is clip-safe by
/// construction and changes the same ratio.
public enum DialogueBoostLevel: String, CaseIterable, Sendable, Hashable {
    /// Background −6 dB relative to dialogue.
    case medium
    /// Background −12 dB relative to dialogue.
    case high

    /// Linear gain applied to every non-centre channel (LFE included — rumble
    /// is background too).
    var backgroundGain: Double {
        switch self {
        case .medium: return 0.5
        case .high: return 0.25
        }
    }

    /// What the rendition's `NAME` appends to the base track's name. This is
    /// user-facing text in AVKit's own track picker, so it stays short; a host
    /// building its own UI should match renditions by the
    /// `public.accessibility.enhances-speech-intelligibility` characteristic
    /// (or `PrismCoreSession.dialogueBoostRenditions`) instead of parsing it.
    public var renditionNameSuffix: String {
        switch self {
        case .medium: return "Dialogue Boost"
        case .high: return "Dialogue Boost+"
        }
    }
}

/// One produced dialogue-boost rendition, as the session reports it to the
/// host: which level it carries and the exact `NAME` the master declares —
/// which is the `title` metadata item (`commonMetadata`, identifier
/// `m3u8/NAME`) of the matching `AVMediaSelectionOption`, not its `displayName`
/// (AVFoundation makes that from the language; see `AudioRenditionInfo`).
public struct DialogueBoostRendition: Sendable, Equatable {
    public let level: DialogueBoostLevel
    public let name: String
}

/// The HLS `CHARACTERISTICS` value a dialogue-boost rendition declares —
/// AVFoundation surfaces it as `AVMediaCharacteristic
/// .enhancesSpeechIntelligibility`, which is the robust way for a host to find
/// the boost options in a selection group without matching display names.
let dialogueBoostCharacteristic = "public.accessibility.enhances-speech-intelligibility"

/// An avfilter graph that pulls dialogue forward in decoded audio:
/// `abuffer → pan → abuffersink`, where the `pan` keeps the source layout and
/// attenuates every channel except the front centre.
///
/// Sits between `AudioBridge`'s decoder and its resampler, so the bridge's
/// timestamp anchoring and FIFO framing stay untouched: frames go in and come
/// out in the same time base (the source stream's) with the same sample count.
///
/// Centre-channel sources only, on purpose. Stereo has no channel that *is*
/// the dialogue — separating speech there needs FFmpeg's `dialoguenhance`
/// filter, which the MPVKit builds don't compile (checked by symbol, not
/// assumed — see AGENTS.md on configure's silent filter drops). When a build
/// ships it, the stereo path belongs here, behind the same availability read.
///
/// The graph is built lazily from the first decoded frame and rebuilt on a
/// mid-stream format change, for the same reason the bridge's resampler is:
/// `codecpar` is a claim, and a dca/mlp stream frequently resolves its real
/// layout only once a frame has been decoded. A frame whose layout turns out
/// to have no centre (or channels the layout can't name) passes through
/// unfiltered rather than failing the rendition — the rendition then
/// duplicates the base track, which is useless but playable, and the
/// eligibility precheck in `AudioBridge` makes the case rare.
final class DialogueBoostFilter {

    enum Failure: Error, CustomStringConvertible {
        case filterMissing(String)
        case allocationFailed(String)

        var description: String {
            switch self {
            case .filterMissing(let name):
                return "FFmpeg build has no '\(name)' filter (check config_components.h)"
            case .allocationFailed(let what):
                return "\(what) allocation failed"
            }
        }
    }

    /// Whether this FFmpeg build can run the boost graph at all. Read at
    /// runtime from the filter registry rather than assumed from the version:
    /// FFmpeg's configure drops filters with unmet dependencies silently.
    static var isAvailable: Bool {
        avfilter_get_by_name("pan") != nil
            && avfilter_get_by_name("abuffer") != nil
            && avfilter_get_by_name("abuffersink") != nil
    }

    /// Whether a layout has a dialogue channel to favour: a front centre among
    /// at least three channels, every one of them nameable (the `pan` spec is
    /// written in channel names, so an unnameable custom layout can't be
    /// expressed honestly).
    static func layoutIsEligible(_ layout: inout AVChannelLayout) -> Bool {
        guard layout.nb_channels >= 3, av_channel_layout_check(&layout) != 0 else { return false }
        guard av_channel_layout_index_from_channel(&layout, AV_CHAN_FRONT_CENTER) >= 0 else {
            return false
        }
        return channelNames(of: &layout) != nil
    }

    let level: DialogueBoostLevel
    /// Time base the pushed frames' PTS are in (the source stream's); the
    /// graph is told it so emitted frames keep it.
    private let timeBase: AVRational

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private var filteredFrame: UnsafeMutablePointer<AVFrame>?

    /// The input side the graph is currently built for — same per-frame
    /// re-derivation as the bridge's resampler, and for the same reason.
    private var inFormat = AV_SAMPLE_FMT_NONE
    private var inRate: Int32 = 0
    private var inLayout = AVChannelLayout()
    /// The current configuration turned out to have nothing to boost; frames
    /// flow through untouched until the format changes again.
    private var passthrough = false

    typealias EmitFrame = (UnsafeMutablePointer<AVFrame>) throws -> Void

    init(level: DialogueBoostLevel, timeBase: AVRational) {
        self.level = level
        self.timeBase = timeBase
    }

    deinit {
        close()
    }

    func close() {
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        source = nil
        sink = nil
        av_frame_free(&filteredFrame)
        av_channel_layout_uninit(&inLayout)
        inFormat = AV_SAMPLE_FMT_NONE
        inRate = 0
    }

    /// Drop whatever the graph buffers without tearing the filter down: the
    /// next frame rebuilds the graph (the `graph == nil` path of
    /// `reconfigureIfNeeded`), so a seek's stale frames never reach the
    /// encoder and the eligibility verdict is re-derived from real input.
    func reset() {
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        source = nil
        sink = nil
        passthrough = false
        inFormat = AV_SAMPLE_FMT_NONE
        inRate = 0
    }

    /// Run one decoded frame through the graph. Consumes the frame's
    /// references on the filtered path (like `av_buffersrc_add_frame`); on the
    /// passthrough path the frame is handed to `emit` untouched.
    func push(_ frame: UnsafeMutablePointer<AVFrame>, emit: EmitFrame) throws {
        try reconfigureIfNeeded(for: frame)
        if passthrough {
            try emit(frame)
            return
        }
        guard let source else { return }
        try FFmpegError.check(
            av_buffersrc_add_frame(source, frame),
            "av_buffersrc_add_frame(dialogue boost)"
        )
        try drain(emit: emit)
    }

    /// End of stream: flush whatever the graph still buffers. `pan` is
    /// sample-for-sample so this is usually empty, but the graph owes the
    /// declaration either way.
    func flush(emit: EmitFrame) throws {
        guard !passthrough, let source else { return }
        _ = av_buffersrc_add_frame(source, nil)
        try drain(emit: emit)
    }

    private func drain(emit: EmitFrame) throws {
        guard let sink, let filteredFrame else { return }
        while true {
            let result = av_buffersink_get_frame(sink, filteredFrame)
            if result == swift_AVERROR(EAGAIN) || result == swift_AVERROR_EOF() { return }
            try FFmpegError.check(result, "av_buffersink_get_frame(dialogue boost)")
            defer { av_frame_unref(filteredFrame) }
            try emit(filteredFrame)
        }
    }

    // MARK: - Graph construction

    private func reconfigureIfNeeded(for frame: UnsafeMutablePointer<AVFrame>) throws {
        let frameFormat = AVSampleFormat(rawValue: frame.pointee.format)
        let matches = (graph != nil || passthrough)
            && frameFormat == inFormat
            && frame.pointee.sample_rate == inRate
            && av_channel_layout_compare(&frame.pointee.ch_layout, &inLayout) == 0
        if matches { return }

        // A rebuild drops what the old graph buffered — first frame or a
        // genuine mid-stream format change, where a sub-millisecond seam beats
        // a rebuilt-and-resynced pipeline (the resampler makes the same call).
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        source = nil
        sink = nil
        passthrough = false

        inFormat = frameFormat
        inRate = frame.pointee.sample_rate
        av_channel_layout_uninit(&inLayout)
        try FFmpegError.check(
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout),
            "av_channel_layout_copy(boost input)"
        )

        guard Self.layoutIsEligible(&inLayout), let names = Self.channelNames(of: &inLayout) else {
            passthrough = true
            return
        }
        try buildGraph(names: names)
    }

    private func buildGraph(names: [String]) throws {
        guard let graph = avfilter_graph_alloc() else {
            throw Failure.allocationFailed("filter graph")
        }
        self.graph = graph

        guard let formatName = av_get_sample_fmt_name(inFormat).map({ String(cString: $0) })
        else { passthrough = true; return }
        let layoutSpec = names.joined(separator: "+")
        let sourceArgs = """
            time_base=\(timeBase.num)/\(timeBase.den):\
            sample_rate=\(inRate):\
            sample_fmt=\(formatName):\
            channel_layout=\(layoutSpec)
            """

        var source: UnsafeMutablePointer<AVFilterContext>?
        try FFmpegError.check(
            avfilter_graph_create_filter(
                &source, avfilter_get_by_name("abuffer"), "in", sourceArgs, nil, graph
            ),
            "avfilter_graph_create_filter(abuffer)"
        )
        var sink: UnsafeMutablePointer<AVFilterContext>?
        try FFmpegError.check(
            avfilter_graph_create_filter(
                &sink, avfilter_get_by_name("abuffersink"), "out", nil, nil, graph
            ),
            "avfilter_graph_create_filter(abuffersink)"
        )

        // Same layout out as in; centre at unity, everything else attenuated.
        // Written in channel names ("FC=FC", "FL=0.5*FL"), which is why the
        // eligibility check demanded nameable channels.
        let gain = String(format: "%.4f", level.backgroundGain)
        let mappings = names.map { name in
            name == "FC" ? "FC=FC" : "\(name)=\(gain)*\(name)"
        }
        let panArgs = ([layoutSpec] + mappings).joined(separator: "|")
        var pan: UnsafeMutablePointer<AVFilterContext>?
        guard let panFilter = avfilter_get_by_name("pan") else {
            throw Failure.filterMissing("pan")
        }
        try FFmpegError.check(
            avfilter_graph_create_filter(&pan, panFilter, "boost", panArgs, nil, graph),
            "avfilter_graph_create_filter(pan)"
        )

        try FFmpegError.check(avfilter_link(source, 0, pan, 0), "avfilter_link(in→pan)")
        try FFmpegError.check(avfilter_link(pan, 0, sink, 0), "avfilter_link(pan→out)")
        try FFmpegError.check(avfilter_graph_config(graph, nil), "avfilter_graph_config(boost)")

        guard let filtered = av_frame_alloc() else {
            throw Failure.allocationFailed("filtered frame")
        }
        self.source = source
        self.sink = sink
        self.filteredFrame = filtered
    }

    /// Every channel's canonical short name ("FL", "FC", …), in layout order —
    /// or nil when any channel has none, which is the signal the layout can't
    /// be expressed in a `pan` spec.
    private static func channelNames(of layout: inout AVChannelLayout) -> [String]? {
        var names: [String] = []
        names.reserveCapacity(Int(layout.nb_channels))
        for index in 0..<layout.nb_channels {
            let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
            guard channel != AV_CHAN_NONE else { return nil }
            var buffer = [CChar](repeating: 0, count: 32)
            guard av_channel_name(&buffer, buffer.count, channel) > 0 else { return nil }
            let name = String(cString: buffer)
            // "USR…"/"?" placeholders mean libavutil itself can't name it.
            guard !name.isEmpty, !name.hasPrefix("USR"), name != "?" else { return nil }
            names.append(name)
        }
        return names
    }
}
