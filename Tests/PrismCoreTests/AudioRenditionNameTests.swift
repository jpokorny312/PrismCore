import Testing
@testable import PrismCore

/// HLS requires every `#EXT-X-MEDIA` NAME to be unique within its group;
/// AVPlayer discards the whole master otherwise.
@Suite("Audio rendition names")
struct AudioRenditionNameTests {

    @Test("distinct names are left untouched")
    func distinctNamesUntouched() {
        let names = ["English", "Deutsch", "Commentary"]
        #expect(AudioRenditionWriter.uniqueRenditionNames(names) == names)
    }

    @Test("the first holder keeps its name, later duplicates are numbered")
    func duplicatesAreNumbered() {
        let result = AudioRenditionWriter.uniqueRenditionNames(["English", "English", "English"])
        #expect(result == ["English", "English 2", "English 3"])
    }

    @Test("collisions are detected case-insensitively")
    func caseInsensitive() {
        let result = AudioRenditionWriter.uniqueRenditionNames(["English", "english"])
        #expect(Set(result.map { $0.lowercased() }).count == 2)
        #expect(result[0] == "English")
    }

    @Test("a generated name never collides with a real one")
    func generatedNameAvoidsRealOne() {
        let result = AudioRenditionWriter.uniqueRenditionNames(["English", "English 2", "English"])
        #expect(Set(result.map { $0.lowercased() }).count == 3)
        #expect(result[0] == "English")
        #expect(result[1] == "English 2")
    }

    @Test("order is preserved and the output is always pairwise distinct")
    func alwaysDistinct() {
        let input = ["A", "B", "A", "B", "A", "A 2", "B"]
        let result = AudioRenditionWriter.uniqueRenditionNames(input)
        #expect(result.count == input.count)
        #expect(Set(result.map { $0.lowercased() }).count == input.count)
    }
}
