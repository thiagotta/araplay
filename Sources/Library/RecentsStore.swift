import Foundation
import Observation

/// The recently-played list: a 200-entry LRU persisted to Application Support.
///
/// Playing a file moves it to the top whether it arrived from the Finder, the
/// open panel, or a click in this very list.
@MainActor
@Observable
final class RecentsStore {
    static let capacity = 200

    private(set) var items: [RecentItem] = []
    /// Entries whose file could not be found on the last sweep. Kept out of the
    /// persisted model because it is a fact about the disk, not about the entry.
    private(set) var missingIDs: Set<UUID> = []

    private let storeURL: URL
    private var saveTask: Task<Void, Never>?

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        load()
    }

    private static func defaultStoreURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = base.appending(path: "AraPlay", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "recents.json")
    }

    // MARK: - Queries

    func isMissing(_ item: RecentItem) -> Bool {
        missingIDs.contains(item.id)
    }

    /// Case- and diacritic-insensitive match over the file name, its folder, and
    /// any cached artist and album — so "praia" finds "Praiá", and an artist
    /// name pulls up everything played from them.
    func search(_ query: String) -> [RecentItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            let haystack = [item.displayName, item.folderName, item.taggedTitle, item.artist, item.album]
                .compactMap(\.self)
            return haystack.contains {
                $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    // MARK: - Mutations

    /// Records a play and returns the entry, moving an existing one to the top
    /// rather than duplicating it.
    @discardableResult
    func recordPlay(url: URL, isVideo: Bool) -> RecentItem {
        let standardized = url.standardizedFileURL
        var item: RecentItem

        if let index = indexOfEntry(matching: standardized) {
            item = items.remove(at: index)
            item.lastPlayed = Date()
            item.path = standardized.path
            item.displayName = standardized.deletingPathExtension().lastPathComponent
            item.isVideo = isVideo
            if item.bookmark == nil {
                item.bookmark = try? standardized.bookmarkData()
            }
        } else {
            item = RecentItem(url: standardized, isVideo: isVideo)
        }

        items.insert(item, at: 0)
        missingIDs.remove(item.id)
        trimToCapacity()
        scheduleSave()
        return item
    }

    func updateProgress(id: UUID, time: Double, duration: Double?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let duration, duration > 0 {
            items[index].duration = duration
            // Treat "watched to the end" as finished so it reopens from the
            // start instead of the closing seconds.
            items[index].resumeTime = time < duration - 10 ? time : nil
        } else {
            items[index].resumeTime = time > 5 ? time : nil
        }
        scheduleSave()
    }

    /// Caches tags read during playback onto the entry, so the list can show
    /// them later without touching the files.
    func updateMetadata(id: UUID, title: String?, artist: String?, album: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let unchanged = items[index].taggedTitle == title
            && items[index].artist == artist
            && items[index].album == album
        guard !unchanged else { return }

        if let title { items[index].taggedTitle = title }
        if let artist { items[index].artist = artist }
        if let album { items[index].album = album }
        scheduleSave()
    }

    func clearResume(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].resumeTime = nil
        scheduleSave()
    }

    /// Writes back a healed bookmark and path after a file was found somewhere new.
    func updateLocation(id: UUID, url: URL, bookmark: Data?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].path = url.path
        items[index].displayName = url.deletingPathExtension().lastPathComponent
        if let bookmark { items[index].bookmark = bookmark }
        missingIDs.remove(id)
        scheduleSave()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        missingIDs.remove(id)
        scheduleSave()
    }

    func removeMissing() {
        items.removeAll { missingIDs.contains($0.id) }
        missingIDs.removeAll()
        scheduleSave()
    }

    func removeAll() {
        items.removeAll()
        missingIDs.removeAll()
        scheduleSave()
    }

    // MARK: - Availability

    /// Re-checks every entry against the disk. Called when the list appears and
    /// when the app returns to the foreground, so a file deleted behind the
    /// app's back shows as missing without a restart.
    func refreshAvailability() async {
        let snapshot = items
        let results = await Task.detached(priority: .utility) { () -> [(UUID, URL?, Data?)] in
            snapshot.map { item in
                guard let location = item.resolveLocation() else { return (item.id, nil, nil) }
                return (item.id, location.url, location.refreshedBookmark)
            }
        }.value

        var missing: Set<UUID> = []
        for (id, url, refreshedBookmark) in results {
            guard let url else {
                missing.insert(id)
                continue
            }
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            if items[index].path != url.path || refreshedBookmark != nil {
                items[index].path = url.path
                items[index].displayName = url.deletingPathExtension().lastPathComponent
                if let refreshedBookmark { items[index].bookmark = refreshedBookmark }
            }
        }
        missingIDs = missing
        scheduleSave()
    }

    // MARK: - Persistence

    private func indexOfEntry(matching url: URL) -> Int? {
        if let index = items.firstIndex(where: { $0.path == url.path }) { return index }
        // The same file may already be listed under an older path; the bookmark
        // is what actually identifies it.
        return items.firstIndex { item in
            guard let location = item.resolveLocation() else { return false }
            return location.url.standardizedFileURL == url
        }
    }

    private func trimToCapacity() {
        guard items.count > Self.capacity else { return }
        let dropped = items[Self.capacity...].map(\.id)
        items.removeLast(items.count - Self.capacity)
        missingIDs.subtract(dropped)
    }

    /// Coalesces the frequent writes that come from progress updates.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = items
        let url = storeURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                guard let data = try? encoder.encode(snapshot) else { return }
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }

    /// Flushes immediately, for app termination where the debounce would not fire.
    func saveNow() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return }
        items = Array(decoded.prefix(Self.capacity))
    }
}
