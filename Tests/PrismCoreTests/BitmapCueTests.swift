import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Libavcodec
import Libavformat
import Libavutil
@testable import PrismCore

/// Bitmap subtitles as pictures: what the decoder hands over for a host to
/// draw — transparency, place, the frame that place is measured in, the forced
/// flag — and how a composition becomes cues with known ends.
///
/// The decoding tests run the real libavcodec decoders on packets assembled by
/// hand (`PGSFixture`): no FFmpeg build can encode these formats, so nothing
/// committable carries them. See that type for what this does and does not
/// prove.
@Suite("Bitmap cues: the decoder")
struct BitmapCueDecoderTests {

    // A 12 × 4 pill: transparent corners, a white rim, a half-transparent red
    // body. Index 0 is transparent, 1 white, 2 red at half alpha.
    static let pill: [[UInt8]] = [
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0],
        [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
    ]
    // Limited-range BT.709 red (Y 63, Cr 240, Cb 102) at half alpha.
    static let pillPalette: [PGSFixture.Entry] = [
        .clear(0), .white(1), PGSFixture.Entry(index: 2, y: 63, cr: 240, cb: 102, alpha: 128),
    ]

    private func decoder(
        _ codec: AVCodecID = AV_CODEC_ID_HDMV_PGS_SUBTITLE, fallback: CGSize = .zero
    ) throws -> BitmapSubtitleDecoder {
        let parameters = SubtitlePacketFixture.parameters(codec: codec)
        defer { SubtitlePacketFixture.free(parameters) }
        return try BitmapSubtitleDecoder(
            codecpar: parameters, timeBase: SubtitlePacketFixture.millisecondTimeBase,
            fallbackFrameSize: fallback
        )
    }

    private func decode(
        _ bytes: [UInt8], at milliseconds: Int64, with decoder: BitmapSubtitleDecoder,
        composeForOCR: Bool = false
    ) -> [BitmapSubtitleDecoder.Event] {
        let packet = SubtitlePacketFixture.packet(bytes, atMilliseconds: milliseconds)
        defer { SubtitlePacketFixture.free(packet) }
        return decoder.decode(packet, composeForOCR: composeForOCR)
    }

    @Test("A PGS composition arrives as rectangles: indices, palette, place, frame, forced")
    func pgsDecodesToRectangles() throws {
        let decoder = try decoder()
        let object = PGSFixture.Object(forced: true, x: 100, y: 900, rows: Self.pill)
        let events = decode(
            PGSFixture.displaySet(palette: Self.pillPalette, objects: [object]),
            at: 1_500, with: decoder
        )

        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.startSeconds == 1.5)
        // PGS ends a composition with the clear that follows, never with a time.
        #expect(event.endSeconds == nil)
        #expect(!event.isClear)
        // The frame is the one the stream states in its own header.
        #expect(event.frameSize == CGSize(width: 1920, height: 1080))

        let rect = try #require(event.rects.first)
        #expect(event.rects.count == 1)
        #expect(rect.x == 100 && rect.y == 900)
        #expect(rect.width == 12 && rect.height == 4)
        #expect(rect.indices == Self.pill.flatMap { $0 })
        #expect(rect.isForced)
        // The palette arrives whole, with straight alpha: index 2 is half
        // transparent, index 0 fully.
        #expect(rect.palette.count >= 3)
        #expect((rect.palette[0] >> 24) == 0)
        #expect((rect.palette[1] >> 24) == 255)
        #expect((rect.palette[2] >> 24) == 128)
    }

    @Test("A PGS clear has no rectangles, and says so")
    func pgsClearIsClear() throws {
        let decoder = try decoder()
        _ = decode(
            PGSFixture.displaySet(
                palette: Self.pillPalette, objects: [.init(x: 0, y: 0, rows: Self.pill)]
            ), at: 1_000, with: decoder
        )
        let events = decode(PGSFixture.clear(), at: 3_000, with: decoder)

        let event = try #require(events.first)
        #expect(event.startSeconds == 3.0)
        #expect(event.isClear)
        #expect(event.rects.isEmpty)
    }

    @Test("A composition's objects stay separate rectangles, each with its own forced flag")
    func pgsKeepsRectanglesApart() throws {
        let decoder = try decoder()
        let top = PGSFixture.Object(id: 0, windowID: 0, forced: true, x: 400, y: 80, rows: Self.pill)
        let bottom = PGSFixture.Object(id: 1, windowID: 1, forced: false, x: 300, y: 940, rows: Self.pill)
        let event = try #require(decode(
            PGSFixture.displaySet(palette: Self.pillPalette, objects: [top, bottom]),
            at: 0, with: decoder
        ).first)

        // Two rectangles, 860 pixels apart: merging them (as the recognizer's
        // picture does) would make a 12 × 864 canvas of which 99 % is air.
        #expect(event.rects.count == 2)
        #expect(event.rects.map(\.y) == [80, 940])
        #expect(event.rects.map(\.isForced) == [true, false])
    }

    @Test("The frame is what the stream says it is, not what the video happens to be")
    func pgsFrameIsTheStreams() throws {
        // A 1280 × 720 PGS stream over a 3840 × 2160 video: the coordinates
        // are in the stream's frame, and the host scales that to the picture.
        let decoder = try decoder(fallback: CGSize(width: 3840, height: 2160))
        let event = try #require(decode(
            PGSFixture.displaySet(
                video: (1280, 720), palette: Self.pillPalette,
                objects: [.init(x: 10, y: 600, rows: Self.pill)]
            ), at: 0, with: decoder
        ).first)
        #expect(event.frameSize == CGSize(width: 1280, height: 720))
    }

    @Test("A flush forgets the epoch: objects defined before it are gone after it")
    func flushForgetsTheEpoch() throws {
        let decoder = try decoder()
        let object = PGSFixture.Object(x: 100, y: 900, rows: Self.pill)
        _ = decode(
            PGSFixture.displaySet(compositionNumber: 1, palette: Self.pillPalette, objects: [object]),
            at: 1_000, with: decoder
        )
        // A normal-case display set that re-shows the object without defining
        // it again — how a palette change or a repeat is authored.
        let reuse = PGSFixture.displaySet(
            compositionNumber: 2, epochStart: false, palette: Self.pillPalette,
            objects: [object], defineObjects: false
        )
        // Within the epoch the object is still known…
        let before = decode(reuse, at: 2_000, with: decoder)
        #expect(before.first?.rects.count == 1)

        // …and across a flush it is not. The decoder is honest about joining
        // mid-epoch: nothing, rather than a picture assembled from before the
        // jump.
        decoder.flush()
        let after = decode(reuse, at: 3_000, with: decoder)
        #expect(after.allSatisfy { $0.rects.isEmpty })
    }

    /// Text drawn with CoreText into an 8-bit coverage mask, row by row, top to bottom.
    private func coverageMask(of text: String, pointSize: CGFloat = 30) throws -> (width: Int, height: Int, alpha: [UInt8]) {
        let width = 340
        let height = 44
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, pointSize, nil)
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString,
            [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        )!
        context.textPosition = CGPoint(x: 8, y: 11)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        // A bitmap context's memory starts at the top row, as subtitles count.
        let data = try #require(context.data)
        return (width, height, Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height)))
    }

    @Test("Anti-aliased text survives the trip: a coverage mask through PGS and the real decoder comes out as the same shape")
    func antiAliasedTextSurvivesTheRoundTrip() throws {
        let mask = try coverageMask(of: "Ahoj světe, Hello PGS")
        try #require(mask.alpha.contains { $0 > 0 && $0 < 255 }, "the mask has soft edges")

        // The disc's way: sixteen levels of one white, each its own palette
        // entry with its own alpha. That is how an authoring tool quantizes.
        let levels = 16
        let step = 255.0 / Double(levels - 1)
        let indices = mask.alpha.map { UInt8((Double($0) / step).rounded()) }
        let rows = stride(from: 0, to: indices.count, by: mask.width).map { Array(indices[$0 ..< $0 + mask.width]) }
        let palette = (0..<levels).map { level in
            level == 0
                ? PGSFixture.Entry.clear(0)
                : PGSFixture.Entry.white(UInt8(level), alpha: UInt8((Double(level) * step).rounded()))
        }

        let decoder = try self.decoder()
        let packet = SubtitlePacketFixture.packet(
            PGSFixture.displaySet(palette: palette, objects: [.init(x: 560, y: 930, rows: rows)]), atMilliseconds: 0
        )
        defer { SubtitlePacketFixture.free(packet) }
        let event = try #require(decoder.decode(packet, composeForOCR: false).first)
        let rect = try #require(event.rects.first)
        #expect(rect.width == mask.width && rect.height == mask.height)
        let image = try #require(BitmapSubtitleDecoder.picture(of: rect))
        let bytes = try bgra(image)
        try #require(bytes.count == mask.width * mask.height * 4)

        // Every pixel: white at the level's alpha, premultiplied (so each
        // channel equals the alpha), and within half a quantization step of
        // the coverage that was drawn.
        var worstCoverageError = 0
        var worstChannelError = 0
        for position in 0..<(mask.width * mask.height) {
            let alpha = Int(bytes[position * 4 + 3])
            for channel in 0..<3 {
                worstChannelError = max(worstChannelError, abs(Int(bytes[position * 4 + channel]) - alpha))
            }
            worstCoverageError = max(worstCoverageError, abs(alpha - Int(mask.alpha[position])))
        }
        #expect(worstChannelError <= 2, "premultiplied white: every channel is the alpha, off by \(worstChannelError)")
        #expect(worstCoverageError <= Int(step / 2) + 1, "off by \(worstCoverageError) from the drawn coverage")

        // For a person to look at, over a dark checkerboard: what a host would
        // draw. Only on request (`PRISMCORE_BITMAP_PREVIEW=1`): a hermetic test
        // does not leave a file behind on every run.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreBitmapCuePreview-\(UUID().uuidString).png")
        if ProcessInfo.processInfo.environment["PRISMCORE_BITMAP_PREVIEW"] != nil, let preview = CGContext(
            data: nil, width: mask.width * 3, height: mask.height * 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            for row in 0..<(mask.height * 3 / 12 + 1) {
                for column in 0..<(mask.width * 3 / 12 + 1) {
                    let dark = (row + column) % 2 == 0
                    preview.setFillColor(CGColor(gray: dark ? 0.18 : 0.30, alpha: 1))
                    preview.fill(CGRect(x: column * 12, y: row * 12, width: 12, height: 12))
                }
            }
            preview.interpolationQuality = .none
            preview.draw(image, in: CGRect(x: 0, y: 0, width: mask.width * 3, height: mask.height * 3))
            if let result = preview.makeImage(),
               let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, result, nil)
                CGImageDestinationFinalize(destination)
                print("BITMAPCUE preview of the round trip: \(output.path)")
            }
        }
    }

    @Test("Asking for the recognizer's picture is optional, and independent of the rectangles")
    func recognizerPictureIsOptional() throws {
        let decoder = try decoder()
        let packetBytes = PGSFixture.displaySet(
            palette: Self.pillPalette, objects: [.init(x: 0, y: 0, rows: Self.pill)]
        )
        let without = try #require(decode(packetBytes, at: 0, with: decoder, composeForOCR: false).first)
        #expect(without.image == nil)
        #expect(without.rects.count == 1)
        #expect(!without.isClear, "a composition without the recognizer's picture is not a clear")

        let withPicture = try #require(decode(packetBytes, at: 10, with: decoder, composeForOCR: true).first)
        #expect(withPicture.image != nil)
        #expect(withPicture.rects == without.rects)
    }
}

