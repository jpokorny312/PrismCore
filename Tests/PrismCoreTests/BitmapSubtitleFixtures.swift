import Foundation
import Libavcodec
import Libavformat
import Libavutil
@testable import PrismCore

/// Bitmap subtitle packets assembled by hand, byte by byte, from the formats'
/// own layouts.
///
/// No FFmpeg build can *encode* PGS, DVB or DVD subtitles (this one has the
/// decoders only), so nothing a test could commit carries them. What a test
/// can do is write the bytes a disc's authoring tool would have written and
/// let the real libavcodec decoder read them. That proves the path from
/// packet to `BitmapCue` — the decoder's palette, alpha, position, forced flag
/// and frame size, and PrismCore's use of them — against the real decoder. It
/// does **not** prove the decoder copes with a real disc's quirks (cropped
/// objects, objects split over packets, palette-only updates, fades); that is
/// what the opt-in `RealMediaPGSTests` run is for.
enum PGSFixture {

    /// One palette entry as a PGS palette segment stores it: YCrCb and alpha.
    struct Entry {
        let index: UInt8
        let y: UInt8
        let cr: UInt8
        let cb: UInt8
        let alpha: UInt8

        /// Limited-range white / black / transparent are the three colours the
        /// tests lean on, because their RGB is exact whatever the matrix.
        static func white(_ index: UInt8, alpha: UInt8 = 255) -> Entry {
            Entry(index: index, y: 235, cr: 128, cb: 128, alpha: alpha)
        }
        static func black(_ index: UInt8, alpha: UInt8 = 255) -> Entry {
            Entry(index: index, y: 16, cr: 128, cb: 128, alpha: alpha)
        }
        static func clear(_ index: UInt8) -> Entry {
            Entry(index: index, y: 16, cr: 128, cb: 128, alpha: 0)
        }
    }

    /// One composition object: a bitmap and where it sits.
    struct Object {
        var id: UInt16 = 0
        var windowID: UInt8 = 0
        var forced = false
        var x: Int
        var y: Int
        /// Palette indices, one array per row; every row the same length.
        var rows: [[UInt8]]

        var width: Int { rows.first?.count ?? 0 }
        var height: Int { rows.count }
    }

    // MARK: - Segments

    private static let paletteSegment: UInt8 = 0x14
    private static let objectSegment: UInt8 = 0x15
    private static let presentationSegment: UInt8 = 0x16
    private static let windowSegment: UInt8 = 0x17
    private static let endSegment: UInt8 = 0x80

    private static func segment(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        [type] + be16(payload.count) + payload
    }

