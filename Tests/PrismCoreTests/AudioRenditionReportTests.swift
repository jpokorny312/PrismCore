import Testing
import Foundation
import AVFoundation
@testable import PrismCore

/// `PrismCoreSession.audioRenditions`: which audio rendition of the served
/// master carries which source stream. The host selects the option of a track
/// by that name, because the only other thing an option carries - a language
/// tag - is shared by two tracks of one language and missing from an untagged
/// one.
///
/// The first suite is pure (the statements the remuxer builds its master
/// from, without a demuxer): it pins the cases a real file would need a new
/// fixture for. The second plays the real fixtures through a session, reads
/// the master the session wrote and asks the real AVFoundation for the
/// options of the audible group - the claim the whole API rests on is that
/// an option's `title` metadata item (identifier `m3u8/NAME`) is the reported
/// `name`. NOT its `displayName`: AVFoundation makes that from the language
/// (the first version of these tests assumed otherwise and failed on the real
/// thing: two `eng` options were both "English", an option without a language
/// "Unknown").
@Suite("Audio rendition report")
struct AudioRenditionReportTests {

    private func track(_ index: Int, language: String?, title: String? = nil) -> AudioTrackInfo {
        AudioTrackInfo(
            streamIndex: index, codecName: "aac", profileName: nil,
            channelCount: 2, channelLayoutDescription: "stereo",
            sampleRate: 48_000, language: language, title: title,
            isObjectAudio: false, copyability: .streamCopy
        )
    }

    /// One writer per track, in the order given - the order of the routes the
    /// remuxer builds them from (`ordinal` is the position, as in `run`).
    private func writers(_ tracks: [AudioTrackInfo]) -> [AudioRenditionWriter] {
        let parent = FileManager.default.temporaryDirectory
        return tracks.enumerated().map { ordinal, track in
            AudioRenditionWriter(
                route: .init(index: Int32(track.streamIndex), mode: .streamCopy),
                track: track, ordinal: ordinal, parent: parent
            )
        }
    }

    /// The report of `writers`, built the way the remuxer builds it.
    private func report(of writers: [AudioRenditionWriter])
        -> (declared: [MasterPlaylistBuilder.AudioRendition], reported: [AudioRenditionInfo]) {
        let declared = HLSRemuxer.declareAudioRenditions(writers)
        return (declared, HLSRemuxer.audioRenditionInfos(routes: writers.map(\.route), declared: declared))
    }

    @Test("Two tracks of one language are two renditions with two names, each tied to its own stream")
    func twoTracksOfOneLanguage() {
        let (_, reported) = report(of: writers([
            track(1, language: "eng"), track(2, language: "eng"),
        ]))
        #expect(reported.map(\.streamIndex) == [1, 2])
        #expect(reported.map(\.language) == ["eng", "eng"])
        // Both would be declared with the language's own name; the master
        // would be refused whole (duplicate NAME), so the second is numbered.
        // (What the language is called depends on the locale of the machine:
        // the relation between the two names does not.)
        #expect(reported[1].name == reported[0].name + " 2", "\(reported.map(\.name))")
        #expect(reported.map(\.isDefault) == [true, false])
    }

    @Test("A track with no language is named by its place, and says it has no language")
    func anUntaggedTrack() {
        // 2 has no tag at all, 3 says "und" - the container's way of saying
        // it does not know, which is no language either.
        let (_, reported) = report(of: writers([
            track(1, language: "eng", title: "Main"),
            track(2, language: nil),
            track(3, language: "und"),
        ]))
        #expect(reported.map(\.name) == ["Main", "Audio 2", "Audio 3"])
        #expect(reported.map(\.language) == ["eng", nil, nil])
        #expect(reported.map(\.streamIndex) == [1, 2, 3])
    }