// MARK: - Pixels

/// Reading a picture back: the bytes of a `CGImage` this code made.
private func bgra(_ image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data)
    return [UInt8](data as Data)
}

@Suite("Bitmap cues: the picture")
struct BitmapCuePictureTests {

    // Straight ARGB, as a decoded palette holds it.
    static let transparent: UInt32 = 0x0000_0000
    static let white: UInt32 = 0xFFFF_FFFF
    static let halfRed: UInt32 = 0x80FF_0000

    private func rect(
        width: Int, height: Int, indices: [UInt8], palette: [UInt32], x: Int = 0, y: Int = 0, forced: Bool = false
    ) -> BitmapSubtitleDecoder.Rect {
        .init(x: x, y: y, width: width, height: height, indices: indices, palette: palette, isForced: forced)
    }

    @Test("The picture keeps what the disc made transparent, and says where the pixels are")
    func pictureKeepsTransparency() throws {
        let image = try #require(BitmapSubtitleDecoder.picture(of: rect(
            width: 3, height: 2, indices: [0, 1, 2, 2, 1, 0],
            palette: [Self.transparent, Self.white, Self.halfRed]
        )))
        #expect(image.width == 3 && image.height == 2)
        #expect(image.alphaInfo == .premultipliedFirst)
        #expect(image.bitmapInfo.contains(.byteOrder32Little))
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)

        // B, G, R, A in memory, premultiplied: transparent is all zero, white
        // is white, half-red is red at half strength.
        let none: [UInt8] = [0, 0, 0, 0]
        let opaqueWhite: [UInt8] = [255, 255, 255, 255]
        let halfRed: [UInt8] = [0, 0, 128, 128]
        #expect(try bgra(image) == none + opaqueWhite + halfRed + halfRed + opaqueWhite + none)
    }

    @Test("Premultiplying rounds to nearest, so a glyph's soft edge is not darkened")
    func premultiplyingRounds() throws {
        // 203 × 100 / 255 = 79.6: truncated it would be 79, rounded 80.
        let image = try #require(BitmapSubtitleDecoder.picture(of: rect(
            width: 2, height: 1, indices: [0, 1],
            palette: [0x64CB_CBCB, 0x01FF_FFFF]
        )))
        // alpha 1 of 255-white: 255 × 1 / 255 = 1.
        #expect(try bgra(image) == [80, 80, 80, 100, 1, 1, 1, 1])
    }

    @Test("An index beyond the palette is transparent, not a crash and not black")
    func indexBeyondPaletteIsTransparent() throws {
        let image = try #require(BitmapSubtitleDecoder.picture(of: rect(
            width: 2, height: 1, indices: [1, 7], palette: [Self.transparent, Self.white]
        )))
        #expect(try bgra(image) == [255, 255, 255, 255, 0, 0, 0, 0])
    }

    @Test("A rectangle whose indices do not match its size makes no picture")
    func inconsistentRectangleMakesNoPicture() {
        #expect(BitmapSubtitleDecoder.picture(of: rect(
            width: 3, height: 2, indices: [0, 1], palette: [Self.white]
        )) == nil)
        #expect(BitmapSubtitleDecoder.picture(of: rect(
            width: 0, height: 0, indices: [], palette: [Self.white]
        )) == nil)
    }

    @Test("The recognizer's picture is still opaque black with the glyphs on it, merged into one box")
    func recognizerPictureIsUnchanged() throws {
        // Two rectangles far apart: the merged canvas spans both, black where
        // neither draws — the shape the OCR path has always had.
        let first = rect(
            width: 4, height: 2, indices: [1, 0, 0, 2, 0, 0, 0, 0],
            palette: [Self.transparent, Self.white, Self.halfRed], x: 10, y: 10
        )
        let second = rect(
            width: 6, height: 3, indices: [Int](repeating: 1, count: 18).map { UInt8($0) },
            palette: [Self.transparent, Self.white], x: 30, y: 50
        )
        let canvas = try #require(BitmapSubtitleDecoder.compose([first, second]))
        #expect(canvas.width == 26 && canvas.height == 43)

        let bytes = try bgra(canvas)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(bytes[(y * canvas.width + x) * 4 ..< (y * canvas.width + x) * 4 + 4])
        }
        #expect(pixel(0, 0) == [255, 255, 255, 255], "first rectangle's white pixel, at its own corner")
        #expect(pixel(3, 0) == [0, 0, 128, 255], "half-red over black: red at half strength, but opaque")
        #expect(pixel(1, 0) == [0, 0, 0, 255], "a transparent pixel is black, never see-through")
        #expect(pixel(25, 42) == [255, 255, 255, 255], "second rectangle's far corner")
        #expect(pixel(15, 20) == [0, 0, 0, 255], "air between the two is black")
        // Every pixel of the canvas is opaque: that is the recognizer's contract.
        #expect(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
    }

    @Test("A composition that came without the recognizer's picture is not a clear for the recognizer")
    func uncomposedCompositionLeavesTheOCRCueAlone() throws {
        // Too large to compose, or not asked for: the host's rectangles are
        // there, the recognizer's picture is not. Taken for a clear it would
        // end the standing cue early; the decoder used to drop such events
        // before the recognizer saw them.
        let track = SubtitleRenditionSet.BitmapRenditionTrack(
            decoder: nil, language: nil, recognize: { _, _ in "TEXT" }
        )
        let image = try #require(BitmapSubtitleDecoder.picture(of: rect(
            width: 2, height: 1, indices: [1, 1], palette: [Self.transparent, Self.white]
        )))
        _ = track.process([.init(startSeconds: 1.0, endSeconds: nil, image: image)])

        let uncomposed = BitmapSubtitleDecoder.Event(
            startSeconds: 2.0, endSeconds: nil, image: nil,
            rects: [rect(width: 2, height: 1, indices: [1, 1], palette: [Self.transparent, Self.white])],
            frameSize: CGSize(width: 1920, height: 1080)
        )
        #expect(!uncomposed.isClear)
        #expect(track.process([uncomposed]).isEmpty, "it neither ends the standing cue nor starts one")
        // The clear, when it comes, ends the cue that stood all along.
        let clear = BitmapSubtitleDecoder.Event(startSeconds: 3.0, endSeconds: nil, image: nil)
        #expect(clear.isClear)
        #expect(track.process([clear]) == [SubtitleCue(start: 1.0, end: 3.0, text: "TEXT")])
    }
}