    private static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    private static func be24(_ value: Int) -> [UInt8] {
        [UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// PGS run-length coding of one object, as `decode_rle` in libavcodec
    /// reads it: a literal non-zero index is one byte; anything else is
    /// `00 flags [length-low] [colour]` (bit 7: a colour follows, bit 6: a
    /// 14-bit length); `00 00` ends a row.
    static func runLengthEncoded(_ rows: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        for row in rows {
            var position = 0
            while position < row.count {
                let colour = row[position]
                var run = 1
                while position + run < row.count, row[position + run] == colour, run < 0x3FFF { run += 1 }
                position += run
                if colour != 0, run <= 2 {
                    bytes.append(contentsOf: [UInt8](repeating: colour, count: run))
                    continue
                }
                var flags: UInt8 = colour != 0 ? 0x80 : 0
                if run < 0x40 {
                    flags |= UInt8(run)
                    bytes.append(contentsOf: [0x00, flags])
                } else {
                    flags |= 0x40 | UInt8(run >> 8)
                    bytes.append(contentsOf: [0x00, flags, UInt8(run & 0xFF)])
                }
                if colour != 0 { bytes.append(colour) }
            }
            bytes.append(contentsOf: [0x00, 0x00])
        }
        return bytes
    }

    /// The five segments of a display set, in the order a Matroska PGS packet
    /// carries them (the container strips the `PG` header of a `.sup` file).
    ///
    /// - Parameters:
    ///   - video: the size of the frame the object coordinates are measured in;
    ///     PGS states it in every presentation segment.
    ///   - epochStart: `0x80` (a new epoch: earlier objects and palettes are
    ///     released) or `0x00` (a normal case, which may refer to the earlier
    ///     ones).
    static func displaySet(
        video: (width: Int, height: Int) = (1920, 1080),
        compositionNumber: Int = 1,
        epochStart: Bool = true,
        paletteID: UInt8 = 0,
        palette: [Entry],
        objects: [Object],
        defineObjects: Bool = true
    ) -> [UInt8] {
        var bytes: [UInt8] = []

        // Presentation: frame size, frame rate, composition number and state,
        // palette-update flag, palette id, then the objects it shows.
        var presentation: [UInt8] = be16(video.width) + be16(video.height)
        presentation += [0x10] + be16(compositionNumber)
        presentation += [epochStart ? 0x80 : 0x00, 0x00, paletteID, UInt8(objects.count)]
        for object in objects {
            presentation += be16(Int(object.id)) + [object.windowID, object.forced ? 0x40 : 0x00]
            presentation += be16(object.x) + be16(object.y)
        }
        bytes += segment(presentationSegment, presentation)

        // Windows: libavcodec reads none of it, but a real disc has them.
        var windows: [UInt8] = [UInt8(Set(objects.map(\.windowID)).count)]
        for windowID in Set(objects.map(\.windowID)).sorted() {
            let owners = objects.filter { $0.windowID == windowID }
            let left = owners.map(\.x).min() ?? 0
            let top = owners.map(\.y).min() ?? 0
            let right = owners.map { $0.x + $0.width }.max() ?? 0
            let bottom = owners.map { $0.y + $0.height }.max() ?? 0
            windows += [windowID] + be16(left) + be16(top) + be16(right - left) + be16(bottom - top)
        }
        bytes += segment(windowSegment, windows)

        if defineObjects {
            var paletteBytes: [UInt8] = [paletteID, 0x00]
            for entry in palette {
                paletteBytes += [entry.index, entry.y, entry.cr, entry.cb, entry.alpha]
            }
            bytes += segment(paletteSegment, paletteBytes)

            for object in objects {
                let data = runLengthEncoded(object.rows)
                var payload: [UInt8] = be16(Int(object.id)) + [0x00, 0xC0]   // first and last fragment
                payload += be24(data.count + 4) + be16(object.width) + be16(object.height)
                bytes += segment(objectSegment, payload + data)
            }
        }
        bytes += segment(endSegment, [])
        return bytes
    }

    /// A display set that shows nothing — how PGS takes a subtitle down.
    static func clear(
        video: (width: Int, height: Int) = (1920, 1080), compositionNumber: Int = 2
    ) -> [UInt8] {
        var presentation: [UInt8] = be16(video.width) + be16(video.height)
        presentation += [0x10] + be16(compositionNumber) + [0x00, 0x00, 0x00, 0x00]
        return segment(presentationSegment, presentation)
            + segment(windowSegment, [0x00])
            + segment(endSegment, [])
    }
}

/// Packets and codec parameters for the decoder, and the matching clean-up.
enum SubtitlePacketFixture {

    /// Codec parameters for a subtitle stream, owned by the caller.
    static func parameters(
        codec: AVCodecID, extradata: [UInt8] = [], width: Int32 = 0, height: Int32 = 0
    ) -> UnsafeMutablePointer<AVCodecParameters> {
        let parameters = avcodec_parameters_alloc()!
        parameters.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        parameters.pointee.codec_id = codec
        parameters.pointee.width = width
        parameters.pointee.height = height
        if !extradata.isEmpty {
            parameters.pointee.extradata = av_mallocz(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))
                .assumingMemoryBound(to: UInt8.self)
            parameters.pointee.extradata.update(from: extradata, count: extradata.count)
            parameters.pointee.extradata_size = Int32(extradata.count)
        }
        return parameters
    }

    static func free(_ parameters: UnsafeMutablePointer<AVCodecParameters>) {
        var parameters: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&parameters)
    }

    /// A packet carrying `bytes`, stamped at `milliseconds` on a 1/1000 time
    /// base (what Matroska uses). Free it with `free(_:)`.
    static func packet(
        _ bytes: [UInt8], atMilliseconds milliseconds: Int64, durationMilliseconds: Int64 = 0,
        streamIndex: Int32 = 0
    ) -> UnsafeMutablePointer<AVPacket> {
        let packet = av_packet_alloc()!
        av_new_packet(packet, Int32(bytes.count))
        packet.pointee.data.update(from: bytes, count: bytes.count)
        packet.pointee.pts = milliseconds
        packet.pointee.dts = milliseconds
        packet.pointee.duration = durationMilliseconds
        packet.pointee.stream_index = streamIndex
        return packet
    }