    @Test("The container's own title wins over the language, and two titles never collide")
    func titlesWin() {
        let (_, reported) = report(of: writers([
            track(1, language: "eng", title: "Main mix"),
            track(2, language: "eng", title: "Commentary"),
            track(5, language: "eng", title: "commentary"),
        ]))
        #expect(Array(reported.map(\.name).prefix(2)) == ["Main mix", "Commentary"])
        // (compared without regard to case, as the group's names must be)
        #expect(Set(reported.map { $0.name.lowercased() }).count == 3, "\(reported.map(\.name))")
        #expect(reported.map(\.streamIndex) == [1, 2, 5])
    }

    @Test("The first of the list is the DEFAULT one and the list is in the master's order, not the container's")
    func theChosenTrackLeads() {
        // `routeAll` put the preferred track (stream 3) first.
        let (_, reported) = report(of: writers([
            track(3, language: "ces"), track(1, language: "eng"), track(2, language: "deu"),
        ]))
        #expect(reported.map(\.streamIndex) == [3, 1, 2])
        #expect(reported.map(\.isDefault) == [true, false, false])
    }

    @Test("A dialogue-boost rendition shares its base track's stream and is not reported twice")
    func boostRenditionsAreNotInTheList() {
        let base = track(3, language: "eng", title: "Main")
        let other = track(1, language: "ces")
        let parent = FileManager.default.temporaryDirectory
        let all = [
            AudioRenditionWriter(route: .init(index: 3, mode: .streamCopy), track: base, ordinal: 0, parent: parent),
            AudioRenditionWriter(route: .init(index: 1, mode: .streamCopy), track: other, ordinal: 1, parent: parent),
            AudioRenditionWriter(route: .init(index: 3, mode: .boost(.medium)), track: base, ordinal: 2, parent: parent),
        ]
        let (declared, reported) = report(of: all)
        #expect(declared.count == 3, "the boost is declared in the master")
        #expect(declared[2].name.hasSuffix("(Dialogue Boost)"), "\(declared.map(\.name))")
        #expect(reported.map(\.streamIndex) == [3, 1], "one rendition per stream")
        #expect(!reported.contains { $0.name.contains("Dialogue Boost") })
        #expect(reported.map(\.isDefault) == [true, false], "DEFAULT is the first base track, boosts never carry it")
    }

    @Test("Two tracks both titled \"English\": the second is numbered, and the report has two entries in the master's order")
    func twoTracksWithTheSameTitle() throws {
        let (declared, reported) = report(of: writers([
            track(4, language: "eng", title: "English"), track(2, language: "eng", title: "English"),
        ]))
        #expect(reported.map(\.streamIndex) == [4, 2], "the master's order, not the container's")
        #expect(reported.map(\.name) == ["English", "English 2"], "a title that is already taken is numbered")
        #expect(reported.map(\.isDefault) == [true, false])
        #expect(declared.map(\.name) == reported.map(\.name))
    }

    @Test("Two renditions that print the same NAME stay two entries, in the master's order")
    func identicalPrintedNamesStayTwoEntries() {
        // `uniqueRenditionNames` makes names unique before they are printed; the one way two can print alike
        // after that is the fold of a double quote (`A"B` beside `A'B`). Built by hand here, to pin that the
        // report never merges, drops or reorders entries by name.
        let routes: [HLSRemuxer.AudioRoute] = [.init(index: 3, mode: .streamCopy), .init(index: 1, mode: .streamCopy)]
        let declared: [MasterPlaylistBuilder.AudioRendition] = [
            .init(name: "English", language: "eng", isDefault: true),
            .init(name: "English", language: "eng", isDefault: false),
        ]
        let reported = HLSRemuxer.audioRenditionInfos(routes: routes, declared: declared)
        #expect(reported.map(\.streamIndex) == [3, 1])
        #expect(reported.map(\.name) == ["English", "English"])
        #expect(reported.map(\.isDefault) == [true, false])
    }