// MARK: - Lifecycle

/// Collects what a handler is given, from whichever thread it is called on.
final class BitmapCueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BitmapCue] = []
    func append(_ cue: BitmapCue) { lock.withLock { stored.append(cue) } }
    var cues: [BitmapCue] { lock.withLock { stored } }
}

@Suite("Bitmap cues: from compositions to cues with known ends")
struct BitmapCueTapTests {

    typealias Rect = BitmapSubtitleDecoder.Rect
    typealias Event = BitmapSubtitleDecoder.Event

    static let frame = CGSize(width: 1920, height: 1080)

    private func rect(x: Int = 100, y: Int = 900, width: Int = 2, height: Int = 1, forced: Bool = false) -> Rect {
        Rect(
            x: x, y: y, width: width, height: height,
            indices: [UInt8](repeating: 1, count: width * height),
            palette: [0x0000_0000, 0xFFFF_FFFF], isForced: forced
        )
    }

    /// A composition: standing until told otherwise, or with an explicit end.
    private func shown(
        _ seconds: Double, end: Double? = nil, timeOut: Bool = false, _ rects: [Rect]? = nil,
        frame: CGSize = Self.frame
    ) -> Event {
        Event(
            startSeconds: seconds, endSeconds: end, image: nil, rects: rects ?? [rect()],
            endIsTimeOut: timeOut, frameSize: frame
        )
    }

    private func cleared(_ seconds: Double) -> Event {
        Event(startSeconds: seconds, endSeconds: nil, image: nil)
    }

    /// A tap with a sink, the origin at zero, and `streams` chosen.
    private func tap(streams: Set<Int32> = [3]) -> (BitmapCueTap, BitmapCueCollector) {
        let tap = BitmapCueTap()
        let collector = BitmapCueCollector()
        tap.setHandler { collector.append($0) }
        tap.setWanted(streams)
        tap.setOrigin(seconds: 0)
        return (tap, collector)
    }

    @Test("A PGS show and its clear become one cue, the clear being its end")
    func showThenClear() {
        let (tap, collector) = tap()
        tap.process([shown(10.0)], streamIndex: 3)
        #expect(collector.cues.isEmpty, "no end is known yet, so nothing is handed over")

        tap.process([cleared(12.5)], streamIndex: 3)
        let cue = collector.cues.first
        #expect(collector.cues.count == 1)
        #expect(cue?.start == 10.0 && cue?.end == 12.5)
        #expect(cue?.streamIndex == 3)
        #expect(cue?.frame == CGRect(x: 100, y: 900, width: 2, height: 1))
        #expect(cue?.referenceSize == Self.frame)
        #expect(cue?.isForced == false)
        #expect(cue?.image.width == 2 && cue?.image.height == 1)
    }

    @Test("The next composition ends the standing one where it starts")
    func nextCompositionEndsStandingOne() {
        let (tap, collector) = tap()
        tap.process([shown(1.0)], streamIndex: 3)
        tap.process([shown(3.0)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[1.0, 3.0]])
        tap.process([cleared(4.0)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[1.0, 3.0], [3.0, 4.0]])
    }

    @Test("A DVD-style explicit end is believed and nothing is left standing")
    func explicitEnd() {
        let (tap, collector) = tap()
        tap.process([shown(5.0, end: 7.25)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[5.0, 7.25]])
        tap.finish()
        #expect(collector.cues.count == 1, "nothing stood, so finishing adds nothing")
    }

    @Test("A clear that never comes ends the picture after the same cap the OCR rendition has")
    func missingClearIsCapped() {
        let (tap, collector) = tap()
        tap.process([shown(0.0)], streamIndex: 3)
        tap.process([cleared(60.0)], streamIndex: 3)
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(collector.cues.map { [$0.start, $0.end] } == [[0.0, cap]])
    }

    @Test("What still stands when the stream ends is closed there, not lost")
    func finishClosesStandingCompositions() {
        let (tap, collector) = tap()
        tap.process([shown(100.0)], streamIndex: 3)
        tap.finish()
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(collector.cues.map { [$0.start, $0.end] } == [[100.0, 100.0 + cap]])
    }

    @Test("A seek kills the standing composition: nothing decoded before the jump appears after it")
    func reanchorDropsStandingComposition() {
        let (tap, collector) = tap()
        tap.process([shown(5.0)], streamIndex: 3)
        tap.reanchor()
        // The clear that would have ended it belongs to the other side of the jump.
        tap.process([cleared(9.0)], streamIndex: 3)
        tap.finish()
        #expect(collector.cues.isEmpty)

        // A composition from the new position works as ever.
        tap.process([shown(500.0), cleared(502.0)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[500.0, 502.0]])
    }

    @Test("Only the chosen streams are wanted, and only with a sink to hand them to")
    func onlyChosenStreamsAreWanted() {
        let tap = BitmapCueTap()
        #expect(!tap.wants(3), "nothing chosen, no sink")
        tap.setWanted([3])
        #expect(!tap.wants(3), "chosen, but no one to hand a picture to")
        tap.setHandler { _ in }
        #expect(tap.wants(3))
        #expect(!tap.wants(4), "a disc's thirty tracks cost nothing until one is chosen")
        tap.setHandler(nil)
        #expect(!tap.wants(3))
    }

    @Test("Choosing again reports what is new and drops what was dropped")
    func choosingAgain() {
        let (tap, collector) = tap(streams: [3, 4])
        tap.process([shown(1.0)], streamIndex: 3)
        tap.process([shown(1.0)], streamIndex: 4)

        let added = tap.setWanted([4, 5])
        #expect(added == [5])
        #expect(tap.wantedStreams == [4, 5])

        // Stream 3's standing picture went with the choice: its clear finds nothing.
        tap.process([cleared(2.0)], streamIndex: 3)
        #expect(collector.cues.isEmpty)
        // Stream 4 kept its own.
        tap.process([cleared(2.0)], streamIndex: 4)
        #expect(collector.cues.map(\.streamIndex) == [4])
    }

    @Test("Streams do not end each other's pictures")
    func streamsAreIndependent() {
        let (tap, collector) = tap(streams: [3, 4])
        tap.process([shown(1.0)], streamIndex: 3)
        tap.process([shown(2.0)], streamIndex: 4)
        tap.process([cleared(3.0)], streamIndex: 3)
        #expect(collector.cues.map { [Double($0.streamIndex), $0.start, $0.end] } == [[3, 1.0, 3.0]])
        tap.process([cleared(5.0)], streamIndex: 4)
        #expect(collector.cues.map { [Double($0.streamIndex), $0.start, $0.end] } == [[3, 1.0, 3.0], [4, 2.0, 5.0]])
    }

