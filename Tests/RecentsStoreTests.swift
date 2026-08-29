import Foundation
import Testing
@testable import AraPlay

// Every test gets its own store file in a temp directory, so nothing here can
// touch (or be polluted by) a real recents list.
@MainActor
struct RecentsStoreTests {
    private func makeStore() -> (store: RecentsStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "araplay-tests-\(UUID().uuidString).json")
        return (RecentsStore(storeURL: url), url)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/araplay-test-media/\(name)")
    }

    // MARK: - LRU behaviour

    @Test func playingInsertsAtTheTop() {
        let (store, _) = makeStore()
        store.recordPlay(url: url("first.mp3"), isVideo: false)
        store.recordPlay(url: url("second.mp3"), isVideo: false)

        #expect(store.items.count == 2)
        #expect(store.items[0].displayName == "second")
        #expect(store.items[1].displayName == "first")
    }

    @Test func replayingMovesToTheTopWithoutDuplicating() {
        let (store, _) = makeStore()
        store.recordPlay(url: url("a.mp3"), isVideo: false)
        store.recordPlay(url: url("b.mp3"), isVideo: false)
        store.recordPlay(url: url("a.mp3"), isVideo: false)

        #expect(store.items.count == 2)
        #expect(store.items[0].displayName == "a")
    }

    @Test func replayingPreservesTheEntryIdentityAndMetadata() {
        let (store, _) = makeStore()
        let original = store.recordPlay(url: url("keep.mp3"), isVideo: false)
        store.updateMetadata(id: original.id, title: "Tagged", artist: "Artist", album: nil)

        let replayed = store.recordPlay(url: url("keep.mp3"), isVideo: false)
        #expect(replayed.id == original.id)
        #expect(store.items[0].taggedTitle == "Tagged")
    }

    @Test func listIsCappedAtCapacityDroppingTheOldest() {
        let (store, _) = makeStore()
        for index in 0 ..< (RecentsStore.capacity + 5) {
            store.recordPlay(url: url("file-\(index).mp3"), isVideo: false)
        }

        #expect(store.items.count == RecentsStore.capacity)
        // The newest survives at the top; the five oldest fell off the end.
        #expect(store.items.first?.displayName == "file-\(RecentsStore.capacity + 4)")
        #expect(!store.items.contains { $0.displayName == "file-0" })
        #expect(!store.items.contains { $0.displayName == "file-4" })
        #expect(store.items.contains { $0.displayName == "file-5" })
    }

    // MARK: - Search

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let (store, _) = makeStore()
        store.recordPlay(url: url("Retrato pra Iaiá.mp3"), isVideo: false)

        #expect(store.search("iaia").count == 1)
        #expect(store.search("RETRATO").count == 1)
        #expect(store.search("nope").isEmpty)
    }

    @Test func searchMatchesCachedTags() {
        let (store, _) = makeStore()
        let item = store.recordPlay(url: url("track01.mp3"), isVideo: false)
        store.updateMetadata(id: item.id, title: "Retrato", artist: "Los Hermanos", album: "Bloco do Eu Sozinho")

        #expect(store.search("hermanos").count == 1)
        #expect(store.search("bloco").count == 1)
    }

    @Test func emptyQueryReturnsEverything() {
        let (store, _) = makeStore()
        store.recordPlay(url: url("one.mp3"), isVideo: false)
        store.recordPlay(url: url("two.mp3"), isVideo: false)
        #expect(store.search("   ").count == 2)
    }

    // MARK: - Resume positions

    @Test func progressMidFileIsKept() {
        let (store, _) = makeStore()
        let item = store.recordPlay(url: url("movie.mkv"), isVideo: true)
        store.updateProgress(id: item.id, time: 50, duration: 100)

        #expect(store.items[0].resumeTime == 50)
        #expect(store.items[0].duration == 100)
    }

    @Test func watchingToTheEndClearsResume() {
        // Within ten seconds of the end counts as finished: reopening should
        // start over, not drop the user into the closing seconds.
        let (store, _) = makeStore()
        let item = store.recordPlay(url: url("movie.mkv"), isVideo: true)
        store.updateProgress(id: item.id, time: 95, duration: 100)

        #expect(store.items[0].resumeTime == nil)
    }

    @Test func progressWithoutDurationNeedsAFewSeconds() {
        let (store, _) = makeStore()
        let item = store.recordPlay(url: url("stream.mp3"), isVideo: false)

        store.updateProgress(id: item.id, time: 3, duration: nil)
        #expect(store.items[0].resumeTime == nil)

        store.updateProgress(id: item.id, time: 30, duration: nil)
        #expect(store.items[0].resumeTime == 30)
    }

    // MARK: - Removal

    @Test func removeAndRemoveAll() {
        let (store, _) = makeStore()
        let keep = store.recordPlay(url: url("keep.mp3"), isVideo: false)
        let drop = store.recordPlay(url: url("drop.mp3"), isVideo: false)

        store.remove(id: drop.id)
        #expect(store.items.map(\.id) == [keep.id])

        store.removeAll()
        #expect(store.items.isEmpty)
    }

    // MARK: - Missing files

    @Test func refreshMarksUnresolvableEntriesMissing() async {
        let (store, _) = makeStore()
        let ghost = store.recordPlay(url: url("deleted.mp3"), isVideo: false)
        await store.refreshAvailability()

        #expect(store.isMissing(ghost))
    }

    @Test func replayingClearsTheMissingFlag() async {
        let (store, _) = makeStore()
        let item = store.recordPlay(url: url("flaky.mp3"), isVideo: false)
        await store.refreshAvailability()
        #expect(store.isMissing(item))

        store.recordPlay(url: url("flaky.mp3"), isVideo: false)
        #expect(!store.isMissing(item))
    }

    // MARK: - Persistence

    @Test func savedListSurvivesARestart() {
        let (store, storeURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let item = store.recordPlay(url: url("persisted.mp3"), isVideo: false)
        store.updateMetadata(id: item.id, title: "Title", artist: "Artist", album: "Album")
        store.updateProgress(id: item.id, time: 42, duration: 100)
        store.saveNow()

        let reloaded = RecentsStore(storeURL: storeURL)
        #expect(reloaded.items.count == 1)
        let entry = reloaded.items[0]
        #expect(entry.id == item.id)
        #expect(entry.taggedTitle == "Title")
        #expect(entry.artist == "Artist")
        #expect(entry.resumeTime == 42)
        #expect(entry.isVideo == false)
    }

    @Test func corruptStoreFileLoadsAsEmptyList() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "araplay-tests-\(UUID().uuidString).json")
        try Data("not json at all {{{".utf8).write(to: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let store = RecentsStore(storeURL: storeURL)
        #expect(store.items.isEmpty)
    }
}
