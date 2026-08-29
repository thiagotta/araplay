import Foundation
import Testing
@testable import AraPlay

struct RecentItemTests {
    private func item(duration: Double? = nil, resume: Double? = nil) -> RecentItem {
        var item = RecentItem(url: URL(fileURLWithPath: "/tmp/example.mp3"), isVideo: false)
        item.duration = duration
        item.resumeTime = resume
        return item
    }

    // MARK: - Progress gauge bounds

    @Test func noProgressWithoutResumePosition() {
        #expect(item(duration: 100).progress == nil)
    }

    @Test func noProgressInTheFirstFiveSeconds() {
        // A sliver of fill reads as a stray underline, not as progress.
        #expect(item(duration: 100, resume: 4).progress == nil)
    }

    @Test func progressInTheMiddle() {
        #expect(item(duration: 100, resume: 50).progress == 0.5)
    }

    @Test func noProgressWhenFractionIsNegligible() {
        // Six seconds into three hours is above the resume floor but the bar
        // would render under a pixel wide.
        #expect(item(duration: 10_000, resume: 6).progress == nil)
    }

    @Test func noProgressWhenEffectivelyFinished() {
        #expect(item(duration: 100, resume: 99).progress == nil)
    }

    // MARK: - Labels

    @Test func labelPrefersTagTitleOverFileName() {
        var entry = item()
        #expect(entry.label == "example")

        entry.taggedTitle = "Real Title"
        #expect(entry.label == "Real Title")
    }

    @Test func subtitlePrefersArtistOverFolder() {
        var entry = item()
        #expect(entry.subtitle == "tmp")

        entry.artist = "Los Hermanos"
        #expect(entry.subtitle == "Los Hermanos")
    }

    @Test func resolveLocationFailsForAMissingFileWithoutBookmark() {
        let ghost = RecentItem(
            url: URL(fileURLWithPath: "/nonexistent/definitely-not-here-\(UUID().uuidString).mp3"),
            isVideo: false
        )
        #expect(ghost.resolveLocation() == nil)
    }

    @Test func resolveLocationFindsAnExistingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "araplay-test-\(UUID().uuidString).mp3")
        try Data("stub".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = RecentItem(url: url, isVideo: false)
        let location = try #require(entry.resolveLocation())
        #expect(location.url.standardizedFileURL.path == url.standardizedFileURL.path)
    }
}