    @Test("One composition, several rectangles: several cues, same times, each its own place and forced flag")
    func severalRectangles() {
        let (tap, collector) = tap()
        let top = rect(x: 400, y: 80, width: 3, height: 2, forced: true)
        let bottom = rect(x: 300, y: 940, width: 5, height: 2, forced: false)
        tap.process([shown(1.0, [top, bottom]), cleared(2.0)], streamIndex: 3)

        #expect(collector.cues.count == 2)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[1.0, 2.0], [1.0, 2.0]])
        #expect(collector.cues.map(\.frame) == [
            CGRect(x: 400, y: 80, width: 3, height: 2), CGRect(x: 300, y: 940, width: 5, height: 2),
        ])
        #expect(collector.cues.map(\.isForced) == [true, false])
        #expect(collector.cues.map { $0.image.width } == [3, 5])
    }

    @Test("Times are on the played timeline: the origin comes off, the viewer's delay goes on, never below zero")
    func playedTimelineAndDelay() {
        let tap = BitmapCueTap()
        let collector = BitmapCueCollector()
        tap.setHandler { collector.append($0) }
        tap.setWanted([3])
        tap.setOrigin(seconds: 10)

        tap.process([shown(12.0, end: 15.0)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[2.0, 5.0]])

        tap.setDelay(1.5)
        tap.process([shown(12.0, end: 15.0)], streamIndex: 3)
        #expect(collector.cues.last.map { [$0.start, $0.end] } == [3.5, 6.5])

        // Pulled back 3 s, 2–5 s starts at zero rather than at -1.
        tap.setDelay(-3)
        tap.process([shown(12.0, end: 15.0)], streamIndex: 3)
        #expect(collector.cues.last.map { [$0.start, $0.end] } == [0.0, 2.0])

        // Pulled back past its own end, it is not shown at all.
        tap.setDelay(-10)
        let before = collector.cues.count
        tap.process([shown(12.0, end: 15.0)], streamIndex: 3)
        #expect(collector.cues.count == before)

        // And a picture from before the origin is never in the future.
        tap.setDelay(0)
        tap.process([shown(4.0, end: 6.0)], streamIndex: 3)
        #expect(collector.cues.count == before)
    }

    @Test("Compositions that end before the origin is known wait for it")
    func compositionsWaitForTheOrigin() {
        let tap = BitmapCueTap()
        let collector = BitmapCueCollector()
        tap.setHandler { collector.append($0) }
        tap.setWanted([3])

        tap.process([shown(12.0, end: 15.0)], streamIndex: 3)
        #expect(collector.cues.isEmpty, "without an origin the times mean nothing")

        tap.setOrigin(seconds: 10)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[2.0, 5.0]])
        // The origin is a fact about the output, set once.
        tap.setOrigin(seconds: 99)
        tap.process([shown(12.0, end: 15.0)], streamIndex: 3)
        #expect(collector.cues.last.map { [$0.start, $0.end] } == [2.0, 5.0])
    }

    @Test("A picture with no frame to be placed in is not delivered: a host would divide by zero")
    func unknownFrameMakesNoCue() {
        let (tap, collector) = tap()
        tap.process([shown(1.0, end: 2.0, frame: .zero)], streamIndex: 3)
        #expect(collector.cues.isEmpty)
    }

    @Test("A DVB page's time-out is a ceiling: the next page ends the page it replaces")
    func timeOutIsACeilingNotAnEnd() {
        let (tap, collector) = tap()
        // Page at 4 s, valid for 6 s — and a successor 3 s later.
        tap.process([shown(4.0, end: 10.0, timeOut: true)], streamIndex: 3)
        #expect(collector.cues.isEmpty, "believed as an end it would be delivered now, and the next page would stack on it")

        tap.process([shown(7.0, end: 13.0, timeOut: true)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[4.0, 7.0]])
        tap.process([cleared(8.0)], streamIndex: 3)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[4.0, 7.0], [7.0, 8.0]])
    }

    @Test("When nothing follows, the demux passing the latest end closes the picture there")
    func advanceClosesAtTheLatestEnd() {
        let (tap, collector) = tap(streams: [3, 4])
        tap.process([shown(4.0, end: 10.0, timeOut: true)], streamIndex: 3)   // DVB, valid for 6 s
        tap.process([shown(100.0)], streamIndex: 4)                            // PGS whose clear never comes

        tap.advance(to: 9.9)
        #expect(collector.cues.isEmpty)
        tap.advance(to: 10.0)
        #expect(collector.cues.map { [Double($0.streamIndex), $0.start, $0.end] } == [[3, 4.0, 10.0]])

        tap.advance(to: 105)
        #expect(collector.cues.count == 1)
        tap.advance(to: 110)
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(collector.cues.last.map { [Double($0.streamIndex), $0.start, $0.end] } == [4, 100.0, 100.0 + cap])
        // Delivered once: the same boundary again changes nothing.
        tap.advance(to: 200)
        #expect(collector.cues.count == 2)
    }

    @Test("A time-out longer than the cap is cut at the cap, like a clear that never comes")
    func longTimeOutIsCapped() {
        let (tap, collector) = tap()
        tap.process([shown(0.0, end: 60.0, timeOut: true)], streamIndex: 3)
        tap.finish()
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(collector.cues.map { [$0.start, $0.end] } == [[0.0, cap]])
    }

    @Test("The end of the stream closes a DVB page at its time-out")
    func finishUsesTheTimeOut() {
        let (tap, collector) = tap()
        tap.process([shown(4.0, end: 7.0, timeOut: true)], streamIndex: 3)
        tap.finish()
        #expect(collector.cues.map { [$0.start, $0.end] } == [[4.0, 7.0]])
    }

    @Test("A second delivery of the same cue has the same identity, with a new image")
    func identityOfARedelivery() throws {
        let (tap, collector) = tap()
        tap.process([shown(1.0, end: 2.0)], streamIndex: 3)
        tap.reanchor()
        tap.process([shown(1.0, end: 2.0)], streamIndex: 3)

        try #require(collector.cues.count == 2)
        let first = collector.cues[0]
        let second = collector.cues[1]
        #expect(first.id == second.id)
        #expect(first.image !== second.image, "a new image: the engine kept nothing")
        #expect(Set([first.id, second.id]).count == 1)
        // A different rectangle at the same time is a different cue.
        tap.process([shown(1.0, end: 2.0, [rect(x: 7)])], streamIndex: 3)
        #expect(collector.cues.last?.id != first.id)
    }

    @Test("The delay rule is TimedTextCue's: start clamped at zero, wholly-before-zero dropped")
    func delayedMatchesTimedText() throws {
        let image = try #require(BitmapSubtitleDecoder.picture(of: rect()))
        let cue = BitmapCue(
            streamIndex: 3, start: 1, end: 3, image: image,
            frame: CGRect(x: 0, y: 0, width: 2, height: 1), referenceSize: Self.frame
        )
        let text = TimedTextCue(streamIndex: 3, start: 1, end: 3, text: "x")
        for delay in [0.0, 0.5, -0.5, -1, -2, -3, 4] {
            let picture = cue.delayed(by: delay)
            let words = text.delayed(by: delay)
            #expect(picture?.start == words?.start, "start under delay \(delay)")
            #expect(picture?.end == words?.end, "end under delay \(delay)")
        }
    }
}

// MARK: - Inside the rendition set

/// A demuxer's view of a source, built in memory: streams with the parameters
/// `SubtitleRenditionSet.prepare` reads, and nothing else.
private final class FakeInput {
    enum Stream {
        case video(width: Int32, height: Int32)
        case subtitle(AVCodecID, language: String?)
    }

    let context: UnsafeMutablePointer<AVFormatContext>

    init(_ streams: [Stream]) {
        context = avformat_alloc_context()!
        for spec in streams {
            let stream = avformat_new_stream(context, nil)!
            stream.pointee.time_base = SubtitlePacketFixture.millisecondTimeBase
            switch spec {
            case .video(let width, let height):
                stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_VIDEO
                stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_H264
                stream.pointee.codecpar.pointee.width = width
                stream.pointee.codecpar.pointee.height = height
            case .subtitle(let codec, let language):
                stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
                stream.pointee.codecpar.pointee.codec_id = codec
                if let language { av_dict_set(&stream.pointee.metadata, "language", language, 0) }
            }
        }
    }

    deinit { avformat_free_context(context) }
}

@Suite("Bitmap cues: inside the rendition set", .serialized)
struct BitmapCueRenditionSetTests {

    private let pgs = AV_CODEC_ID_HDMV_PGS_SUBTITLE

