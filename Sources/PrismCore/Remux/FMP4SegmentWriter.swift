import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// fMP4 segmentation over FFmpeg's `mp4` muxer with a custom AVIO sink.
///
/// Exists because MPVKit's libavformat is built without the `hls` muxer
/// (mpv only demuxes; 23 muxers survive the trim, `ff_hls_muxer` is not one
/// of them — discovered the moment the first integration test ran). Rather
/// than forking the FFmpeg build for it, we segment ourselves:
///
/// - `movflags delay_moov+frag_custom+default_base_moof`: the first null
///   flush after packets started arriving emits `ftyp+moov` alone — that IS
///   the HLS init segment (`flushInitSegment()`) — and every later
///   `av_write_frame(ctx, nil)` flush emits one `moof+mdat` fragment, which
///   IS one HLS media segment.
/// - The custom AVIO write callback collects the muxer's bytes into the
///   current segment buffer; the remuxer decides the cut points (video
///   keyframes at/after the boundary) and asks for the flush.
///
/// This is also the layout phase 5 needs anyway: a demand-driven producer
/// must own its cuts, which the `hls` muxer never exposes.
final class FMP4SegmentWriter {

    /// Box passed through the AVIO opaque pointer — collects muxer output.
    final class Sink {
        var buffer = Data()
    }

    private var output: UnsafeMutablePointer<AVFormatContext>?
    private var avio: UnsafeMutablePointer<AVIOContext>?
    private let sink = Sink()
    var audioDelaySeconds: Double = 0
    /// Where this writer's timestamp repairs are tallied; outlives the writer.
    var timestampRepairs: TimestampRepairLedger?
    /// One per output stream, created on its first packet. Owned by the writer
    /// so that a re-anchor, which always builds a fresh writer, starts every
    /// stream over: the restarted fragment's tfdt carries absolute time, and a
    /// sanitizer still holding the old position's last DTS would clamp the
    /// first packets after a backward seek up to it.
    private var sanitizers: [Int: TimestampSanitizer] = [:]
    /// One per output stream that reorders pictures (`video_delay > 0`): holds
    /// the packets such a stream comes without a DTS (its first ones after a
    /// seek) until the first real one arrives and numbers them from it — see
    /// `LeadingDTSBackfill`. A writer is rebuilt at every re-anchor, so nothing
    /// is carried across a seek.
    private var leadingDTS: [Int: LeadingDTSBackfill<UnsafeMutablePointer<AVPacket>>] = [:]
    private var ioBuffer: UnsafeMutableRawPointer?

    /// input stream index → output stream index
    private(set) var streamMap: [Int: Int32] = [:]

    deinit {
        // Normal teardown runs `finish()`; this is the error-path backstop.
        for index in Array(leadingDTS.keys) {
            for release in leadingDTS[index]?.drain() ?? [] { Self.free(release) }
        }
        if let output {
            avformat_free_context(output)
        }
        if let avio {
            av_free(avio.pointee.buffer)
            avio_context_free(&self.avio)
        }
    }

    /// One output stream to create: mirror the input stream's parameters
    /// (`configure == nil`), or let the caller fill them (a bridged stream
    /// describes its ENCODER, not the source — and it must do so before
    /// `write_header`; the sample entries themselves are completed from real
    /// packets at moov-flush time, which is why the moov is deferred).
    struct StreamPlan {
        let inputIndex: Int32
        let configure: ((UnsafeMutablePointer<AVStream>) throws -> Void)?
        /// ISO-639 tag for the output track's `mdhd`, when the source had one.
        /// A rendition's language is carried by the master playlist's
        /// `LANGUAGE` attribute, so this is not what AVPlayer selects on — it
        /// keeps the media itself self-describing for anything that reads the
        /// trak instead of the manifest.
        let language: String?

        init(
            inputIndex: Int32,
            language: String? = nil,
            configure: ((UnsafeMutablePointer<AVStream>) throws -> Void)? = nil
        ) {
            self.inputIndex = inputIndex
            self.language = language
            self.configure = configure
        }
    }