    static func free(_ packet: UnsafeMutablePointer<AVPacket>) {
        var packet: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packet)
    }

    static let millisecondTimeBase = AVRational(num: 1, den: 1000)
}

/// A DVD sub-picture unit assembled by hand, as a VobSub track in a Matroska
/// file stores it: a size, a pointer to the control sequences, the run-length
/// coded rows of the two interlaced fields, then the control sequences that
/// say when to show it, in which colours, and where.
enum DVDFixture {

    /// What Matroska keeps in a VobSub track's `CodecPrivate`: the `.idx`
    /// header. `size:` is the only place a DVD stream states its frame.
    static func extradata(size: (width: Int, height: Int) = (720, 480)) -> [UInt8] {
        let palette = [
            "000000", "ffffff", "ff0000", "00ff00", "0000ff", "ffff00", "00ffff", "ff00ff",
            "808080", "400000", "004000", "000040", "404000", "004040", "400040", "c0c0c0",
        ]
        let text = "# VobSub index file, v7 (do not modify this line!)\n"
            + "size: \(size.width)x\(size.height)\n"
            + "palette: \(palette.joined(separator: ", "))\n"
        return Array(text.utf8)
    }

    /// One field's rows as DVD run-length nibbles: a run of `n` pixels of
    /// colour `c` (0…3) is the number `n << 2 | c` in 4, 8, 12 or 16 bits
    /// depending on how long the run is; every row ends on a byte boundary.
    static func runLengthEncoded(_ rows: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = []
        for row in rows {
            var nibbles: [UInt8] = []
            var position = 0
            while position < row.count {
                let colour = row[position]
                var run = 1
                while position + run < row.count, row[position + run] == colour, run < 255 { run += 1 }
                position += run
                let code = (run << 2) | Int(colour)
                let digits = run < 4 ? 1 : run < 16 ? 2 : run < 64 ? 3 : 4
                for shift in stride(from: (digits - 1) * 4, through: 0, by: -4) {
                    nibbles.append(UInt8((code >> shift) & 0xF))
                }
            }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
            for pair in stride(from: 0, to: nibbles.count, by: 2) {
                bytes.append(nibbles[pair] << 4 | nibbles[pair + 1])
            }
        }
        return bytes
    }