    private func makeSet() throws -> (set: SubtitleRenditionSet, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreBitmapCues-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SubtitleRenditionSet(outputDirectory: directory), directory)
    }

    private func ingest(
        _ bytes: [UInt8], at milliseconds: Int64, stream: Int32, into set: SubtitleRenditionSet
    ) {
        let packet = SubtitlePacketFixture.packet(bytes, atMilliseconds: milliseconds, streamIndex: stream)
        defer { SubtitlePacketFixture.free(packet) }
        set.ingest(packet)
    }

    private func show(_ x: Int = 100, forced: Bool = false) -> [UInt8] {
        PGSFixture.displaySet(
            palette: BitmapCueDecoderTests.pillPalette,
            objects: [.init(forced: forced, x: x, y: 900, rows: BitmapCueDecoderTests.pill)]
        )
    }

    @Test("A PGS track beside a text track has no rendition, and still gives the host its pictures")
    func pictureOnlyStreamBesideTextTrack() throws {
        let (set, directory) = try makeSet()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = FakeInput([
            .video(width: 1920, height: 1080),
            .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"),
            .subtitle(pgs, language: "eng"),
        ])

        // Both subtitle streams' packets have to reach `ingest`; only the text
        // one has a rendition (beside a real SRT, OCR'd twins are menu noise).
        let routed = try set.prepare(input: input.context)
        #expect(routed == [1, 2])
        #expect(set.renditions.count == 1)

        set.setTimelineOrigin(seconds: 0)
        let collector = BitmapCueCollector()
        set.setBitmapCueHandler { collector.append($0) }

        // Not chosen: nothing is decoded, nothing is delivered.
        ingest(show(), at: 1_000, stream: 2, into: set)
        ingest(PGSFixture.clear(), at: 3_000, stream: 2, into: set)
        #expect(collector.cues.isEmpty)

        // Chosen: the same stream, now decoded and delivered.
        #expect(set.setBitmapCueStreams([2]) == [2])
        ingest(show(forced: true), at: 5_000, stream: 2, into: set)
        ingest(PGSFixture.clear(), at: 7_500, stream: 2, into: set)
        let cue = try #require(collector.cues.first)
        #expect(collector.cues.count == 1)
        #expect(cue.streamIndex == 2)
        #expect(cue.start == 5.0 && cue.end == 7.5)
        #expect(cue.frame == CGRect(x: 100, y: 900, width: 12, height: 4))
        #expect(cue.referenceSize == CGSize(width: 1920, height: 1080))
        #expect(cue.isForced)
        // A text stream is not a bitmap stream: choosing it changes nothing.
        set.setBitmapCueStreams([1, 2])
        ingest(show(), at: 9_000, stream: 1, into: set)
        #expect(collector.cues.count == 1)
    }

    @Test("A PGS track with an OCR rendition gives pictures without being fetched, and once when it is")
    func pictureAndRecognizerShareOneDecode() throws {
        try #require(SubtitleOCR.isAvailable, "no Vision here: the rendition would not exist")
        let (set, directory) = try makeSet()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = FakeInput([.video(width: 1920, height: 1080), .subtitle(pgs, language: "eng")])

        #expect(try set.prepare(input: input.context) == [1])
        #expect(set.renditions.count == 1, "no text track, so the OCR rendition exists")
        set.setTimelineOrigin(seconds: 0)
        let collector = BitmapCueCollector()
        set.setBitmapCueHandler { collector.append($0) }
        set.setBitmapCueStreams([1])

        // Nobody fetched the rendition: OCR is idle (lazy arming), the pictures are not.
        ingest(show(), at: 1_000, stream: 1, into: set)
        ingest(PGSFixture.clear(), at: 2_000, stream: 1, into: set)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[1.0, 2.0]])

        // The player fetches a segment of the rendition: it arms. The pictures
        // are delivered exactly once per composition, not once per reader.
        #expect(set.noteSegmentDemand(path: "subs0/seg00000.vtt") == .serveAsIs)
        ingest(show(), at: 4_000, stream: 1, into: set)
        ingest(PGSFixture.clear(), at: 5_000, stream: 1, into: set)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[1.0, 2.0], [4.0, 5.0]])
    }

    @Test("Neither reader wanting the stream means the packet is not decoded at all")
    func nobodyWantsNothingIsDecoded() throws {
        let (set, directory) = try makeSet()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = FakeInput([
            .video(width: 1920, height: 1080), .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"),
            .subtitle(pgs, language: "eng"),
        ])
        try set.prepare(input: input.context)
        set.setTimelineOrigin(seconds: 0)
        let collector = BitmapCueCollector()
        set.setBitmapCueHandler { collector.append($0) }

        // Not chosen while packets flow…
        ingest(show(), at: 1_000, stream: 2, into: set)
        // …then chosen: the decoder has not seen the display set above, so a
        // clear alone ends nothing and a normal-case set that refers to it
        // shows nothing — the proof that no work was done for it.
        set.setBitmapCueStreams([2])
        ingest(PGSFixture.clear(), at: 3_000, stream: 2, into: set)
        let reuse = PGSFixture.displaySet(
            compositionNumber: 3, epochStart: false, palette: BitmapCueDecoderTests.pillPalette,
            objects: [.init(x: 100, y: 900, rows: BitmapCueDecoderTests.pill)], defineObjects: false
        )
        ingest(reuse, at: 4_000, stream: 2, into: set)
        ingest(PGSFixture.clear(), at: 5_000, stream: 2, into: set)
        #expect(collector.cues.isEmpty)
    }

    @Test("A re-anchor flushes the decoders and ends nothing across the jump, rendition or not")
    func reanchorFlushesEveryDecoder() throws {
        // Two sources: a PGS stream that has an OCR rendition (no text track),
        // and one that is picture-only (a text track beside it). Each stream
        // keeps its decoder somewhere else, and a jump has to reach both.
        for (label, streams) in [
            ("with a rendition", [FakeInput.Stream.video(width: 1920, height: 1080), .subtitle(pgs, language: "eng")]),
            ("picture-only", [FakeInput.Stream.video(width: 1920, height: 1080), .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"), .subtitle(pgs, language: "eng")]),
        ] {
            let (set, directory) = try makeSet()
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = FakeInput(streams)
            try set.prepare(input: input.context)
            let stream = Int32(streams.count - 1)
            set.setTimelineOrigin(seconds: 0)
            let collector = BitmapCueCollector()
            set.setBitmapCueHandler { collector.append($0) }
            set.setBitmapCueStreams([stream])

            // A picture stands, the player jumps, and the clear that would have
            // ended it is the far side's. Nothing may come of either.
            ingest(show(), at: 1_000, stream: stream, into: set)
            set.reanchor(segmentIndex: 40, startSeconds: 240)
            ingest(PGSFixture.clear(), at: 242_000, stream: stream, into: set)
            #expect(collector.cues.isEmpty, "\(label): a standing picture crossed the jump")

            // A display set that continues the OLD epoch must not resurrect it.
            let reuse = PGSFixture.displaySet(
                compositionNumber: 9, epochStart: false, palette: BitmapCueDecoderTests.pillPalette,
                objects: [.init(x: 100, y: 900, rows: BitmapCueDecoderTests.pill)], defineObjects: false
            )
            ingest(reuse, at: 243_000, stream: stream, into: set)
            ingest(PGSFixture.clear(), at: 244_000, stream: stream, into: set)
            #expect(collector.cues.isEmpty, "\(label): the decoder remembered an object from before the jump")

            // A fresh epoch after the jump is shown as ever.
            ingest(show(), at: 250_000, stream: stream, into: set)
            ingest(PGSFixture.clear(), at: 252_000, stream: stream, into: set)
            #expect(collector.cues.map { [$0.start, $0.end] } == [[250.0, 252.0]], "\(label)")
        }
    }

    @Test("A stream chosen again starts from a clean decoder: what it held from before the gap is gone")
    func choosingAgainFlushesTheDecoder() throws {
        // A PGS stream with an OCR rendition and one without keep their
        // decoders in different places; both have to be flushed.
        for (label, streams) in [
            ("with a rendition", [FakeInput.Stream.video(width: 1920, height: 1080), .subtitle(pgs, language: "eng")]),
            ("picture-only", [FakeInput.Stream.video(width: 1920, height: 1080), .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"), .subtitle(pgs, language: "eng")]),
        ] {
            let (set, directory) = try makeSet()
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = FakeInput(streams)
            try set.prepare(input: input.context)
            let stream = Int32(streams.count - 1)
            set.setTimelineOrigin(seconds: 0)
            let collector = BitmapCueCollector()
            set.setBitmapCueHandler { collector.append($0) }
            set.setBitmapCueStreams([stream])

            // An epoch is defined and shown.
            ingest(show(), at: 1_000, stream: stream, into: set)
            ingest(PGSFixture.clear(), at: 2_000, stream: stream, into: set)
            #expect(collector.cues.count == 1, "\(label)")

            // The viewer turns the track off and, later, on again. The demux
            // went on in between; the decoder was not fed.
            set.setBitmapCueStreams([])
            ingest(show(), at: 30_000, stream: stream, into: set)
            set.setBitmapCueStreams([stream])

            // A display set that continues the old epoch without defining it
            // must not bring the old picture back at 60 s.
            let reuse = PGSFixture.displaySet(
                compositionNumber: 9, epochStart: false, palette: BitmapCueDecoderTests.pillPalette,
                objects: [.init(x: 100, y: 900, rows: BitmapCueDecoderTests.pill)], defineObjects: false
            )
            ingest(reuse, at: 60_000, stream: stream, into: set)
            ingest(PGSFixture.clear(), at: 61_000, stream: stream, into: set)
            #expect(collector.cues.count == 1, "\(label): a picture from the first epoch appeared at 60 s")

            // And a fresh epoch is shown as ever.
            ingest(show(), at: 70_000, stream: stream, into: set)
            ingest(PGSFixture.clear(), at: 71_000, stream: stream, into: set)
            #expect(collector.cues.map(\.start) == [1.0, 70.0], "\(label)")
        }
    }

    @Test("The end of the production closes what still stands")
    func finishClosesStanding() throws {
        let (set, directory) = try makeSet()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = FakeInput([
            .video(width: 1920, height: 1080), .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"),
            .subtitle(pgs, language: "eng"),
        ])
        try set.prepare(input: input.context)
        set.setTimelineOrigin(seconds: 0)
        let collector = BitmapCueCollector()
        set.setBitmapCueHandler { collector.append($0) }
        set.setBitmapCueStreams([2])

        ingest(show(), at: 6_000, stream: 2, into: set)
        try set.finish()
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(collector.cues.map { [$0.start, $0.end] } == [[6.0, 6.0 + cap]])
    }

    @Test("A cut of the video segment tells the pictures how far the demux has read")
    func segmentCutsAdvanceThePictures() throws {
        let (set, directory) = try makeSet()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = FakeInput([
            .video(width: 1920, height: 1080), .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"),
            .subtitle(pgs, language: "eng"),
        ])
        try set.prepare(input: input.context)
        set.setTimelineOrigin(seconds: 0)
        let collector = BitmapCueCollector()
        set.setBitmapCueHandler { collector.append($0) }
        set.setBitmapCueStreams([2])

        // The last subtitle before a long silence: no clear, no successor.
        ingest(show(), at: 1_000, stream: 2, into: set)
        try set.flushSegment(start: 0, end: 6)
        #expect(collector.cues.isEmpty, "it may still be standing at 6 s")

        // The segment cut at 12 s says the demux has read past 11 s, the
        // longest it could stand: it ends there instead of waiting for a
        // subtitle that may be minutes away.
        try set.flushSegment(start: 6, end: 12)
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(collector.cues.map { [$0.start, $0.end] } == [[1.0, 1.0 + cap]])
    }

    @Test("The origin and the delay the set is given reach the pictures")
    func originAndDelayReachThePictures() throws {
        let (set, directory) = try makeSet()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = FakeInput([
            .video(width: 1920, height: 1080), .subtitle(AV_CODEC_ID_SUBRIP, language: "eng"),
            .subtitle(pgs, language: "eng"),
        ])
        try set.prepare(input: input.context)
        let collector = BitmapCueCollector()
        set.setBitmapCueHandler { collector.append($0) }
        set.setBitmapCueStreams([2])

        // Before the origin exists the picture waits.
        ingest(show(), at: 12_000, stream: 2, into: set)
        ingest(PGSFixture.clear(), at: 15_000, stream: 2, into: set)
        #expect(collector.cues.isEmpty)

        set.setDelay(0.5)
        set.setTimelineOrigin(seconds: 10)
        #expect(collector.cues.map { [$0.start, $0.end] } == [[2.5, 5.5]])
    }
}

// MARK: - DVD

@Suite("Bitmap cues: DVD subtitles through the real decoder")
struct BitmapCueDVDTests {

    // 20 × 6: colour 1 (white) rim, colour 2 (red) inside, colour 3 half-transparent corner dots.
    static let rows: [[UInt8]] = [
        [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3],
        [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1],
        [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1],
        [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1],
        [1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1],
        [3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
    ]

    private func decoder(size: (Int, Int)? = (720, 480), fallback: CGSize = .zero) throws -> BitmapSubtitleDecoder {
        let parameters = SubtitlePacketFixture.parameters(
            codec: AV_CODEC_ID_DVD_SUBTITLE, extradata: size.map { DVDFixture.extradata(size: ($0.0, $0.1)) } ?? []
        )
        defer { SubtitlePacketFixture.free(parameters) }
        return try BitmapSubtitleDecoder(
            codecpar: parameters, timeBase: SubtitlePacketFixture.millisecondTimeBase, fallbackFrameSize: fallback
        )
    }

    private func decode(_ bytes: [UInt8], at milliseconds: Int64, with decoder: BitmapSubtitleDecoder) -> [BitmapSubtitleDecoder.Event] {
        let packet = SubtitlePacketFixture.packet(bytes, atMilliseconds: milliseconds)
        defer { SubtitlePacketFixture.free(packet) }
        return decoder.decode(packet, composeForOCR: false)
    }

    @Test("A DVD sub-picture arrives with its own end, its place, its frame and its transparency")
    func dvdDecodes() throws {
        let decoder = try decoder()
        let events = decode(DVDFixture.packet(x: 100, y: 400, rows: Self.rows), at: 10_000, with: decoder)

        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.startSeconds == 10.0)
        // DVD says when it ends: (200 << 10) / 90 = 2275 ms after the packet.
        let end = try #require(event.endSeconds)
        #expect(abs(end - 12.275) < 0.0015)
        // The frame is the `size:` of the index in the track's private data.
        #expect(event.frameSize == CGSize(width: 720, height: 480))

        let rect = try #require(event.rects.first)
        #expect(rect.x == 100 && rect.y == 400)
        #expect(rect.width == 20 && rect.height == 6)
        #expect(rect.indices == Self.rows.flatMap { $0 })
        #expect(!rect.isForced)
        // Four colours: transparent, white, red, and a half-opaque one
        // (alpha 8 of 15 is 136 of 255).
        #expect(rect.palette.count == 4)
        #expect(rect.palette.map { $0 >> 24 } == [0, 255, 255, 136])
        #expect(rect.palette[1] & 0xFFFFFF == 0xFFFFFF)
        #expect(rect.palette[2] & 0xFFFFFF == 0xFF0000)
    }

    @Test("DVD's forced start display command is the forced flag")
    func dvdForced() throws {
        let decoder = try decoder()
        let forced = try #require(decode(
            DVDFixture.packet(x: 0, y: 0, rows: Self.rows, forced: true), at: 0, with: decoder
        ).first?.rects.first)
        #expect(forced.isForced)
        let ordinary = try #require(decode(
            DVDFixture.packet(x: 0, y: 0, rows: Self.rows, forced: false), at: 5_000, with: decoder
        ).first?.rects.first)
        #expect(!ordinary.isForced)
    }

    @Test("Without a size in the track's private data the frame is the video's")
    func dvdFrameFallsBackToTheVideo() throws {
        let decoder = try decoder(size: nil, fallback: CGSize(width: 1920, height: 1080))
        let event = try #require(decode(
            DVDFixture.packet(x: 100, y: 400, rows: Self.rows), at: 0, with: decoder
        ).first)
        #expect(event.frameSize == CGSize(width: 1920, height: 1080))
    }

    @Test("A DVD sub-picture becomes cues at once: its end is already known")
    func dvdBecomesCues() throws {
        let decoder = try decoder()
        let events = decode(DVDFixture.packet(x: 100, y: 400, rows: Self.rows), at: 10_000, with: decoder)
        let tap = BitmapCueTap()
        let collector = BitmapCueCollector()
        tap.setHandler { collector.append($0) }
        tap.setWanted([4])
        tap.setOrigin(seconds: 0)
        tap.process(events, streamIndex: 4)

        let cue = try #require(collector.cues.first)
        #expect(collector.cues.count == 1, "no clear needed")
        #expect(cue.start == 10.0 && abs(cue.end - 12.275) < 0.0015)
        #expect(cue.referenceSize == CGSize(width: 720, height: 480))
        #expect(cue.frame == CGRect(x: 100, y: 400, width: 20, height: 6))
        // The picture shows the rectangle: transparent corner, white, red.
        let bytes = try bgra(cue.image)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * 20 + x) * 4 ..< (y * 20 + x) * 4 + 4]) }
        #expect(pixel(0, 0) == [0, 0, 0, 0])
        #expect(pixel(1, 0) == [255, 255, 255, 255])
        #expect(pixel(1, 1) == [0, 0, 255, 255])
    }
}

