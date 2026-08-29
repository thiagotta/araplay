import Testing
@testable import AraPlay

// The tag-cleanup helpers normalize the many historical spellings of the same
// facts. Each shape below was seen in real files during development.
struct MetadataParsingTests {
    // MARK: - Year

    @Test func yearFromBareYear() {
        #expect(MediaMetadataReader.extractYear(from: "2001") == 2001)
    }

    @Test func yearFromISODate() {
        #expect(MediaMetadataReader.extractYear(from: "2001-07-23") == 2001)
    }

    @Test func yearFromTimestamp() {
        #expect(MediaMetadataReader.extractYear(from: "2001-07-23T12:00:00Z") == 2001)
    }

    @Test func yearFromDayFirstDate() {
        #expect(MediaMetadataReader.extractYear(from: "23/07/2001") == 2001)
    }

    @Test func yearFromGarbage() {
        #expect(MediaMetadataReader.extractYear(from: "unknown") == nil)
        #expect(MediaMetadataReader.extractYear(from: "") == nil)
    }

    // MARK: - Track numbers

    @Test func trackWithTotal() {
        let parsed = MediaMetadataReader.parseTrack("3/14")
        #expect(parsed.number == 3)
        #expect(parsed.total == 14)
    }

    @Test func trackAlone() {
        let parsed = MediaMetadataReader.parseTrack("7")
        #expect(parsed.number == 7)
        #expect(parsed.total == nil)
    }

    @Test func trackZeroPadded() {
        let parsed = MediaMetadataReader.parseTrack("03/14")
        #expect(parsed.number == 3)
        #expect(parsed.total == 14)
    }

    @Test func trackGarbage() {
        let parsed = MediaMetadataReader.parseTrack("A/B")
        #expect(parsed.number == nil)
        #expect(parsed.total == nil)
    }

    // MARK: - Genre

    @Test func genrePlainTextPassesThrough() {
        #expect(MediaMetadataReader.normalizeGenre("MPB") == "MPB")
    }

    @Test func genreID3IndexPrefixIsStripped() {
        #expect(MediaMetadataReader.normalizeGenre("(17)Rock") == "Rock")
    }

    @Test func genreBareIndexIsRejected() {
        // A numeric-only genre is an ID3v1 table index, not a name worth showing.
        #expect(MediaMetadataReader.normalizeGenre("17") == nil)
        #expect(MediaMetadataReader.normalizeGenre("(17)") == nil)
    }

    @Test func genreParenthesesWithoutIndexAreKept() {
        #expect(MediaMetadataReader.normalizeGenre("(Live) Bootleg") == "(Live) Bootleg")
    }

    @Test func genreEmptyIsRejected() {
        #expect(MediaMetadataReader.normalizeGenre("  ") == nil)
    }
}
