import Foundation
import Libavformat

/// How much of a source libavformat may read before it has to answer what is
/// in it — the setting that decides what "opening a file" costs over a network.
///
/// FFmpeg's defaults (5 MB probe, 5 s of analysis) are tuned for containers
/// that hide their structure. The ones PrismCore takes describe themselves in
/// their header: Matroska carries CodecPrivate, MP4 carries the whole `moov`.
/// Measured against a 5.4 GB HEVC/EAC3 remux over HTTP, one open cost
/// **1.31 MB across 3 requests** at the defaults and **0.92 MB** capped — and
/// on a living-room Wi-Fi link to a media server that difference is the
/// visible part of "Preparing…", paid twice because the routing probe and the
/// remuxer each open the source.
///
/// The caps are a *ceiling*, not a target: libavformat stops as soon as it has
/// what it needs, so a well-formed file reads far less than either number.
/// What they bound is the pathological case — sparse audio, junk streams, a
/// container that never settles — where the analysis would otherwise read
/// megabytes to learn nothing new.
public enum SourceOpenTuning {

    /// Bytes libavformat may read while probing the container. Comfortably
    /// past a Matroska header with dozens of tracks, well short of the default.
    public static let probeSizeBytes = 4 << 20

    /// Microseconds of content the analysis may consume. Two seconds covers
    /// audio sparse enough to matter (a 1 s cap loses nothing on this corpus,
    /// but a stream with a long silent lead-in is exactly the case not worth
    /// being clever about).
    public static let analyzeDurationMicroseconds = 2_000_000

    /// How long a probe may spend before it answers with an error instead.
    ///
    /// A probe with no deadline is a playback with no fallback: a server that
    /// accepts the connection and then starves the reads (busy transcoding,
    /// sleeping disk) left the host with neither a verdict nor an error — the
    /// 2026-08-14 field log shows five play attempts over four minutes with
    /// no line from the engine at all, because `avformat_open_input` was
    /// still blocked on the first. Generous on purpose: a healthy probe over
    /// LAN answers in well under a second, so the budget only ever cuts off
    /// sources that were not going to answer.
    public static let probeBudget: Duration = .seconds(10)

    /// The protocols libavformat may open **itself** for a source: a local file,
    /// plain `http`, and the `tcp` it rides on — not `https`/`tls`, `crypto`,
    /// `rtp`/`udp`, `rtsp` or anything else.
    ///
    /// Why (2026-11-13, the Ensō fork): FFmpeg's own TLS — GnuTLS in MPVKit's
    /// build — takes **any** certificate. A host reads an `https` address
    /// through its own reader (a `PrismCoreInput`, `URLSession` in Ensō), which
    /// checks the server's certificate; what is left for FFmpeg to open is a
    /// plain `http` address or a file. Without a whitelist FFmpeg would also
    /// follow a redirect from such an address to `https` and read it with its
    /// own TLS: a stream, and whatever credential rides in its address or its
    /// headers, without a certificate check. With it, an address that needs a
    /// protocol outside the list fails with "Protocol '…' not on whitelist"
    /// **before** a connection is made (the whitelist is also checked for every
    /// redirect target).
    public static let protocolWhitelist = "file,http,tcp"

    /// How many redirects FFmpeg's http may follow when it opens a source
    /// itself: **none** (FFmpeg's default is 8). An address that redirects is
    /// not the address of the stream, and the credential in it must not follow
    /// a `Location` header to another host; the host resolves the address it
    /// means before it hands it over.
    public static let maxRedirects = 0

    /// Sets the two policies above on an options dictionary of an open.
    /// Every `avformat_open_input` that is given a URL carries it
    /// (`makeOptions` does it; a test scans for the opens that do not).
    static func applyProtocolPolicy(to options: inout OpaquePointer?) {
        av_dict_set(&options, "protocol_whitelist", protocolWhitelist, 0)
        av_dict_set(&options, "max_redirects", String(maxRedirects), 0)
    }

    /// The options every open should carry: the caller's HTTP headers, the
    /// reconnect policy the demux side needs, the caps above and the protocol
    /// policy (`protocolWhitelist`, `maxRedirects`).
    ///
    /// Returns an owned dictionary — the caller frees it with `av_dict_free`.
    static func makeOptions(httpHeaders: [String: String]) -> OpaquePointer? {
        var options: OpaquePointer?
        applyProtocolPolicy(to: &options)
        if !httpHeaders.isEmpty {
            let headerBlob = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&options, "headers", headerBlob, 0)
        }
        // Reconnect on dropped HTTP connections — the demuxer read side.
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        // Deliberately NOT `multiple_requests=1` (HTTP keep-alive). Measured
        // 2026-08-26 against a Range-capable loopback server, one session
        // start over a 30 s MKV: without it 4 requests on 4 connections;
        // with it 5–6 requests on 2–3 connections — the socket was reused,
        // but a duplicated Range request appeared in two runs of three, so
        // the round trips did not go down, and keep-alive semantics against
        // Plex/Jellyfin/Emby were an untested risk for no measured gain.
        av_dict_set(&options, "probesize", String(probeSizeBytes), 0)
        av_dict_set(&options, "analyzeduration", String(analyzeDurationMicroseconds), 0)
        return options
    }
}