// MARK: - DVB

@Suite("Bitmap cues: DVB subtitles through the real decoder")
struct BitmapCueDVBTests {

    // 0 transparent, 1 white, 2 red at half transparency.
    static let palette: [DVBFixture.Entry] = [
        .init(index: 0, y: 0, cr: 128, cb: 128, transparency: 255),
        .init(index: 1, y: 235, cr: 128, cb: 128, transparency: 0),
        .init(index: 2, y: 63, cr: 240, cb: 102, transparency: 127),
    ]
    static let rows: [[UInt8]] = [
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
        [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0],
        [0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 1, 0],
        [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0],
    ]

    private func decoder(fallback: CGSize = .zero) throws -> BitmapSubtitleDecoder {
        let parameters = SubtitlePacketFixture.parameters(codec: AV_CODEC_ID_DVB_SUBTITLE)
        defer { SubtitlePacketFixture.free(parameters) }
        return try BitmapSubtitleDecoder(
            codecpar: parameters, timeBase: SubtitlePacketFixture.millisecondTimeBase, fallbackFrameSize: fallback
        )
    }

    private func decode(_ bytes: [UInt8], at milliseconds: Int64, with decoder: BitmapSubtitleDecoder) -> [BitmapSubtitleDecoder.Event] {
        let packet = SubtitlePacketFixture.packet(bytes, atMilliseconds: milliseconds)
        defer { SubtitlePacketFixture.free(packet) }
        return decoder.decode(packet, composeForOCR: false)
    }