    @Test("The name is the text the playlist says: a double quote is folded to a single one, in the report too")
    func nameIsWhatThePlaylistPrints() throws {
        #expect(MasterPlaylistBuilder.attributeValue("Director\"s \"cut\"") == "Director's 'cut'")
        #expect(MasterPlaylistBuilder.attributeValue("Commentary") == "Commentary", "nothing else is touched")

        let (declared, reported) = report(of: writers([
            track(1, language: "eng", title: "Director's \"cut\""),
        ]))
        #expect(reported[0].name == "Director's 'cut'")
        // ... and that is what the master prints between the quotes.
        let master = try MasterPlaylistBuilder.build(.init(
            bandwidth: 1_000_000, videoCodec: .explicit("avc1.640028"), audioRenditions: declared
        ))
        #expect(master.contains("NAME=\"\(reported[0].name)\""), "\(master)")
        #expect(master.contains("LANGUAGE=\"eng\""))
    }

    @Test("The report keeps what the master says about the language: the tag verbatim, nothing for none")
    func languageIsTheMastersLanguage() throws {
        let (declared, reported) = report(of: writers([
            track(1, language: "ger"), track(2, language: nil), track(3, language: "pt-BR"),
        ]))
        #expect(reported.map(\.language) == ["ger", nil, "pt-BR"])
        let master = try MasterPlaylistBuilder.build(.init(
            bandwidth: 1_000_000, videoCodec: .explicit("avc1.640028"), audioRenditions: declared
        ))
        let lines = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:") }
        #expect(lines.count == 3)
        #expect(lines[0].contains("LANGUAGE=\"ger\""))
        #expect(!lines[1].contains("LANGUAGE="), "an untagged track is declared without one")
        #expect(lines[2].contains("LANGUAGE=\"pt-BR\""))
    }
}

