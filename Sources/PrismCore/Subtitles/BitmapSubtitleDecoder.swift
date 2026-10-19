import Foundation
import CoreGraphics
import Libavcodec
import Libavutil

/// Decodes one bitmap subtitle stream (PGS / DVB / DVD) into timed
/// *compositions* — a set of palettized rectangles to show, or a clear.
///
/// Bitmap subtitles are event streams, not cue streams: a packet either
/// presents a composition (one or more palettized rects) or presents nothing,
/// which is the "take it down" event. Whoever consumes this therefore owns a
/// pending-cue lifecycle; this type only turns packets into pixels and times.
///
/// Two consumers read the same decode, and they want different pixels:
///
/// - The OCR rendition wants one picture per composition, composited onto
///   black inside the common bounding box — light glyphs on a dark ground is
///   what a recognizer (and a human looking at a debug dump) reads best.
///   `Event.image`.
/// - The host that draws the subtitle itself wants what the disc authored: each
///   rectangle with its own transparency, where it sits in the picture, the
///   frame those coordinates are measured in, and whether it is a forced one.
///   `Event.rects` and `Event.frameSize`.
///
/// A packet is decoded once for both: the decoder carries epoch state (PGS
/// palettes and objects live across packets), so feeding it a packet twice is
/// not an optimisation question, it is wrong.
final class BitmapSubtitleDecoder {

    /// One bitmap rectangle of a composition exactly as the codec delivered it:
    /// palette indices and a palette, not pixels.
    ///
    /// Kept in this form until a cue is actually handed over. A composition
    /// that waits for its clear (PGS) can sit here for seconds, and a flush
    /// throws it away; the indices are a quarter of the BGRA picture and no
    /// image is ever built for a composition nobody sees.
    struct Rect: Equatable, Sendable {
        /// Top-left corner in the codec's reference frame (`Event.frameSize`),
        /// pixels, y down.
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        /// `width * height` palette indices, rows top to bottom, no padding.
        let indices: [UInt8]
        /// ARGB in native byte order with **straight** (not premultiplied)
        /// alpha, as `AVSubtitleRect.data[1]` holds it.
        let palette: [UInt32]
        /// The codec's forced flag (`AV_SUBTITLE_FLAG_FORCED`): PGS marks it on
        /// each composition object, DVD on the whole subtitle. A disc's
        /// "foreign dialogue only" track is made of these, and so are the
        /// stray sign translations inside a full track.
        let isForced: Bool
    }

    /// One decoded event on the stream's timeline (source seconds).
    struct Event {
        let startSeconds: Double
        /// Explicit end when the codec carries one (DVD subtitles usually do,
        /// PGS ends with a clear event instead), `nil` otherwise.
        let endSeconds: Double?
        /// The composition for the recognizer — `nil` is a clear, and also a
        /// composition nobody asked to have composed (`decode(_:composeForOCR:)`).
        /// A clear is `isClear`; `image == nil` alone does not say so.
        let image: CGImage?
        /// The rectangles to show, individually. Empty is a clear.
        var rects: [Rect] = []
        /// `endSeconds` is a **time-out**, not an end: DVB states how long a
        /// page stays valid, and the next page replaces it sooner. A DVD
        /// sub-picture's stop time, by contrast, is exact.
        var endIsTimeOut = false
        /// The frame `rects` are positioned in — the video size the stream was
        /// authored for (PGS states it in every composition), or what the
        /// container and the video say when the codec is silent. `.zero` only
        /// when nothing at all was known.
        var frameSize: CGSize = .zero

        var isClear: Bool { rects.isEmpty && image == nil }
    }

    enum Failure: Error {
        case decoderUnavailable(String)
        case allocationFailed(String)
    }

    /// Larger than any subtitle frame in the field (UHD authoring is 3840 wide)
    /// and small enough that a corrupt rectangle cannot ask for a gigabyte.
    static let maximumSide = 4096

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private let codecID: AVCodecID
    private let codecName: String
    private let timeBase: AVRational
    /// What the frame is when the codec never says (a DVB stream without a
    /// display definition, a DVD index without a `size:` line): the video's.
    private let fallbackFrameSize: CGSize
    /// The decoder and an owned copy of the stream's parameters, kept so a
    /// flush can open a fresh context (see `flush()`).
    private let codec: UnsafePointer<AVCodec>?
    private var parameters: UnsafeMutablePointer<AVCodecParameters>?