    @Test("A DVB display set arrives as its region: pixels, place, palette with transparency")
    func dvbDecodes() throws {
        let decoder = try decoder(fallback: CGSize(width: 1920, height: 1080))
        let events = decode(
            DVBFixture.displaySet(x: 100, y: 400, rows: Self.rows, palette: Self.palette),
            at: 4_000, with: decoder
        )
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.startSeconds == 4.0)
        // DVB's only statement of duration is the page time-out, 6 s here.
        #expect(event.endSeconds == 10.0)
        #expect(event.endIsTimeOut, "a ceiling: the next page replaces this one")

        let rect = try #require(event.rects.first)
        #expect(rect.x == 100 && rect.y == 400)
        #expect(rect.width == 12 && rect.height == 4)
        #expect(rect.indices == Self.rows.flatMap { $0 })
        // DVB states transparency, the CLUT turns it into alpha: 255 → 0, 0 → 255, 127 → 128.
        #expect(rect.palette[0] >> 24 == 0)
        #expect(rect.palette[1] >> 24 == 255)
        #expect(rect.palette[2] >> 24 == 128)
        #expect(!rect.isForced, "DVB has no forced flag")
    }

    @Test("Without a display definition a DVB frame is the standard's 720 × 576, whatever the video is")
    func dvbDefaultFrame() throws {
        // The decoder states it itself; the video's size is only for codecs
        // that say nothing, and DVB is not one of them.
        let decoder = try decoder(fallback: CGSize(width: 3840, height: 2160))
        let event = try #require(decode(
            DVBFixture.displaySet(x: 100, y: 400, rows: Self.rows, palette: Self.palette),
            at: 0, with: decoder
        ).first)
        #expect(event.frameSize == CGSize(width: 720, height: 576))
    }

    @Test("A display definition sets the frame: how HD broadcasts state theirs")
    func dvbDisplayDefinitionFrame() throws {
        for size in [(width: 1920, height: 1080), (width: 1280, height: 720)] {
            let decoder = try decoder()
            let event = try #require(decode(
                DVBFixture.displaySet(
                    x: 100, y: 400, rows: Self.rows, palette: Self.palette, displayDefinition: size
                ), at: 0, with: decoder
            ).first)
            #expect(event.frameSize == CGSize(width: size.width, height: size.height))
        }
    }

    @Test("An empty DVB page is a clear")
    func dvbEmptyPageIsClear() throws {
        let decoder = try decoder()
        let event = try #require(decode(DVBFixture.emptyPage(), at: 2_000, with: decoder).first)
        #expect(event.isClear)
        #expect(event.rects.isEmpty)
    }

    @Test("Two DVB pages in a row are two cues, the second ending the first where it starts")
    func dvbPagesDoNotStack() throws {
        let decoder = try decoder()
        let tap = BitmapCueTap()
        let collector = BitmapCueCollector()
        tap.setHandler { collector.append($0) }
        tap.setWanted([5])
        tap.setOrigin(seconds: 0)

        // Page time-out 6 s, a successor 2 s in: the first stands for 2 s, not 6.
        let first = DVBFixture.displaySet(x: 100, y: 400, rows: Self.rows, palette: Self.palette, version: 1)
        let second = DVBFixture.displaySet(x: 100, y: 420, rows: Self.rows, palette: Self.palette, version: 2)
        tap.process(decode(first, at: 4_000, with: decoder), streamIndex: 5)
        tap.process(decode(second, at: 6_000, with: decoder), streamIndex: 5)
        tap.process(decode(DVBFixture.emptyPage(version: 3), at: 8_000, with: decoder), streamIndex: 5)

        #expect(collector.cues.map { [$0.start, $0.end] } == [[4.0, 6.0], [6.0, 8.0]])
        #expect(collector.cues.map(\.frame.minY) == [400, 420])
        #expect(collector.cues.allSatisfy { $0.referenceSize == CGSize(width: 720, height: 576) })
    }
}

// MARK: - Through the remuxer

/// A real session on a real Matroska file with a PGS stream in it: probe,
/// plan, producer thread, the packet routing, the decoder, the tap, the
/// replay. The PGS content is hand-made (`PGSFixture`) and the file is made
/// from a committed fixture at test time (`MatroskaFixture`).
@Suite("Bitmap cues: through the session", .serialized)
struct BitmapCueSessionTests {

    typealias Packet = MatroskaFixture.SubtitlePacket

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    private func show(forced: Bool = false, x: Int = 100) -> [UInt8] {
        PGSFixture.displaySet(
            palette: BitmapCueDecoderTests.pillPalette,
            objects: [.init(forced: forced, x: x, y: 900, rows: BitmapCueDecoderTests.pill)]
        )
    }

