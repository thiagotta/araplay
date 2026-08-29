import Testing
@testable import AraPlay

// `MediaInfo.applying` merges the engine's report with the tag reader's, and
// the two arrive in either order. The contract under test: a source can add
// what it knows, but can never blank out what another source already found.
struct MediaInfoTests {
    @Test func laterSourceFillsGaps() {
        var base = MediaInfo(title: "Retrato pra Iaiá")
        base = base.applying(MediaInfo(artist: "Los Hermanos", album: "Bloco do Eu Sozinho"))

        #expect(base.title == "Retrato pra Iaiá")
        #expect(base.artist == "Los Hermanos")
        #expect(base.album == "Bloco do Eu Sozinho")
    }

    @Test func nilNeverOverwritesAValue() {
        var base = MediaInfo(title: "Kept", artist: "Kept Too")
        base = base.applying(MediaInfo(album: "Only Addition"))

        #expect(base.title == "Kept")
        #expect(base.artist == "Kept Too")
        #expect(base.album == "Only Addition")
    }

    @Test func newerValueWinsWhenBothExist() {
        var base = MediaInfo(title: "Filename Guess")
        base = base.applying(MediaInfo(title: "Real Tag Title"))
        #expect(base.title == "Real Tag Title")
    }

    @Test func hasVideoIsSticky() {
        // Either source discovering a video track settles the question; a later
        // audio-only report must not demote the file back to audio.
        var base = MediaInfo(hasVideo: true)
        base = base.applying(MediaInfo(hasVideo: false))
        #expect(base.hasVideo)

        var other = MediaInfo(hasVideo: false)
        other = other.applying(MediaInfo(hasVideo: true))
        #expect(other.hasVideo)
    }

    @Test func mergeIsOrderTolerantForDisjointFields() {
        let tags = MediaInfo(title: "T", artist: "A")
        let engine = MediaInfo(hasVideo: true, naturalSize: .init(width: 1280, height: 720))

        let tagsFirst = MediaInfo().applying(tags).applying(engine)
        let engineFirst = MediaInfo().applying(engine).applying(tags)

        #expect(tagsFirst == engineFirst)
    }

    @Test func hasTagsRequiresARealTag() {
        #expect(!MediaInfo(title: "just a filename").hasTags)
        #expect(MediaInfo(artist: "Someone").hasTags)
        #expect(MediaInfo(year: 2001).hasTags)
    }
}
