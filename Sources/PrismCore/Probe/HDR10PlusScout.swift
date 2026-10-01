import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// What the **bitstream** said about HDR10+ (SMPTE ST 2094-40 dynamic
/// metadata) on the video track — the counterpart of `ObjectAudioFinding` for
/// the other premium format that no container declares.
///
/// ### Why a bitstream read, and why three answers
///
/// Nothing a container or `AVCodecParameters` carries says "HDR10+": the
/// metadata rides per picture, inside the HEVC (or H.264) elementary stream,
/// as an SEI `user_data_registered_itu_t_t35` message whose T.35 header is
/// Samsung's. A stream-copy carries those SEI units through untouched, so the
/// metadata already reaches AVPlayer; what was missing was *knowing*, so a
/// host can badge a title or log what it played.
///
/// The only way to know is to look at packets, and looking is bounded. So the
/// answer is deliberately ternary — `seen`, `notSeenWithinBudget`, `unknown` —
/// and never "absent": a scan that read its budget and found nothing has
/// learned exactly that, and a source whose encoder only writes the message
/// at scene changes further in would say the same thing.
public struct HDR10PlusFinding: Sendable, Equatable {

    public enum Verdict: Sendable, Equatable {
        /// An ST 2094-40 message was read out of a video packet.
        case seen
        /// The scan read its budget (or the whole stream, if shorter) and
        /// found no ST 2094-40 message. **Not proof of absence.**
        case notSeenWithinBudget
        /// The scan could not ask the question; see the reason.
        case unknown(UnknownReason)
    }

    public enum UnknownReason: String, Sendable, Equatable {
        /// The codec is not one whose SEI this scout walks (AV1 carries
        /// ST 2094-40 in a metadata OBU, VP9 only in container side data).
        case codecNotScanned
        /// The input cannot seek. The scan consumes packets, and an adopting
        /// producer that cannot rewind would lose the head of the stream to
        /// it — a worse trade than a badge.
        case unseekableInput
        /// A read failed (or the probe budget interrupted it) before the scan
        /// had spent its budget, so its silence means nothing.
        case readFailed
        /// No video packet arrived within the scan's overall packet cap.
        case noVideoPackets
    }

    /// The source stream this describes — the video track `SourceInfo.video`
    /// reports.
    public let streamIndex: Int
    public let verdict: Verdict
    /// `application_version` of the first message seen (0 or 1 — the two
    /// versions ST 2094-40's T.35 carriage defines). `nil` unless `seen`.
    public let applicationVersion: Int?
    /// Video packets actually walked. On `seen` this is the packet the message
    /// was found in (1 = the first).
    public let videoPacketsScanned: Int
    /// The budget the scan was given, so a host can tell "read 24 of 24" from
    /// "read 3 and the stream ended".
    public let videoPacketBudget: Int

    /// Whether the bitstream carries HDR10+ metadata, as far as this scan saw.
    public var isSeen: Bool { verdict == .seen }

    /// Whether the scan moved the read position of the context it ran on.
    /// Only the two refusals leave it untouched; everything else read at least
    /// one packet. An adopting producer keys its early rewind on this.
    var consumedPackets: Bool {
        switch verdict {
        case .unknown(.codecNotScanned), .unknown(.unseekableInput): return false
        default: return true
        }
    }

    public init(
        streamIndex: Int,
        verdict: Verdict,
        applicationVersion: Int?,
        videoPacketsScanned: Int,
        videoPacketBudget: Int
    ) {
        self.streamIndex = streamIndex
        self.verdict = verdict
        self.applicationVersion = applicationVersion
        self.videoPacketsScanned = videoPacketsScanned
        self.videoPacketBudget = videoPacketBudget
    }
}

/// Whether `SourceProbe.open` should read video packets to look for HDR10+.
///
/// Off by default, for the same reason `SourceStructureExport` is: the probe
/// is on the path to the routing verdict, and every packet the scout reads
/// past what `avformat_find_stream_info` already buffered is I/O the user
/// waits through. A host that shows the answer (a detail page, a badge) asks;
/// a host that only routes does not pay.
public enum HDR10PlusScan: Sendable, Equatable {
    /// No scan. `SourceInfo.hdr10Plus` stays `nil`.
    case off
    /// Walk at most this many video packets, stopping at the first message.
    case scan(videoPackets: Int)

    /// One second of pictures at 24 fps. The scan stops at the first message,
    /// and an encoder driven by per-frame metadata (x265's `--dhdr10-info`
    /// takes one JSON entry per picture) writes one into every access unit,
    /// so on such a source the answer comes from the first video packet. The
    /// full budget is paid by a source that carries none — which is why it
    /// is a budget, and why its silence is `notSeenWithinBudget`.
    public static let standard = HDR10PlusScan.scan(videoPackets: 24)

    var videoPacketBudget: Int? {
        switch self {
        case .off: return nil
        case .scan(let packets): return max(1, packets)
        }
    }
}