    /// Five compositions on the 30 s fixture, none within a quarter second of
    /// a segment boundary (the fixture's keyframes are every 2 s):
    ///
    ///     A 2.5–4.5      cleared
    ///     B 10.5–12.75   cleared, forced
    ///     C 14.5         ended by D, the next composition
    ///     D 16.5–17.75   cleared
    ///     E 19.0         nothing ever ends it: the latest end it can have is 29.0
    private func packets() -> [Packet] {
        func shown(_ seconds: Double, x: Int, forced: Bool = false) -> Packet {
            Packet(milliseconds: Int64(seconds * 1000), durationMilliseconds: 1_000, bytes: show(forced: forced, x: x))
        }
        func cleared(_ seconds: Double, number: Int) -> Packet {
            Packet(milliseconds: Int64(seconds * 1000), durationMilliseconds: 1, bytes: PGSFixture.clear(compositionNumber: number))
        }
        return [
            shown(2.5, x: 100), cleared(4.5, number: 2),
            shown(10.5, x: 300, forced: true), cleared(12.75, number: 4),
            shown(14.5, x: 500), shown(16.5, x: 700), cleared(17.75, number: 7),
            shown(19.0, x: 900),
        ]
    }

    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreBitmapCues-\(UUID().uuidString).mkv")
        try MatroskaFixture.copy(try fixture("h264_aac_30s.mkv"), adding: packets(), to: url)
        return url
    }

    private func waitUntil(_ timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Times survive a subtraction of an origin that is not a round number.
    private func agree(_ actual: [Double], _ expected: [Double]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.001 }
    }

    @Test("The probe reports the PGS stream as a bitmap track the host can draw")
    func probeSeesThePGSStream() throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try SourceProbe.probe(url: url)
        let track = try #require(info.bitmapSubtitleTracks.first)
        #expect(info.bitmapSubtitleTracks.count == 1)
        #expect(track.codecName.contains("pgs"))
        #expect(track.language == "eng")
        #expect(track.kind == .bitmapHostOnly)
    }

    @Test("A chosen PGS stream reaches the host as pictures, on the played timeline, ended the way the disc ends them")
    func sessionDeliversPictures() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try SourceProbe.probe(url: url)
        let stream = try #require(info.bitmapSubtitleTracks.first).streamIndex

        let session = try PrismCoreSession(url: url)
        let collector = BitmapCueCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        await session.setBitmapCueStreams([stream])
        _ = try await session.start()
        defer { Task { await session.stop() } }

        try await waitUntil { collector.cues.count >= 5 }
        let cues = collector.cues
        try #require(cues.count == 5, "five compositions in the file, one cue each")
        #expect(cues.allSatisfy { $0.streamIndex == Int32(stream) })

        // Starts as authored, relative to the first picture (the file's own
        // origin is not zero, and has been taken off).
        #expect(agree(cues.map(\.start), [2.5, 10.5, 14.5, 16.5, 19.0]), "\(cues.map(\.start))")
        // Ends: a clear, a clear, the next composition, a clear — and for E,
        // which nothing ends, the latest it could stand (19 s + the 10 s cap),
        // once the demux had read past it.
        let cap = SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds
        #expect(agree(cues.map(\.end), [4.5, 12.75, 16.5, 17.75, 19.0 + cap]), "\(cues.map(\.end))")
        #expect(cues.map(\.isForced) == [false, true, false, false, false])
        #expect(cues.map(\.frame.minX) == [100, 300, 500, 700, 900])
        #expect(cues.allSatisfy { $0.frame.size == CGSize(width: 12, height: 4) })
        #expect(cues.allSatisfy { $0.referenceSize == CGSize(width: 1920, height: 1080) })

        // The pixels are the disc's: the pill's corner transparent, its rim
        // opaque white, its body red at half strength.
        let firstCue = try #require(cues.first)
        let bytes = try bgra(firstCue.image)
        try #require(bytes.count == 12 * 4 * 4)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * 12 + x) * 4 ..< (y * 12 + x) * 4 + 4]) }
        #expect(pixel(0, 0) == [0, 0, 0, 0])
        #expect(pixel(2, 0).allSatisfy { $0 >= 253 }, "white rim, opaque")
        #expect(pixel(3, 1)[3] == 128, "the body is half transparent")
    }

    @Test("Beside a text track the PGS stream has no rendition, and the host still gets its pictures")
    func sessionDeliversPicturesBesideATextTrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrismCoreBitmapCuesText-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        try MatroskaFixture.copy(
            try fixture("h264_aac_30s.mkv"), adding: packets(),
            textPackets: [Packet(milliseconds: 5_000, durationMilliseconds: 2_000, bytes: Array("Ahoj".utf8))],
            to: url
        )
        let info = try SourceProbe.probe(url: url)
        #expect(info.subtitleTracks.count == 2)
        let stream = try #require(info.bitmapSubtitleTracks.first).streamIndex

        let session = try PrismCoreSession(url: url)
        let collector = BitmapCueCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        await session.setBitmapCueStreams([stream])
        _ = try await session.start()
        defer { Task { await session.stop() } }

        try await waitUntil { collector.cues.count >= 5 }
        #expect(collector.cues.count == 5)
        // Only the text track is declared: a PGS rendition beside a real SRT
        // would be menu noise, and the pictures need none.
        let renditions = await session.subtitleRenditions
        #expect(renditions.count == 1)
    }

    @Test("Nothing is delivered for a stream the host did not choose, nor without a choice at all")
    func sessionDeliversNothingUnchosen() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try PrismCoreSession(url: url)
        let collector = BitmapCueCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        // Another stream index chosen is the same as none.
        await session.setBitmapCueStreams([0])
        _ = try await session.start()
        defer { Task { await session.stop() } }

        // Long enough for the producer to read the whole 30 s file.
        try await Task.sleep(for: .seconds(3))
        #expect(collector.cues.isEmpty)
    }

    @Test("Chosen late, a stream has missed what the demux passed — unless the host asks for it again")
    func sessionLateChoiceAndReplay() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try #require(SourceProbe.probe(url: url).bitmapSubtitleTracks.first).streamIndex

        let session = try PrismCoreSession(url: url)
        let collector = BitmapCueCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        // Nothing chosen yet; and nothing asked to be read again before start.
        #expect(await session.setBitmapCueStreams([], replayingFrom: 0) == false)
        _ = try await session.start()
        defer { Task { await session.stop() } }
        // The producer reads the whole short file and parks at its end.
        try await Task.sleep(for: .seconds(3))
        #expect(collector.cues.isEmpty)

        // Chosen now, with no position: the demux is at the end of the file,
        // and a stream chosen from here sees nothing.
        #expect(await session.setBitmapCueStreams([stream]) == false)
        try await Task.sleep(for: .seconds(1))
        #expect(collector.cues.isEmpty, "the pictures the demux already passed are not kept")

        // Asked for from 22 s on the player's clock, the producer reads again
        // from 10 s before it (the longest a picture stands) — 12 s, in the
        // segment that opens at 8 s: B, C, D and E come, not A.
        #expect(await session.setBitmapCueStreams([stream], replayingFrom: 22) == true)
        try await waitUntil { collector.cues.count >= 4 }
        try await Task.sleep(for: .seconds(1))
        let cues = collector.cues
        #expect(agree(cues.map(\.start), [10.5, 14.5, 16.5, 19.0]), "\(cues.map(\.start))")
        #expect(cues.map(\.isForced) == [true, false, false, false])
    }

    @Test("A redelivered cue is the same cue by identity, and a new image")
    func sessionRedeliveryKeepsIdentity() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try #require(SourceProbe.probe(url: url).bitmapSubtitleTracks.first).streamIndex

        let session = try PrismCoreSession(url: url)
        let collector = BitmapCueCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        await session.setBitmapCueStreams([stream])
        _ = try await session.start()
        defer { Task { await session.stop() } }
        try await waitUntil { collector.cues.count >= 5 }
        let first = collector.cues

        // From the very beginning: everything again.
        #expect(await session.setBitmapCueStreams([stream], replayingFrom: 0) == true)
        try await waitUntil { collector.cues.count >= 10 }
        try await Task.sleep(for: .seconds(1))
        let all = collector.cues
        #expect(all.count == 10, "five and five again, nothing skipped and nothing doubled")
        #expect(Set(all.map(\.id)).count == 5, "the second five are the first five by identity")
        #expect(zip(first, all.dropFirst(5)).allSatisfy { $0.id == $1.id && $0.image !== $1.image })
    }

    @Test("A session made after a master rejection carries the handler and the choice")
    func fallbackSessionCarriesTheChoice() async throws {
        let url = try makeFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try #require(SourceProbe.probe(url: url).bitmapSubtitleTracks.first).streamIndex

        let session = try PrismCoreSession(url: url)
        let collector = BitmapCueCollector()
        await session.setBitmapCueHandler { collector.append($0) }
        await session.setBitmapCueStreams([stream])
        // The first session never starts: AVPlayer refused its master.
        let fallback = try await session.makeMasterRejectionFallbackSession()
        await session.stop()
        _ = try await fallback.start()
        defer { Task { await fallback.stop() } }

        try await waitUntil { collector.cues.count >= 5 }
        #expect(collector.cues.count == 5, "the clone delivers to the handler the host registered on its predecessor")
    }
}