    init(
        codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational,
        fallbackFrameSize: CGSize = .zero
    ) throws {
        let codecID = codecpar.pointee.codec_id
        self.codecID = codecID
        codecName = avcodec_get_name(codecID).map { String(cString: $0) } ?? "unknown"
        self.timeBase = timeBase
        self.fallbackFrameSize = fallbackFrameSize
        guard let decoder = avcodec_find_decoder(codecID) else {
            throw Failure.decoderUnavailable(codecName)
        }
        codec = decoder
        guard let owned = avcodec_parameters_alloc() else {
            throw Failure.allocationFailed("subtitle decoder parameters")
        }
        parameters = owned
        try FFmpegError.check(
            avcodec_parameters_copy(owned, codecpar),
            "avcodec_parameters_copy(subtitle)"
        )
        codecContext = try Self.openContext(codec: decoder, parameters: owned, timeBase: timeBase)
    }

    deinit {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if parameters != nil {
            avcodec_parameters_free(&parameters)
        }
    }

    private static func openContext(
        codec: UnsafePointer<AVCodec>, parameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational
    ) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let context = avcodec_alloc_context3(codec) else {
            throw Failure.allocationFailed("subtitle decoder context")
        }
        do {
            try FFmpegError.check(
                avcodec_parameters_to_context(context, parameters),
                "avcodec_parameters_to_context(subtitle)"
            )
            // Without this, libavcodec cannot place the composition on a timeline
            // and `AVSubtitle.pts` stays NOPTS — every event would be dropped as
            // untimed. Found the hard way against a real remux.
            context.pointee.pkt_timebase = timeBase
            try FFmpegError.check(
                avcodec_open2(context, codec, nil),
                "avcodec_open2(subtitle decoder)"
            )
        } catch {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&doomed)
            throw error
        }
        return context
    }

    /// A seek: the decoder forgets the epoch it was in. PGS keeps its palettes
    /// and objects across packets, and a display set that refers to them
    /// without defining them again (a fade, a repeat) is how a stream continues
    /// an epoch — decoded after a jump, it would show a picture from before
    /// it, at the new time. Until the next epoch start the decoder produces
    /// nothing, which is the honest outcome of joining mid-epoch.
    ///
    /// **`avcodec_flush_buffers` does not do this.** It calls the codec's own
    /// flush hook, and the PGS decoder in this FFmpeg (libavcodec 62) did not
    /// clear its cache on it: a display set re-showing an object defined
    /// before the flush still came out of it (`BitmapCueDecoderTests`,
    /// `flushForgetsTheEpoch`; observed, the decoder's code was not read). A
    /// new context is the reset that is guaranteed, and it costs a few
    /// microseconds on a seek (2 to 6 measured, in a debug build).
    func flush() {
        guard let codec, let parameters else { return }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        // A context that cannot be opened again leaves the decoder silent,
        // which is safe; a stale one is not.
        codecContext = try? Self.openContext(codec: codec, parameters: parameters, timeBase: timeBase)
    }

    /// The frame size right now: the codec's own statement if it has made one
    /// (PGS sets it from each composition's header, DVD from its index), else
    /// what the container declared for the stream (the codec context starts
    /// from it), else the video's.
    private func currentFrameSize() -> CGSize {
        if let codecContext, codecContext.pointee.width > 0, codecContext.pointee.height > 0 {
            return CGSize(width: Int(codecContext.pointee.width), height: Int(codecContext.pointee.height))
        }
        return fallbackFrameSize
    }

    /// Decode one packet. Most packets complete no composition (PGS spreads
    /// one over several), so an empty array is the common return.
    ///
    /// - Parameter composeForOCR: build `Event.image`, the composition on
    ///   black. A host tap alone does not need it, and the composition is the
    ///   larger part of the work.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>, composeForOCR: Bool = true) -> [Event] {
        guard let codecContext else { return [] }
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        let result = avcodec_decode_subtitle2(codecContext, &subtitle, &gotSubtitle, packet)
        guard result >= 0, gotSubtitle != 0 else { return [] }
        defer { avsubtitle_free(&subtitle) }

        // `pts` is on AV_TIME_BASE; display times are milliseconds after it.
        // When the codec couldn't place it, the packet's own timestamp on the
        // stream time base is the honest substitute.
        let base: Double
        if subtitle.pts != swift_AV_NOPTS_VALUE() {
            base = Double(subtitle.pts) / Double(AV_TIME_BASE)
        } else if packet.pointee.pts != swift_AV_NOPTS_VALUE() {
            base = Double(packet.pointee.pts) * av_q2d(timeBase)
        } else {
            return []
        }
        let start = base + Double(subtitle.start_display_time) / 1000
        let end = Self.explicitEndMilliseconds(
            start: subtitle.start_display_time, end: subtitle.end_display_time
        ).map { base + Double($0) / 1000 }

        guard subtitle.num_rects > 0 else {
            return [Event(startSeconds: start, endSeconds: nil, image: nil)]
        }
        let rects = Self.extractRects(from: subtitle)
        guard !rects.isEmpty else { return [] }
        // A composition too large to compose for the recognizer still goes out,
        // without a picture: the host that draws the rectangles can show it,
        // and the OCR side recognizes the gap (`image == nil` with rects).
        return [Event(
            startSeconds: start, endSeconds: end,
            image: composeForOCR ? Self.compose(rects) : nil,
            rects: rects, endIsTimeOut: end != nil && codecID == AV_CODEC_ID_DVB_SUBTITLE,
            frameSize: currentFrameSize()
        )]
    }

    /// The codec's end display time, or `nil` when it is only saying "until told otherwise".
    ///
    /// FFmpeg's PGS decoder reports every composition with `end_display_time` of
    /// `UINT32_MAX`: not an end, its marker for "the clear will say". Taken at face value
    /// that is a cue 49 days long, closed on the spot, which the writer then clamps to every
    /// segment boundary and repeats into every later segment — and the clear, when it comes,
    /// finds nothing pending to close. Observed on a Vision Pro as captions piling up on top
    /// of one another (2026-09-06). DVD subtitles carry a real end; those are kept.
    static func explicitEndMilliseconds(start: UInt32, end: UInt32) -> UInt32? {
        guard end != UInt32.max, end > start else { return nil }
        return end
    }

    // MARK: - Rectangles

    /// Copy every bitmap rectangle of `subtitle` out of libavcodec's memory,
    /// which is freed as soon as `decode` returns. Rectangles that cannot be
    /// drawn (no pixels, no palette, a side beyond `maximumSide`, a row stride
    /// shorter than the row) are skipped, not repaired.
    static func extractRects(from subtitle: AVSubtitle) -> [Rect] {
        guard subtitle.num_rects > 0, let list = subtitle.rects else { return [] }
        var rects: [Rect] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = list[index],
                  rect.pointee.type == SUBTITLE_BITMAP,
                  let pixels = rect.pointee.data.0,
                  let colors = rect.pointee.data.1
            else { continue }
            let width = Int(rect.pointee.w)
            let height = Int(rect.pointee.h)
            let stride = Int(rect.pointee.linesize.0)
            let colorCount = min(Int(rect.pointee.nb_colors), 256)
            guard width > 0, height > 0, width <= maximumSide, height <= maximumSide,
                  stride >= width, colorCount > 0
            else { continue }

            var indices = [UInt8](repeating: 0, count: width * height)
            indices.withUnsafeMutableBufferPointer { destination in
                for row in 0..<height {
                    (destination.baseAddress! + row * width).update(from: pixels + row * stride, count: width)
                }
            }
            let palette = colors.withMemoryRebound(to: UInt32.self, capacity: colorCount) {
                Array(UnsafeBufferPointer(start: $0, count: colorCount))
            }
            rects.append(Rect(
                x: Int(rect.pointee.x), y: Int(rect.pointee.y),
                width: width, height: height,
                indices: indices, palette: palette,
                isForced: rect.pointee.flags & AV_SUBTITLE_FLAG_FORCED != 0
            ))
        }
        return rects
    }

    // MARK: - Pixels

    /// All bitmap rects of one composition, blended onto black inside their
    /// common bounding box (relative rect positions carry line breaks). For the
    /// recognizer: alpha, forced flag and the picture's position are gone by
    /// design — see `picture(of:)` for the pixels a host draws.
    static func compose(_ rects: [Rect]) -> CGImage? {
        guard !rects.isEmpty else { return nil }

        let minX = rects.map(\.x).min()!
        let minY = rects.map(\.y).min()!
        let maxX = rects.map { $0.x + $0.width }.max()!
        let maxY = rects.map { $0.y + $0.height }.max()!
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0, width <= maximumSide, height <= maximumSide else { return nil }

        // Opaque black canvas, BGRA.
        var canvas = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: canvas.count, by: 4) { canvas[index] = 255 }

        for rect in rects {
            let offsetX = rect.x - minX
            let offsetY = rect.y - minY

            for row in 0..<rect.height {
                for column in 0..<rect.width {
                    let colorIndex = Int(rect.indices[row * rect.width + column])
                    guard colorIndex < rect.palette.count else { continue }
                    // Palette entries are ARGB in native byte order.
                    let argb = rect.palette[colorIndex]
                    let alpha = UInt32((argb >> 24) & 0xFF)
                    guard alpha > 0 else { continue }
                    let red = (argb >> 16) & 0xFF
                    let green = (argb >> 8) & 0xFF
                    let blue = argb & 0xFF
                    let target = ((offsetY + row) * width + offsetX + column) * 4
                    // Source-over onto black: out = src × alpha.
                    canvas[target] = UInt8(blue * alpha / 255)
                    canvas[target + 1] = UInt8(green * alpha / 255)
                    canvas[target + 2] = UInt8(red * alpha / 255)
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &canvas,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    /// One rectangle as the picture a host lays over the video: BGRA,
    /// premultiplied, and **transparent wherever the palette says so** — the
    /// disc authored a glyph's anti-aliased edge and a drop shadow as alpha,
    /// and flattening it onto a colour (as `compose` does for the recognizer)
    /// would put a black box behind every line.
    ///
    /// The picture is the rectangle's own size; where it goes is `Rect.x` /
    /// `Rect.y` in the stream's frame, and the caller carries that. Palette
    /// indices beyond the palette are transparent, as the recognizer's
    /// composition treats them.
    static func picture(of rect: Rect) -> CGImage? {
        let count = rect.width * rect.height
        guard rect.width > 0, rect.height > 0, rect.indices.count == count else { return nil }

        // One premultiplied value per palette entry, so the per-pixel pass is a
        // table lookup instead of three multiplies and divides.
        var table = [UInt32](repeating: 0, count: 256)
        for (slot, argb) in rect.palette.prefix(256).enumerated() {
            let alpha = (argb >> 24) & 0xFF
            guard alpha > 0 else { continue }
            let red = premultiplied((argb >> 16) & 0xFF, by: alpha)
            let green = premultiplied((argb >> 8) & 0xFF, by: alpha)
            let blue = premultiplied(argb & 0xFF, by: alpha)
            table[slot] = (alpha << 24) | (red << 16) | (green << 8) | blue
        }
        var pixels = [UInt32](repeating: 0, count: count)
        rect.indices.withUnsafeBufferPointer { source in
            table.withUnsafeBufferPointer { lookup in
                pixels.withUnsafeMutableBufferPointer { destination in
                    for position in 0..<count { destination[position] = lookup[Int(source[position])] }
                }
            }
        }

        // A UInt32 per pixel in a little-endian machine's order is the
        // `byteOrder32Little | premultipliedFirst` layout the image is declared
        // with: bytes B, G, R, A in memory.
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: rect.width, height: rect.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rect.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// `channel × alpha / 255`, rounded to nearest. Truncating would darken
    /// every semi-transparent pixel — the whole anti-aliased edge of a glyph —
    /// by up to one step; an opaque pixel is exact either way.
    private static func premultiplied(_ channel: UInt32, by alpha: UInt32) -> UInt32 {
        (channel * alpha + 127) / 255
    }
}
