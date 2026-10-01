import Testing
import Foundation
@testable import PrismCore

/// The prewarm's contract: bytes fetched ahead are used only after the origin
/// confirms them, never cost more than their budget, go on the first memory
/// warning, and never take capacity from an origin that is refusing.
///
/// Every server here listens on its own port, so every test's URL — and with
/// it its key in the shared store — is its own.
@Suite("Source prewarm", .serialized)
struct SourcePrewarmTests {

    /// The suite uses the process-wide store, as hosts do. Emptied up front
    /// so no test's outcome depends on what an earlier one left behind — the
    /// ports make collisions unlikely, this makes them impossible.
    init() { PrismCoreEngine.discardPrewarmedSources() }

    private func fixture(_ name: String = "h264_aac_30s") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: - Store

    private func entry(_ bytes: Int, validator: String = "\"v\"") -> SourcePrewarmStore.Entry {
        .init(validator: validator, length: Int64(bytes), blocks: [.init(start: 0, data: Data(count: bytes))])
    }

    private func key(_ name: String) -> SourcePrewarmStore.Key {
        .init(url: URL(string: "http://example.test/\(name)")!, headers: [:])
    }

    @Test func storeEvictsLeastRecentlyUsedToStayInsideItsCapacity() {
        let store = SourcePrewarmStore(capacity: 100)
        #expect(store.insert(entry(40), for: key("a")))
        #expect(store.insert(entry(40), for: key("b")))
        // Touching `a` makes `b` the oldest, so `b` is what a third entry evicts.
        #expect(store.entry(for: key("a")) != nil)
        #expect(store.insert(entry(40), for: key("c")))
        #expect(store.entry(for: key("b")) == nil)
        #expect(store.entry(for: key("a")) != nil)
        #expect(store.residentBytes == 80)
        // Bigger than the whole store: refused, and nothing already held is
        // sacrificed for it.
        #expect(!store.insert(entry(101), for: key("d")))
        #expect(store.residentBytes == 80)
    }

    @Test func memoryPressureDropsEveryPrewarmedByte() {
        let store = SourcePrewarmStore(capacity: 100)
        store.insert(entry(30), for: key("a"))
        store.insert(entry(30), for: key("b"))
        store.handleMemoryPressure()
        #expect(store.residentBytes == 0)
        #expect(store.entry(for: key("a")) == nil)
    }