    /// Allocate the mp4 muxer, create the planned streams, and write the
    /// header. With `delay_moov` the header emits nothing — the init segment
    /// arrives from `flushInitSegment()` once packets have been fed.
    func open(
        input: UnsafeMutablePointer<AVFormatContext>,
        plan: [StreamPlan],
        restart: Bool = false
    ) throws -> Data {
        var outputOpt: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(
            avformat_alloc_output_context2(&outputOpt, nil, "mp4", nil),
            "avformat_alloc_output_context2(mp4)"
        )
        guard let output = outputOpt else {
            throw FFmpegError(code: -1, operation: "avformat_alloc_output_context2(mp4)")
        }
        self.output = output

        for entry in plan {
            let inStream = input.pointee.streams[Int(entry.inputIndex)]!
            guard let outStream = avformat_new_stream(output, nil) else {
                throw FFmpegError(code: -1, operation: "avformat_new_stream")
            }
            if let configure = entry.configure {
                try configure(outStream)
            } else {
                try FFmpegError.check(
                    avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar),
                    "avcodec_parameters_copy"
                )
                outStream.pointee.codecpar.pointee.codec_tag = 0
            }
            if outStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                // codecpar carries only the BITSTREAM aspect ratio; the
                // container-level one (an MKV's DisplayWidth/Height — how
                // anamorphic DVD rips are usually tagged) lives on the
                // stream and is what movenc's `pasp`/`tkhd` want. Same
                // precedence as ffmpeg's own streamcopy: stream over
                // codecpar, written back to both. Outside the mirror branch
                // on purpose — the video stream always arrives through a
                // `configure`, which copies codecpar and would drop the
                // stream-level value the same way.
                let streamSAR = inStream.pointee.sample_aspect_ratio
                let sar = streamSAR.num != 0
                    ? streamSAR
                    : outStream.pointee.codecpar.pointee.sample_aspect_ratio
                outStream.pointee.sample_aspect_ratio = sar
                outStream.pointee.codecpar.pointee.sample_aspect_ratio = sar
            }
            if let language = entry.language, !language.isEmpty {
                av_dict_set(&outStream.pointee.metadata, "language", language, 0)
            }
            streamMap[Int(entry.inputIndex)] = outStream.pointee.index
            if outStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               outStream.pointee.codecpar.pointee.video_delay > 0 {
                leadingDTS[Int(outStream.pointee.index)] = LeadingDTSBackfill()
            }
        }

        // Custom AVIO: the muxer writes, the sink collects. 64 KiB transfer
        // buffer (av_malloc'd — AVIO may av_realloc it internally).
        let bufferSize: Int32 = 64 * 1024
        guard let raw = av_malloc(Int(bufferSize)) else {
            throw FFmpegError(code: -1, operation: "av_malloc(avio buffer)")
        }
        ioBuffer = raw
        let opaque = Unmanaged.passUnretained(sink).toOpaque()
        avio = avio_alloc_context(
            raw.assumingMemoryBound(to: UInt8.self),
            bufferSize,
            1,                    // write_flag
            opaque,
            nil,                  // read
            { opaque, data, size in
                guard let opaque, let data, size > 0 else { return size }
                let sink = Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue()
                sink.buffer.append(data, count: Int(size))
                return size
            },
            nil                   // seek — absent on purpose: a nil seek is
                                  // what tells movenc the output is a stream,
                                  // which fragmented MP4 handles by design.
        )
        guard avio != nil else { throw FFmpegError(code: -1, operation: "avio_alloc_context") }
        output.pointee.pb = avio

        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        // delay_moov     → the moov (= HLS init segment) is written by the
        //                  FIRST null flush after packets started arriving,
        //                  not at header time. Mandatory for bridged/copied
        //                  EAC3: movenc builds the `dec3` sample entry from
        //                  parsed packets and refuses an up-front moov with
        //                  "Cannot write moov atom before EAC3 packets
        //                  parsed" (found by the HEVC+EAC3 fixture — the
        //                  moov has to wait until the packets did arrive).
        // frag_custom    → fragments cut exactly when we flush, nowhere else.
        // default_base_moof → offsets relative to the moof, which is what
        //                  HLS-fMP4 players (AVPlayer included) require of
        //                  segments served as separate resources.
        // frag_discont on RESTART muxers: a fresh movenc zero-bases its
        // timeline by default, so a restart-produced segment would carry
        // tfdt=0 while the playlist places it mid-presentation — an implicit
        // discontinuity AVPlayer papers over for plain playback but that
        // detaches ancillary consumers. With frag_discont (+ negative-ts
        // passthrough below) tfdt carries the producer's ABSOLUTE
        // timestamps, so a demand-produced segment is placed exactly where
        // the plan promised it.
        let flags = restart
            ? "+delay_moov+frag_custom+default_base_moof+frag_discont"
            : "+delay_moov+frag_custom+default_base_moof"
        av_dict_set(&options, "movflags", flags, 0)
        av_dict_set(&options, "avoid_negative_ts", "disabled", 0)
        // Without this movenc refuses to write the Dolby Vision configuration
        // box and says so: "Not writing 'dvcC'/'dvvC' box. Requires -strict
        // unofficial." The boxes are Dolby's specification rather than ISO's,
        // hence the gate — but they are also the only thing that tells
        // AVFoundation a track is Dolby Vision, so a DV source without them is
        // just HDR10 with extra bytes. Found on a real Profile 7 file; no
        // synthetic fixture carries DV, so nothing here could have caught it.
        av_dict_set(&options, "strict", "unofficial", 0)

        try FFmpegError.check(
            avformat_write_header(output, &options),
            "avformat_write_header(mp4)"
        )
        avio_flush(avio)
        return takeBufferedBytes()
    }

    /// Whether the deferred moov has been emitted yet.
    private(set) var moovWritten = false

    var context: UnsafeMutablePointer<AVFormatContext>? { output }

    /// Mux one packet, already rescaled onto its output stream's time base.
    ///
    /// Every stream-copied and bridged packet of both output shapes comes
    /// through here, which is why the timestamp repair lives here and not in
    /// each caller: a path that skipped it would fail the whole remux on the
    /// first bad DTS.
    func write(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        // A stream that reorders pictures has no DTS for its first packets
        // after a seek: they wait here for the first real one, which numbers
        // them (`LeadingDTSBackfill`), and only then are repaired and muxed.
        let index = Int(packet.pointee.stream_index)
        if leadingDTS[index]?.isSettled == false {
            try writeNumberingLeadingPackets(packet, streamIndex: index)
            return
        }
        try repairAndMux(packet)
    }

    /// Repair the packet's timestamps, apply the audio delay, and hand it to the
    /// muxer.
    private func repairAndMux(_ packet: UnsafeMutablePointer<AVPacket>) throws {
        guard let output else { return }
        let index = Int(packet.pointee.stream_index)
        if index >= 0, index < Int(output.pointee.nb_streams), let stream = output.pointee.streams[index] {
            // Before the audio delay shift, so the delay's drop-below-zero
            // check sees timestamps the muxer would accept.
            var sanitizer = sanitizers[index]
                ?? TimestampSanitizer(reordersFrames: stream.pointee.codecpar.pointee.video_delay > 0)
            sanitizer.sanitize(packet, recordingInto: timestampRepairs)
            sanitizers[index] = sanitizer
        }
        if audioDelaySeconds != 0, index >= 0, index < Int(output.pointee.nb_streams),
           let stream = output.pointee.streams[index],
           stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            let ticks = Int64((AudioDelay.normalized(audioDelaySeconds) / av_q2d(stream.pointee.time_base)).rounded())
            // `avoid_negative_ts` is disabled (tfdt must carry absolute time
            // on restart), so a negative delay must not push a packet below
            // zero: movenc writes tfdt as an UNSIGNED 64-bit field and a
            // negative dts would wrap. Audio that would present before the
            // timeline's origin is inaudible anyway (a priming packet
            // included) — dropped only when it is the shift that put it there;
            // a zero or positive delay leaves a source's own timestamps alone.
            let pts = packet.pointee.pts, dts = packet.pointee.dts
            if ticks < 0,
               (pts != swift_AV_NOPTS_VALUE() && pts + ticks < 0)
                || (dts != swift_AV_NOPTS_VALUE() && dts + ticks < 0) {
                return
            }
            if pts != swift_AV_NOPTS_VALUE() { packet.pointee.pts = pts + ticks }
            if dts != swift_AV_NOPTS_VALUE() { packet.pointee.dts = dts + ticks }
        }
        try FFmpegError.check(
            av_interleaved_write_frame(output, packet),
            "av_interleaved_write_frame"
        )
    }

    private typealias Release = LeadingDTSBackfill<UnsafeMutablePointer<AVPacket>>.Release

    /// Frees the packet of a release that was held (the one in hand belongs to
    /// the caller).
    private static func free(_ release: Release) {
        guard case .held(let held) = release.item else { return }
        var owned: UnsafeMutablePointer<AVPacket>? = held
        av_packet_free(&owned)
    }

    /// The packet either waits (a copy of it is kept) for the first real DTS of
    /// its stream, or arrives with that DTS and releases the ones that waited,
    /// numbered from it.
    private func writeNumberingLeadingPackets(
        _ packet: UnsafeMutablePointer<AVPacket>,
        streamIndex index: Int
    ) throws {
        let dts = packet.pointee.dts
        let pts = packet.pointee.pts
        let releases = try leadingDTS[index]!.admit(
            dts: dts == swift_AV_NOPTS_VALUE() ? nil : dts,
            pts: pts == swift_AV_NOPTS_VALUE() ? nil : pts,
            duration: packet.pointee.duration,
            hold: {
                // A reference to the same buffer: the caller unreferences its
                // own packet as soon as this call returns.
                guard let copy = av_packet_clone(packet) else {
                    throw FFmpegError(code: -1, operation: "av_packet_clone")
                }
                return copy
            }
        )
        try mux(releases, current: packet)
    }

    /// Writes released packets in order, giving each the DTS it was assigned.
    /// The held ones are owned here and freed whatever happens.
    private func mux(_ releases: [Release], current: UnsafeMutablePointer<AVPacket>?) throws {
        var handled = 0
        defer {
            for release in releases[handled...] { Self.free(release) }
        }
        for release in releases {
            handled += 1
            defer { Self.free(release) }
            switch release.item {
            case .held(let held):
                if let dts = release.dts { held.pointee.dts = dts }
                try repairAndMux(held)
            case .current:
                guard let current else { continue }
                if let dts = release.dts { current.pointee.dts = dts }
                try repairAndMux(current)
            }
        }
    }

    /// Writes out whatever the backfill still holds, with the timestamps those
    /// packets have: a fragment or the stream ends before a stream's first real
    /// DTS came, and a held packet must not be lost to that.
    private func releaseHeldPackets() throws {
        for index in leadingDTS.keys.sorted() {
            guard let releases = leadingDTS[index]?.drain(), !releases.isEmpty else { continue }
            try mux(releases, current: nil)
        }
    }

    /// Flush the current fragment. Returns the init segment too when this is
    /// the FIRST cut: draining the interleave queue is what actually delivers
    /// packets into movenc (feeding `av_interleaved_write_frame` only queues
    /// them), and codec boxes like `dec3` are built from DELIVERED packets —
    /// flushing the moov any earlier wrote a zero-size `stsd` entry for EAC3
    /// (found by the HEVC+EAC3 fixture: the init probed as "invalid size 0 in
    /// stsd"). Under `delay_moov` the first null flush emits the moov alone
    /// and keeps queued samples; the second closes the fragment.
    func cutSegment() throws -> (initSegment: Data?, media: Data) {
        guard let output, let avio else { return (nil, Data()) }
        try releaseHeldPackets()
        // Drain the interleave queue into movenc first.
        try FFmpegError.check(av_interleaved_write_frame(output, nil), "flush interleave queue")

        var initSegment: Data?
        if !moovWritten {
            try FFmpegError.check(av_write_frame(output, nil), "av_write_frame(flush moov)")
            avio_flush(avio)
            initSegment = takeBufferedBytes()
            moovWritten = true
        }

        try FFmpegError.check(av_write_frame(output, nil), "av_write_frame(flush fragment)")
        avio_flush(avio)
        return (initSegment, takeBufferedBytes())
    }

    /// Write the trailer and return any final bytes.
    func finish() throws -> Data {
        guard let output, let avio else { return Data() }
        try releaseHeldPackets()
        try FFmpegError.check(av_write_trailer(output), "av_write_trailer")
        avio_flush(avio)
        let tail = takeBufferedBytes()
        avformat_free_context(output)
        self.output = nil
        av_free(avio.pointee.buffer)
        avio_context_free(&self.avio)
        self.avio = nil
        ioBuffer = nil
        return tail
    }

    private func takeBufferedBytes() -> Data {
        let bytes = sink.buffer
        sink.buffer = Data()
        // The next segment is about the size of this one, so reserve it up
        // front: a fragment's worth of 64 KiB avio writes was regrowing the
        // sink a dozen times per segment.
        sink.buffer.reserveCapacity(bytes.count)
        return bytes
    }
}
