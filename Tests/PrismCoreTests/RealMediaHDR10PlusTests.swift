import Testing
import Foundation
@testable import PrismCore

/// Opt-in check of the HDR10+ scout against a real encode. The committed
/// fixtures carry an ST 2094-40 SEI that a script injected, which proves the
/// syntax but not what a real encoder (or a disc's authoring chain) writes —
/// scene-based metadata, suffix SEI, several messages per picture.
///
///     PRISMCORE_HDR10PLUS_MEDIA=/path/or/http-url swift test --filter realEncodeIsSeen
///
/// An `http://` URL is the honest one to time (see AGENTS.md, *Measuring*):
/// the scan's cost is packet reads, and a mounted share hides them.
///
/// It proves detection and stream-copy survival only. Whether a panel shows
/// HDR10+ is a device run, and this is not one.
@Suite(
    "Real media: HDR10+",
    .enabled(if: ProcessInfo.processInfo.environment["PRISMCORE_HDR10PLUS_MEDIA"] != nil)
)
struct RealMediaHDR10PlusTests {

    @Test("A real HDR10+ encode is seen, and its SEI reaches the served head segment")
    func realEncodeIsSeen() async throws {
        let value = ProcessInfo.processInfo.environment["PRISMCORE_HDR10PLUS_MEDIA"] ?? ""
        let url = value.hasPrefix("http") ? try #require(URL(string: value)) : URL(fileURLWithPath: value)

        let probed = try SourceProbe.open(url: url, hdr10Plus: .standard)
        let finding = try #require(probed.info.hdr10Plus, "no video track")
        print("HDR10+ finding: \(finding) — scan took \(probed.timing.hdr10PlusScan), probe total \(probed.timing.total)")
        #expect(finding.verdict == .seen)

        let session = try PrismCoreSession(
            url: url, display: DisplayCapabilities(isHDRReady: true, isDolbyVisionCapable: false),
            probed: probed
        )
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        let (head, _) = try await URLSession.uncached.data(
            from: playlist.deletingLastPathComponent().appendingPathComponent("seg00000.m4s")
        )
        let version = UInt8(finding.applicationVersion ?? 1)
        #expect(head.range(of: Data([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, version])) != nil,
                "the HDR10+ SEI did not reach the served head segment")
    }
}