/// The real thing: sessions over the fixtures, the master they wrote, and the
/// options AVFoundation makes of it.
@Suite("Audio rendition report, sessions", .serialized)
struct AudioRenditionSessionTests {

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try #require(url, "fixture \(name) missing from test bundle")
    }

    /// `h264_multi_audio.mkv` with the language of its second track (Czech, "ces")
    /// replaced by `language` - three letters, so that every byte stays where it
    /// is. The track's Language element is `22 B5 9C 83` and the tag itself.
    private func multiAudio(secondTrackTagged language: String) throws -> URL {
        precondition(language.utf8.count == 3)
        var bytes = try Data(contentsOf: fixture("h264_multi_audio.mkv"))
        let header = Data([0x22, 0xB5, 0x9C, 0x83])
        let czech = header + Data("ces".utf8)
        let range = try #require(bytes.range(of: czech), "the fixture's second track is no longer tagged ces")
        bytes.replaceSubrange(range, with: header + Data(language.utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRenditionReport-\(UUID().uuidString).mkv")
        try bytes.write(to: url)
        return url
    }

    /// `h264_multi_audio.mkv` with the TITLE of its first track (the Name element, "English", 7 bytes)
    /// replaced by `title`, also 7 UTF-8 bytes so that every byte stays where it is.
    private func retitled(_ title: String) throws -> URL {
        precondition(title.utf8.count == 7)
        var bytes = try Data(contentsOf: fixture("h264_multi_audio.mkv"))
        let header = Data([0x53, 0x6E, 0x87])
        let range = try #require(bytes.range(of: header + Data("English".utf8)), "the fixture's first track is no longer titled English")
        bytes.replaceSubrange(range, with: header + Data(title.utf8))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRenditionReport-\(UUID().uuidString).mkv")
        try bytes.write(to: url)
        return url
    }

    /// The NAME of every option of `group`, in the group's order, as AVFoundation hands it over: the `title`
    /// common-metadata item (identifier `m3u8/NAME` for an HLS rendition) - NOT `displayName`, which AVFoundation
    /// makes from the language (and from the system's locale): two `eng` options were both "English", an option
    /// without a language "Unknown".
    private func optionNames(of group: AVMediaSelectionGroup) async throws -> [String?] {
        var names: [String?] = []
        for option in group.options {
            let titles = option.commonMetadata.filter { $0.commonKey == .commonKeyTitle }
            let title = titles.first(where: { $0.identifier?.rawValue == "m3u8/NAME" }) ?? titles.first
            names.append(try await title?.load(.stringValue))
        }
        return names
    }

    /// Every `EXT-X-MEDIA:TYPE=AUDIO` line of the master.
    private func mediaLines(_ master: String) -> [String] {
        master.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") }
    }

    /// One attribute of an `EXT-X-MEDIA` line: the text between the quotes, or
    /// up to the next comma for an unquoted one; nil when the line has none.
    private func attribute(_ key: String, in line: String) -> String? {
        guard let start = line.range(of: ",\(key)=") else { return nil }
        let rest = line[start.upperBound...]
        if rest.hasPrefix("\"") { return String(rest.dropFirst().prefix { $0 != "\"" }) }
        return String(rest.prefix { $0 != "," })
    }

    /// The master a session wrote into its work directory.
    private func master(of session: PrismCoreSession) async throws -> String {
        try String(
            contentsOf: await session.workDirectory.appendingPathComponent("master.m3u8"),
            encoding: .utf8
        )
    }

    @Test("The report is what the master declares, line by line, and the indexes are the container's")
    func reportMatchesTheMaster() async throws {
        let source = try fixture("h264_multi_audio.mkv")
        let session = try PrismCoreSession(url: source)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(playlist.lastPathComponent == "master.m3u8")

        let reported = session.audioRenditions
        let lines = mediaLines(try await master(of: session))
        try #require(lines.count == 2)
        #expect(reported.count == 2)
        for (info, line) in zip(reported, lines) {
            #expect(attribute("NAME", in: line) == info.name, "\(line)")
            #expect(attribute("LANGUAGE", in: line) == info.language, "\(line)")
            #expect((attribute("DEFAULT", in: line) == "YES") == info.isDefault, "\(line)")
        }
        // The index of a stream is the container's own: what a probe of the
        // source itself says - and what the session's delivery list uses.
        let sourceTracks = try SourceProbe.probe(url: source).audioTracks
        #expect(Set(reported.map(\.streamIndex)) == Set(sourceTracks.map(\.streamIndex)))
        #expect(Set(reported.map(\.streamIndex)) == Set(session.audioTrackDeliveries.map(\.streamIndex)))
        for info in reported {
            let probed = sourceTracks.first(where: { $0.streamIndex == info.streamIndex })
            #expect(probed != nil, "stream \(info.streamIndex) is not a track of the source")
            #expect(info.language == probed?.language, "stream \(info.streamIndex)")
        }
        // Exactly one DEFAULT, and it leads (the English track here).
        #expect(reported.filter(\.isDefault).count == 1)
        #expect(reported.first?.isDefault == true)
        #expect(reported.first?.language == "eng")
    }

    @Test("The host's preferred language moves DEFAULT, and the report with it")
    func preferredLanguageLeads() async throws {
        let source = try fixture("h264_multi_audio.mkv")
        let session = try PrismCoreSession(url: source, preferredAudioLanguage: "cs")
        _ = try await session.start()
        defer { Task { await session.stop() } }

        let sourceTracks = try SourceProbe.probe(url: source).audioTracks
        let czech = try #require(sourceTracks.first(where: { $0.language == "ces" }))
        let reported = session.audioRenditions
        #expect(reported.first?.streamIndex == czech.streamIndex)
        #expect(reported.first?.isDefault == true)
        #expect(reported.count == 2)
    }

    @Test("A muxed session has no group to select in: the report is empty")
    func muxedShapeReportsNothing() async throws {
        let session = try PrismCoreSession(url: try fixture("h264_multi_audio.mkv"), forceMuxedShape: true)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }
        #expect(playlist.lastPathComponent == "index.m3u8", "served: \(playlist.lastPathComponent)")
        #expect(session.audioRenditions.isEmpty)
    }

    @Test("Two tracks of one language: two names, and AVFoundation's options carry exactly those names")
    func sameLanguageTwiceInAFile() async throws {
        let file = try multiAudio(secondTrackTagged: "eng")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = try PrismCoreSession(url: file)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let reported = session.audioRenditions
        try #require(reported.count == 2)
        #expect(reported.map(\.language) == ["eng", "eng"], "both tracks are English now")
        #expect(Set(reported.map { $0.name.lowercased() }).count == 2, "\(reported.map(\.name))")
        #expect(Set(reported.map(\.streamIndex)).count == 2)

        // The claim the API rests on: an option's NAME - its `title` metadata item - is the reported
        // name, and the options come in the master's order (what a host that pairs the k-th option of a
        // name with the k-th entry of that name relies on).
        let group = try #require(
            try await AVURLAsset(url: playlist).loadMediaSelectionGroup(for: .audible),
            "no audible group - the master declared no renditions"
        )
        let names = try await optionNames(of: group)
        #expect(
            names == reported.map { Optional($0.name) },
            "option names: \(names), reported: \(reported.map(\.name)), displayNames: \(group.options.map(\.displayName))"
        )
        #expect(Set(names).count == 2, "the two options differ by their NAME: \(names)")
        // ... and both options speak the same language: that is the case in
        // which a pick by language plays the wrong track.
        let tags = Set(group.options.compactMap { $0.extendedLanguageTag ?? $0.locale?.identifier })
        #expect(tags == ["eng"], "\(tags)")
    }

    @Test("A track with no language: named by its place, declared without LANGUAGE, selectable by its name")
    func untaggedTrackInAFile() async throws {
        let file = try multiAudio(secondTrackTagged: "und")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = try PrismCoreSession(url: file)
        let playlist = try await session.start()
        defer { Task { await session.stop() } }

        let reported = session.audioRenditions
        try #require(reported.count == 2)
        let untagged = try #require(reported.first(where: { $0.language == nil }), "\(reported)")
        #expect(untagged.name == "Audio 2", "the second track of the master, without a title or a language")
        #expect(!untagged.isDefault)

        let lines = mediaLines(try await master(of: session))
        let line = try #require(lines.first(where: { attribute("NAME", in: $0) == untagged.name }))
        #expect(attribute("LANGUAGE", in: line) == nil, "\(line)")

        // No tag to compare, and still an option to select: the one that bears the name.
        let group = try #require(try await AVURLAsset(url: playlist).loadMediaSelectionGroup(for: .audible))
        let names = try await optionNames(of: group)
        #expect(names == reported.map { Optional($0.name) }, "option names: \(names), reported: \(reported.map(\.name)), displayNames: \(group.options.map(\.displayName))")
        #expect(names.contains(untagged.name), "no option named \(untagged.name): \(names)")
    }

    @Test("A title with a double quote, and one with a comma and non-ASCII letters, reach the options as the report says them")
    func awkwardTitlesReachTheOptions() async throws {
        for title in ["Eng\"ish", "Ä,B é"] {
            let file = try retitled(title)
            defer { try? FileManager.default.removeItem(at: file) }
            let session = try PrismCoreSession(url: file)
            let playlist = try await session.start()
            defer { Task { await session.stop() } }

            let reported = session.audioRenditions
            try #require(reported.count == 2)
            // The playlist cannot hold a double quote in a NAME: the report says the folded text.
            #expect(reported[0].name == title.replacingOccurrences(of: "\"", with: "'"), "\(reported.map(\.name))")
            let group = try #require(try await AVURLAsset(url: playlist).loadMediaSelectionGroup(for: .audible))
            let names = try await optionNames(of: group)
            #expect(names == reported.map { Optional($0.name) }, "title \(title.debugDescription): option names \(names), reported \(reported.map(\.name))")
        }
    }
}