/// The packet walk behind `HDR10PlusFinding`. Shares the NAL framing and the
/// SEI message loop with the closed-caption reader (`HEVCNALUnits`); only the
/// T.35 header test is its own.
enum HDR10PlusScout {

    /// Packets of any stream to walk past per budgeted video packet — a bound
    /// for a container whose interleaving is pathological (a UHD remux with
    /// eight audio tracks still interleaves far tighter than this).
    static let packetsPerVideoPacket = 16

    /// The `application_version` of an ST 2094-40 T.35 message, or `nil` for
    /// any other registered user data.
    ///
    /// `itu_t_t35_country_code` 0xB5, `terminal_provider_code` 0x003C
    /// (Samsung), `terminal_provider_oriented_code` 0x0001,
    /// `application_identifier` 4. The version is checked too: 0 and 1 are
    /// the ones defined, and a message claiming a later one is a format this
    /// code has not read the syntax of — calling that HDR10+ would be a guess.
    static func applicationVersion(inT35 message: ArraySlice<UInt8>) -> Int? {
        guard message.count >= 6 else { return nil }
        let bytes = message.startIndex
        guard message[bytes] == 0xB5,
              message[bytes + 1] == 0x00, message[bytes + 2] == 0x3C,
              message[bytes + 3] == 0x00, message[bytes + 4] == 0x01,
              message[bytes + 5] == 0x04
        else { return nil }
        // The version byte is past the fixed header; a message that stops
        // right after the identifier has no version and no payload to be.
        guard message.count >= 7 else { return nil }
        let version = Int(message[bytes + 6])
        return version <= 1 ? version : nil
    }

    /// The `application_version` of the first ST 2094-40 message in one
    /// compressed video packet, or `nil`.
    static func applicationVersion(
        inPacket bytes: UnsafeBufferPointer<UInt8>,
        framing: HEVCNALUnits.Framing,
        codec: HEVCNALUnits.Codec
    ) -> Int? {
        var found: Int?
        HEVCNALUnits.scan(bytes, framing: framing, codec: codec) { type, payload in
            guard found == nil, HEVCNALUnits.isSEI(type, codec: codec) else { return }
            HEVCNALUnits.forEachSEIMessage(inSEINAL: payload) { payloadType, message in
                guard payloadType == HEVCNALUnits.t35PayloadType,
                      let version = applicationVersion(inT35: message)
                else { return true }
                found = version
                return false
            }
        }
        return found
    }

    /// Consume packets from `input` looking for ST 2094-40. **Leaves the read
    /// position where it stopped** — an adopting producer rewinds (it already
    /// must, after the interlace verification), and a one-shot probe context
    /// is closed.
    static func scan(
        input: UnsafeMutablePointer<AVFormatContext>,
        video: VideoTrackInfo,
        videoPacketBudget: Int
    ) -> HDR10PlusFinding {
        let streamIndex = Int32(video.streamIndex)
        func finding(_ verdict: HDR10PlusFinding.Verdict, version: Int? = nil, scanned: Int = 0) -> HDR10PlusFinding {
            HDR10PlusFinding(
                streamIndex: video.streamIndex, verdict: verdict, applicationVersion: version,
                videoPacketsScanned: scanned, videoPacketBudget: videoPacketBudget
            )
        }

        guard streamIndex >= 0, streamIndex < Int32(input.pointee.nb_streams),
              let stream = input.pointee.streams[Int(streamIndex)],
              let carriage = HEVCNALUnits.carriage(
                  codecID: stream.pointee.codecpar.pointee.codec_id,
                  nalUnitLengthSize: video.nalUnitLengthSize
              )
        else { return finding(.unknown(.codecNotScanned)) }
        // No pb is a demuxer that reads itself (none of ours); treat it like
        // an input that cannot be rewound, which is the property that matters.
        guard let pb = input.pointee.pb, pb.pointee.seekable != 0 else {
            return finding(.unknown(.unseekableInput))
        }
        guard let packet = av_packet_alloc() else { return finding(.unknown(.readFailed)) }
        var packetRef: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetRef) }

        let packetCap = videoPacketBudget * packetsPerVideoPacket
        var videoPackets = 0
        var packets = 0
        while videoPackets < videoPacketBudget, packets < packetCap {
            let result = av_read_frame(input, packet)
            if result < 0 {
                if result == swift_AVERROR_EOF() { break }
                return finding(.unknown(.readFailed), scanned: videoPackets)
            }
            defer { av_packet_unref(packet) }
            packets += 1
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0
            else { continue }
            videoPackets += 1
            let bytes = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
            if let version = applicationVersion(
                inPacket: bytes, framing: carriage.framing, codec: carriage.codec
            ) {
                return finding(.seen, version: version, scanned: videoPackets)
            }
        }
        guard videoPackets > 0 else { return finding(.unknown(.noVideoPackets)) }
        return finding(.notSeenWithinBudget, scanned: videoPackets)
    }
}