    @Test func headersArePartOfTheIdentity() {
        let url = URL(string: "http://example.test/movie.mkv")!
        #expect(SourcePrewarmStore.Key(url: url, headers: ["Authorization": "a"])
                != SourcePrewarmStore.Key(url: url, headers: ["Authorization": "b"]))
        #expect(SourcePrewarmStore.Key(url: url, headers: [:])
                != SourcePrewarmStore.Key(url: URL(string: "http://example.test/movie.mkv?t=2")!, headers: [:]))
    }

    // MARK: - Layout

    /// The tail fetch is aimed by the SeekHead's Cues entry; without the
    /// offset a prewarm could only guess at the tail.
    @Test func scannerNamesTheCuesOffsetOfARealMatroska() throws {
        let media = try fixture()
        let layout = SourcePrewarmFetcher.scanLayout(head: media, length: Int64(media.count))
        #expect(layout.indexLocation == .tail)
        let cues = try #require(layout.indexOffset)
        #expect(cues > Int64(try #require(layout.headerBytes)))
        // Cues element ID at the offset the SeekHead named.
        #expect([UInt8](media[Int(cues)..<Int(cues) + 4]) == [0x1C, 0x53, 0xBB, 0x6B])
    }

    /// An MP4 box: 32-bit size, four-character type, payload.
    private func box(_ type: String, _ payloadCount: Int, fill: UInt8 = 0) -> Data {
        let total = payloadCount + 8
        return Data([UInt8((total >> 24) & 0xFF), UInt8((total >> 16) & 0xFF),
                     UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)] + Array(type.utf8)
                    + [UInt8](repeating: fill, count: payloadCount))
    }

    /// A non-faststart MP4 whose `mdat` outruns the prewarm head, so the
    /// tail window is fetched from where the framing points — past `mdat`.
    private func tailIndexedMP4(moov: Bool) -> Data {
        box("ftyp", 16, fill: 1) + box("mdat", 1_200_000, fill: 3) + box("free", 64)
            + (moov ? box("moov", 256, fill: 2) : box("uuid", 256, fill: 4))
    }

    // MARK: - Fetch and handoff

    @Test func aPrewarmedOpenReadsOneByteFromTheOrigin() async throws {
        let media = try fixture()
        let server = try RangeFixtureServer(media: media, etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        let outcome = await PrismCoreEngine.prewarm(url: url)
        #expect(outcome.status == .stored)
        #expect(outcome.validator == "\"v1\"")
        #expect(outcome.indexPrewarmed)
        #expect(outcome.headerBytes != nil)
        // The head, then a tail window reaching back from the end of the file
        // — which on a 1.3 MB fixture and a 2 MB budget is the whole rest.
        #expect(outcome.requests == 2)
        #expect(outcome.storedBytes == media.count)
        let afterPrewarm = server.ranges.count

        let probed = try await SourceProbe.openDetached(url: url, coordinatedHTTP: true)
        #expect(!probed.info.audioTracks.isEmpty)
        #expect(probed.prewarm == .adopted(bytes: media.count))
        // The confirmation, and nothing else: every byte the probe read came
        // from memory.
        #expect(Array(server.ranges.dropFirst(afterPrewarm)) == ["bytes=0-0"])
    }

    @Test func aChangedValidatorDiscardsThePrewarmBeforeAByteIsUsed() async throws {
        let media = try fixture()
        let server = try RangeFixtureServer(media: media, etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        #expect(await PrismCoreEngine.prewarm(url: url).status == .stored)
        server.setETag("\"v2\"")
        let afterPrewarm = server.ranges.count

        let probed = try await SourceProbe.openDetached(
            url: url, coordinatedHTTP: true, hints: SourceOpenHints(expectedValidator: "\"v2\"")
        )
        #expect(probed.prewarm == .stale)
        #expect(!probed.info.audioTracks.isEmpty)
        // The confirmation is the reader's first response, so the hints'
        // validator check is judged on what the origin says NOW.
        #expect(probed.hints.reportedValidator == "\"v2\"")
        #expect(probed.hints.rejections.isEmpty)
        #expect(server.ranges.count > afterPrewarm + 1, "the probe should have read the network")
        #expect(SourcePrewarmStore.shared.entry(for: .init(url: url, headers: [:])) == nil)
    }

    /// `indexOffset` for an MP4 is only "the first byte after `mdat`"; the
    /// report has to be about what the bytes there are.
    @Test func anMP4IndexIsReportedOnlyWhenItsMoovWasFetched() async throws {
        for hasMoov in [true, false] {
            let media = tailIndexedMP4(moov: hasMoov)
            let server = try RangeFixtureServer(media: media, bytesPerSecond: 50_000_000, etag: "\"v1\"")
            let url = try await server.start()
            defer { server.stop() }

            let outcome = await PrismCoreEngine.prewarm(url: url)
            #expect(outcome.status == .stored)
            #expect(outcome.requests == 2, "the tail past mdat should have been fetched")
            #expect(outcome.indexPrewarmed == hasMoov,
                    "moov \(hasMoov ? "present" : "absent") but indexPrewarmed is \(outcome.indexPrewarmed)")
        }
    }

    @Test func discardingPrewarmedSourcesEmptiesTheStore() async throws {
        let server = try RangeFixtureServer(media: try fixture(), etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        #expect(await PrismCoreEngine.prewarm(url: url).status == .stored)
        PrismCoreEngine.discardPrewarmedSources()
        #expect(SourcePrewarmStore.shared.entry(for: .init(url: url, headers: [:])) == nil)
        let probed = try await SourceProbe.openDetached(url: url, coordinatedHTTP: true)
        #expect(probed.prewarm == .none)
    }

    /// `Last-Modified` has one-second resolution. An origin that reports
    /// nothing better cannot tell a prewarm whether the file was rewritten
    /// in the second its date names, so nothing is stored.
    @Test func aLastModifiedDateAloneIsNotAValidator() async throws {
        let server = try RangeFixtureServer(media: try fixture(), lastModified: "Wed, 30 Sep 2026 10:00:00 GMT")
        let url = try await server.start()
        defer { server.stop() }

        let outcome = await PrismCoreEngine.prewarm(url: url)
        #expect(outcome.status == .validatorUnavailable)
        #expect(SourcePrewarmStore.shared.entry(for: .init(url: url, headers: [:])) == nil)
    }

    /// The reproduction behind the rule, on the adopt side: an entry bound to
    /// a date (as a pre-fix prewarm stored it), and a file rewritten under
    /// the same date, length and first byte. Every check but the validator's
    /// kind passes; the bytes must still not be used.
    @Test func sameDateLengthAndFirstByteWithDifferentBytesIsNotAdopted() async throws {
        let original = try fixture()
        var rewritten = original
        let changed = rewritten.startIndex + rewritten.count / 2
        rewritten[changed] ^= 0xFF
        #expect(rewritten.first == original.first && rewritten.count == original.count)

        let date = "Wed, 30 Sep 2026 10:00:00 GMT"
        let server = try RangeFixtureServer(media: rewritten, lastModified: date)
        let url = try await server.start()
        defer { server.stop() }
        let key = SourcePrewarmStore.Key(url: url, headers: [:])
        SourcePrewarmStore.shared.insert(
            .init(validator: date, length: Int64(original.count), blocks: [.init(start: 0, data: original)]),
            for: key)

        let probed = try await SourceProbe.openDetached(url: url, coordinatedHTTP: true)
        #expect(probed.prewarm == .stale)
        #expect(!probed.info.audioTracks.isEmpty)
        #expect(SourcePrewarmStore.shared.entry(for: key) == nil)
    }

    @Test func anOriginWithoutAValidatorIsNeverPrewarmed() async throws {
        let server = try RangeFixtureServer(media: try fixture())
        let url = try await server.start()
        defer { server.stop() }

        let outcome = await PrismCoreEngine.prewarm(url: url)
        #expect(outcome.status == .validatorUnavailable)
        #expect(outcome.requests == 1)
        #expect(SourcePrewarmStore.shared.entry(for: .init(url: url, headers: [:])) == nil)
    }

    @Test func aPrewarmUnderOtherHeadersIsNotOffered() async throws {
        let server = try RangeFixtureServer(media: try fixture(), etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        #expect(await PrismCoreEngine.prewarm(url: url, httpHeaders: ["Authorization": "a"]).status == .stored)
        let probed = try await SourceProbe.openDetached(
            url: url, httpHeaders: ["Authorization": "b"], coordinatedHTTP: true
        )
        #expect(probed.prewarm == .none)
    }

    @Test func theBudgetBoundsWhatIsHeld() async throws {
        let server = try RangeFixtureServer(media: try fixture(), etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        let outcome = await PrismCoreEngine.prewarm(url: url, byteBudget: 256 << 10)
        #expect(outcome.status == .stored)
        #expect(outcome.storedBytes <= 256 << 10)
        // Still a play: the reader takes what there is and fetches the rest.
        let probed = try await SourceProbe.openDetached(url: url, coordinatedHTTP: true)
        #expect(probed.prewarm == .adopted(bytes: outcome.storedBytes))
        #expect(!probed.info.audioTracks.isEmpty)
    }

    // MARK: - Origin capacity

    @Test func aRefusalIsRecordedAndNotRetried() async throws {
        let server = try RangeFixtureServer(media: try fixture(), refusals: 1, retryAfter: "5", etag: "\"v1\"")
        let url = try await server.start()
        defer { server.stop() }

        let refused = await PrismCoreEngine.prewarm(url: url)
        #expect(refused.status == .originRefused(status: 429))
        #expect(refused.requests == 1)
        #expect(server.requests.count == 1)
        // The origin said no a moment ago: a second prewarm does not even ask
        // — and says so, rather than reporting a request it never sent.
        let declined = await PrismCoreEngine.prewarm(url: url)
        #expect(declined.status == .originBusy)
        #expect(declined.requests == 0)
        #expect(server.requests.count == 1)
    }

    @Test func yieldingAdmissionAlwaysLeavesASlotForPlayback() {
        let coordinator = HTTPOriginCoordinator()
        #expect(coordinator.acquire("o", cancelled: { false }))
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        #expect(!coordinator.acquireYielding("o", cancelled: { ProcessInfo.processInfo.systemUptime >= deadline }),
                "a prewarm took the second slot while playback held the first")
        coordinator.release("o")
        #expect(coordinator.acquireYielding("o", cancelled: { false }))
        // Playback can still get in beside a prewarm.
        #expect(coordinator.acquire("o", cancelled: { false }))
        coordinator.release("o")
        coordinator.release("o")
        coordinator.refuse("o", retryAfter: "0")
        #expect(!coordinator.acquireYielding("o", cancelled: { false }), "a refusing origin must be declined, not waited on")
    }

    @Test func nonHTTPSourcesAreNotApplicable() async throws {
        let outcome = await PrismCoreEngine.prewarm(url: URL(fileURLWithPath: "/tmp/movie.mkv"))
        #expect(outcome.status == .notApplicable)
        #expect(outcome.requests == 0)
    }
}