    /// - Parameters:
    ///   - rows: colour numbers 0…3 per pixel, top to bottom; the even rows go
    ///     to the first field and the odd rows to the second.
    ///   - stopDate: when the sub-picture ends, in the DVD's own units
    ///     (1024/90000 s each); 200 is 2.275 s.
    ///   - forced: the "forced start display" command instead of the ordinary
    ///     one — what a disc's forced-subtitle track is made of.
    ///   - colourMap: which of the sixteen palette entries each of the four
    ///     colours is.
    ///   - alphas: each colour's opacity, 0…15.
    static func packet(
        x: Int, y: Int, rows: [[UInt8]], stopDate: Int = 200, forced: Bool = false,
        colourMap: [UInt8] = [0, 1, 2, 3], alphas: [UInt8] = [0, 15, 15, 8]
    ) -> [UInt8] {
        let first = runLengthEncoded(rows.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        let second = runLengthEncoded(rows.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
        let width = rows.first?.count ?? 0
        let (x1, x2) = (x, x + width - 1)
        // Inclusive, as the DVD specification has it. (FFmpeg once read the
        // height as y2 − y1, a line short; this build's decoder reads it
        // inclusively — a box written the old way decodes one row too tall,
        // with the second field's first row where the first field's last
        // should be.)
        let (y1, y2) = (y, y + rows.count - 1)

        func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
        let controlStart = 4 + first.count + second.count

        var showCommands: [UInt8] = [forced ? 0x00 : 0x01]
        showCommands += [0x03, colourMap[3] << 4 | colourMap[2], colourMap[1] << 4 | colourMap[0]]
        showCommands += [0x04, alphas[3] << 4 | alphas[2], alphas[1] << 4 | alphas[0]]
        showCommands += [
            0x05, UInt8(x1 >> 4), UInt8((x1 & 0xF) << 4 | x2 >> 8), UInt8(x2 & 0xFF),
            UInt8(y1 >> 4), UInt8((y1 & 0xF) << 4 | y2 >> 8), UInt8(y2 & 0xFF),
        ]
        showCommands += [0x06] + be16(4) + be16(4 + first.count)
        showCommands += [0xFF]
        let stopStart = controlStart + 4 + showCommands.count

        var bytes: [UInt8] = []
        bytes += be16(stopStart + 4 + 2)             // total size
        bytes += be16(controlStart)                   // where the control sequences start
        bytes += first + second
        bytes += be16(0) + be16(stopStart) + showCommands
        bytes += be16(stopDate) + be16(stopStart) + [0x02, 0xFF]   // its own next-pointer: the last one
        return bytes
    }
}

/// A DVB subtitle display set (ETSI EN 300 743) assembled by hand, as a
/// Matroska DVB track stores it: the subtitling segments of one PES packet,
/// each opening with the sync byte `0x0F`.
enum DVBFixture {

    /// A colour of the CLUT as a broadcaster writes it: YCrCb and *transparency*
    /// (0 opaque … 255 invisible), the other way round from alpha.
    struct Entry {
        let index: UInt8
        let y: UInt8
        let cr: UInt8
        let cb: UInt8
        let transparency: UInt8
    }

    private static func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    private static func segment(_ type: UInt8, page: Int = 1, _ payload: [UInt8]) -> [UInt8] {
        [0x0F, type] + be16(page) + be16(payload.count) + payload
    }

    /// The 8-bit pixel code string of one object line: a literal non-zero
    /// code is one byte, a run of zeros `00 0LLLLLLL`, a run of another code
    /// `00 1LLLLLLL code`, and `00 00` ends the string.
    static func eightBitString(_ row: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        var position = 0
        while position < row.count {
            let code = row[position]
            var run = 1
            while position + run < row.count, row[position + run] == code, run < 127 { run += 1 }
            position += run
            if code != 0, run == 1 {
                bytes.append(code)
            } else if code == 0 {
                bytes += [0x00, UInt8(run)]
            } else {
                bytes += [0x00, 0x80 | UInt8(run), code]
            }
        }
        return bytes + [0x00, 0x00]
    }

    /// One region holding one object that fills it.
    ///
    /// - Parameters:
    ///   - pageTimeOut: seconds after which the page is no longer valid —
    ///     DVB's only statement of how long a subtitle stands, and a ceiling
    ///     rather than an end: the next page replaces this one.
    ///   - displayDefinition: the display size a broadcaster declares for HD
    ///     subtitles (a display definition segment); without one the stream
    ///     says nothing about its frame.
    ///   - version: the page version (4 bits). A page whose version equals the
    ///     one on screen is a repeat, and the decoder ignores it — so every new
    ///     subtitle needs the next number.
    static func displaySet(
        x: Int, y: Int, rows: [[UInt8]], palette: [Entry], pageTimeOut: Int = 6, version: Int = 0,
        displayDefinition: (width: Int, height: Int)? = nil
    ) -> [UInt8] {
        let width = rows.first?.count ?? 0
        var bytes: [UInt8] = []

        if let displayDefinition {
            bytes += segment(0x14, [0x00] + be16(displayDefinition.width - 1) + be16(displayDefinition.height - 1))
        }
        // Page: time-out, "mode change" state, then the region and where it goes.
        bytes += segment(0x10, [UInt8(pageTimeOut), UInt8(version << 4) | 0x08, 0x00, 0x00] + be16(x) + be16(y))
        // Region: filled with code 0, 8 bits deep, using CLUT 0, one object at its corner.
        bytes += segment(0x11, [0x00, 0x08] + be16(width) + be16(rows.count) + [0x2F, 0x00, 0x00, 0x00]
            + be16(0) + be16(0) + be16(0))
        var clut: [UInt8] = [0x00, 0x00]
        for entry in palette {
            clut += [entry.index, 0x21, entry.y, entry.cr, entry.cb, entry.transparency]
        }
        bytes += segment(0x12, clut)

        // The object: even rows in the top field, odd rows in the bottom.
        func field(_ parity: Int) -> [UInt8] {
            rows.enumerated().filter { $0.offset % 2 == parity }
                .flatMap { [0x12] + eightBitString($0.element) + [0xF0] }
        }
        let top = field(0)
        let bottom = field(1)
        bytes += segment(0x13, be16(0) + [0x00] + be16(top.count) + be16(bottom.count) + top + bottom)
        bytes += segment(0x80, [])
        return bytes
    }

    /// A page with no region: how a broadcaster erases the screen before the
    /// time-out would.
    static func emptyPage(pageTimeOut: Int = 6, version: Int = 0) -> [UInt8] {
        segment(0x10, [UInt8(pageTimeOut), UInt8(version << 4) | 0x08]) + segment(0x80, [])
    }
}

/// A Matroska file with a hand-assembled subtitle stream in it, written at test
/// time: the video and audio of a committed fixture, copied packet by packet,
/// and one more stream whose packets the test supplies.
///
/// Written rather than committed because the stream's content is the thing
/// each test varies, and because a committed `.mkv` with a PGS track would
/// look like evidence of real PGS media. It is not: see `PGSFixture`.
enum MatroskaFixture {

    struct SubtitlePacket {
        let milliseconds: Int64
        let durationMilliseconds: Int64
        let bytes: [UInt8]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ code: Int32, _ what: String) throws {
        guard code >= 0 else { throw Failure(description: "\(what) failed with \(code)") }
    }

    /// Copy the video and audio of `source` into `destination` and add a
    /// subtitle stream of `codec` made of `packets`.
    ///   - textPackets: if any, a SubRip stream beside it — a source with a text
    ///     track is one where the bitmap stream gets no OCR rendition.
    static func copy(
        _ source: URL, adding packets: [SubtitlePacket], codec: AVCodecID = AV_CODEC_ID_HDMV_PGS_SUBTITLE,
        extradata: [UInt8] = [], language: String = "eng", textPackets: [SubtitlePacket] = [], to destination: URL
    ) throws {
        var input: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&input, source.path, nil, nil), "open \(source.lastPathComponent)")
        defer { avformat_close_input(&input) }
        try check(avformat_find_stream_info(input, nil), "stream info")
        guard let input else { throw Failure(description: "no input") }

        var output: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&output, nil, "matroska", destination.path), "output context")
        guard let output else { throw Failure(description: "no output") }
        defer {
            if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }
            avformat_free_context(output)
        }

        var mapping: [Int: Int32] = [:]
        for index in 0..<Int(input.pointee.nb_streams) {
            let inStream = input.pointee.streams[index]!
            let type = inStream.pointee.codecpar.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO else { continue }
            let outStream = avformat_new_stream(output, nil)!
            try check(avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar), "copy parameters")
            outStream.pointee.codecpar.pointee.codec_tag = 0
            outStream.pointee.time_base = inStream.pointee.time_base
            mapping[index] = outStream.pointee.index
        }

        let subtitleStream = avformat_new_stream(output, nil)!
        subtitleStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        subtitleStream.pointee.codecpar.pointee.codec_id = codec
        subtitleStream.pointee.time_base = SubtitlePacketFixture.millisecondTimeBase
        if !extradata.isEmpty {
            let buffer = av_mallocz(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!
                .assumingMemoryBound(to: UInt8.self)
            buffer.update(from: extradata, count: extradata.count)
            subtitleStream.pointee.codecpar.pointee.extradata = buffer
            subtitleStream.pointee.codecpar.pointee.extradata_size = Int32(extradata.count)
        }
        av_dict_set(&subtitleStream.pointee.metadata, "language", language, 0)
        let subtitleIndex = subtitleStream.pointee.index

        var textIndex: Int32?
        if !textPackets.isEmpty {
            let textStream = avformat_new_stream(output, nil)!
            textStream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            textStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_SUBRIP
            textStream.pointee.time_base = SubtitlePacketFixture.millisecondTimeBase
            av_dict_set(&textStream.pointee.metadata, "language", language, 0)
            textIndex = textStream.pointee.index
        }

        try check(avio_open(&output.pointee.pb, destination.path, AVIO_FLAG_WRITE), "open output")
        try check(avformat_write_header(output, nil), "write header")

        // Everything in one list, ordered by decode time, so the muxer sees a
        // sane interleave whatever order the pieces were made in.
        var queue: [(seconds: Double, packet: UnsafeMutablePointer<AVPacket>)] = []
        defer { for entry in queue { var packet: UnsafeMutablePointer<AVPacket>? = entry.packet; av_packet_free(&packet) } }

        var scratch = av_packet_alloc()
        defer { av_packet_free(&scratch) }
        while av_read_frame(input, scratch) >= 0 {
            defer { av_packet_unref(scratch) }
            guard let outIndex = mapping[Int(scratch!.pointee.stream_index)] else { continue }
            let inStream = input.pointee.streams[Int(scratch!.pointee.stream_index)]!
            let outStream = output.pointee.streams[Int(outIndex)]!
            let packet = av_packet_clone(scratch)!
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet.pointee.stream_index = outIndex
            packet.pointee.pos = -1
            let stamp = packet.pointee.dts != swift_AV_NOPTS_VALUE() ? packet.pointee.dts : packet.pointee.pts
            queue.append((Double(stamp) * av_q2d(outStream.pointee.time_base), packet))
        }

        // Matroska stores presentation times only, so the demuxer has to work
        // out decode times, and cannot for the first few pictures of a stream
        // with B-frames: they come out with none. The muxer wants them, one
        // frame apart and ahead of the first one the demuxer did work out — the
        // numbers an encoder would have written.
        for index in mapping.values {
            let stream = queue.indices.filter { queue[$0].packet.pointee.stream_index == index }
            guard let firstKnown = stream.firstIndex(where: { queue[$0].packet.pointee.dts != swift_AV_NOPTS_VALUE() })
            else {
                for position in stream { queue[position].packet.pointee.dts = queue[position].packet.pointee.pts }
                continue
            }
            let step = max(1, queue[stream[firstKnown]].packet.pointee.duration)
            for (offset, position) in stream[..<firstKnown].enumerated() {
                queue[position].packet.pointee.dts =
                    queue[stream[firstKnown]].packet.pointee.dts - Int64(firstKnown - offset) * step
            }
        }
        // …which puts the first of them before zero, where Matroska has no
        // room: everything moves later by the same amount, the subtitles
        // included, so a subtitle at 2.0 s is still 2.0 s after the first picture.
        let timeBase = av_q2d(SubtitlePacketFixture.millisecondTimeBase)
        let earliest = queue.map { Double($0.packet.pointee.dts) * av_q2d(output.pointee.streams[Int($0.packet.pointee.stream_index)]!.pointee.time_base) }.min() ?? 0
        let shiftMilliseconds = Int64((max(0, -earliest) / timeBase).rounded(.up))
        for index in queue.indices {
            let packet = queue[index].packet
            let stream = output.pointee.streams[Int(packet.pointee.stream_index)]!
            let shift = av_rescale_q(shiftMilliseconds, SubtitlePacketFixture.millisecondTimeBase, stream.pointee.time_base)
            packet.pointee.pts += shift
            packet.pointee.dts += shift
            // Ordered by what is written now, not by what was read.
            queue[index].seconds = Double(packet.pointee.dts) * av_q2d(stream.pointee.time_base)
        }
        for entry in packets {
            let packet = SubtitlePacketFixture.packet(
                entry.bytes, atMilliseconds: entry.milliseconds + shiftMilliseconds,
                durationMilliseconds: entry.durationMilliseconds, streamIndex: subtitleIndex
            )
            queue.append((Double(entry.milliseconds + shiftMilliseconds) / 1000, packet))
        }
        if let textIndex {
            for entry in textPackets {
                let packet = SubtitlePacketFixture.packet(
                    entry.bytes, atMilliseconds: entry.milliseconds + shiftMilliseconds,
                    durationMilliseconds: entry.durationMilliseconds, streamIndex: textIndex
                )
                queue.append((Double(entry.milliseconds + shiftMilliseconds) / 1000, packet))
            }
        }
        // Ordered by decode time; equal times keep the order they were made in.
        queue = queue.enumerated().sorted {
            ($0.element.seconds, $0.offset) < ($1.element.seconds, $1.offset)
        }.map(\.element)

        for entry in queue {
            // The muxer takes ownership of the data, not of the struct.
            let packet = av_packet_clone(entry.packet)!
            defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
            try check(av_interleaved_write_frame(output, packet), "write packet")
        }
        try check(av_write_trailer(output), "write trailer")
    }
}
