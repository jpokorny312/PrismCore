import Foundation

/// Pulls ATSC A/53 Part 4 §6.2.3 `cc_data` out of a compressed video packet.
///
/// Closed captions are not a demuxable stream: they ride *inside* the video
/// elementary stream, in an SEI `user_data_registered_itu_t_t35` message whose
/// T.35 payload is claimed by ATSC (`GA94`). Every access unit that carries
/// captions carries one, holding a handful of byte triplets — the caption
/// bytes for that one frame, on the frame's own presentation time.
///
/// This type does the carriage only: bytes in, triplets out. What the triplets
/// *mean* is `CEA608Decoder`'s business, and the reordering that turns their
/// decode-order arrival into presentation order is `ClosedCaptionReader`'s.
enum A53CaptionData {

    /// One `cc_data` triplet: two caption bytes plus which wire they were on.
    struct Triplet: Equatable {
        /// `cc_valid`. A frame reserves room for a fixed triplet count and
        /// marks the unused ones invalid; feeding those to the decoder would
        /// inject whatever the encoder left in the buffer.
        let isValid: Bool
        /// `cc_type`: 0 = NTSC field 1 (CEA-608), 1 = NTSC field 2 (CEA-608),
        /// 2 = DTVCC packet continuation, 3 = DTVCC packet start (CEA-708).
        let type: UInt8
        let data0: UInt8
        let data1: UInt8

        /// The CEA-608 field this triplet belongs to, or `nil` for the DTVCC
        /// types (see `ClosedCaptionReader` for why those are declined).
        var cea608Field: Int? {
            guard isValid else { return nil }
            switch type {
            case 0: return 1
            case 1: return 2
            default: return nil
            }
        }
    }

    /// Every caption triplet in one compressed video packet.
    ///
    /// Returns an empty array — the overwhelmingly common answer — without
    /// allocating anything beyond the (empty) result for a packet whose NAL
    /// units are all slices. That matters: this runs on **every video packet**
    /// of a session whose source turned out to have captions, beside the
    /// existing Dolby Vision walk.
    static func triplets(
        in bytes: UnsafeBufferPointer<UInt8>,
        framing: HEVCNALUnits.Framing,
        codec: HEVCNALUnits.Codec
    ) -> [Triplet] {
        var found: [Triplet] = []
        HEVCNALUnits.scan(bytes, framing: framing, codec: codec) { type, payload in
            guard HEVCNALUnits.isSEI(type, codec: codec) else { return }
            appendTriplets(fromSEINAL: payload, into: &found)
        }
        return found
    }

    /// The SEI message loop of one SEI NAL payload (header already stripped).
    static func appendTriplets(
        fromSEINAL payload: UnsafeBufferPointer<UInt8>, into found: inout [Triplet]
    ) {
        HEVCNALUnits.forEachSEIMessage(inSEINAL: payload) { payloadType, message in
            if payloadType == HEVCNALUnits.t35PayloadType { appendTriplets(fromT35: message, into: &found) }
            return true
        }
    }

    /// One T.35 message: the ATSC claim, then `cc_data`.
    private static func appendTriplets(fromT35 message: ArraySlice<UInt8>, into found: inout [Triplet]) {
        let bytes = Array(message)
        // itu_t_t35_country_code 0xB5 (USA), terminal provider 0x0031,
        // user_identifier "GA94", user_data_type_code 0x03 (cc_data). Anything
        // else in an SEI type 4 is someone else's user data — Dolby, HDR10+,
        // an encoder's watermark — and must not be read as captions.
        guard bytes.count > 8, bytes[0] == 0xB5, bytes[1] == 0x00, bytes[2] == 0x31,
              bytes[3] == 0x47, bytes[4] == 0x41, bytes[5] == 0x39, bytes[6] == 0x34,
              bytes[7] == 0x03
        else { return }
        let header = bytes[8]
        guard header & 0x40 != 0 else { return }  // process_cc_data_flag
        let count = Int(header & 0x1F)
        // byte 9 is em_data, which nothing has ever used.
        let start = 10
        guard start + count * 3 <= bytes.count else { return }
        for index in 0..<count {
            let base = start + index * 3
            found.append(
                Triplet(
                    isValid: bytes[base] & 0x04 != 0,
                    type: bytes[base] & 0x03,
                    data0: bytes[base + 1],
                    data1: bytes[base + 2]
                )
            )
        }
    }
}
