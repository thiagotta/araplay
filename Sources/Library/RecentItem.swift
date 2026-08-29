import Foundation

/// One entry in the recently-played list.
///
/// The bookmark is the source of truth for locating the file; `path` is a cached
/// last-known location used for display and as a fallback when the bookmark
/// cannot be resolved. Because bookmarks track files across moves and renames,
/// an entry can heal itself and only a genuinely deleted file shows as missing.
struct RecentItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var bookmark: Data?
    var path: String
    var displayName: String
    var lastPlayed: Date
    /// Cached from the file's tags so the sidebar can label a row properly
    /// without re-reading every file to draw the list.
    var taggedTitle: String?
    var artist: String?
    var album: String?
    var duration: Double?
    /// Where playback stopped, so reopening resumes in place. Cleared once the
    /// file plays to the end or is watched to within a few seconds of it.
    var resumeTime: Double?
    var isVideo: Bool

    var url: URL { URL(fileURLWithPath: path) }

    var folderName: String {
        url.deletingLastPathComponent().lastPathComponent
    }

    /// The song's own title once tags have been read, falling back to the file
    /// name — which for a downloaded track is often the artist, album and title
    /// mashed into one long string.
    var label: String {
        if let taggedTitle, !taggedTitle.isEmpty { return taggedTitle }
        return displayName
    }

    /// What the sidebar puts under the title: the artist when the file is
    /// tagged, otherwise the folder it lives in.
    var subtitle: String {
        if let artist, !artist.isEmpty { return artist }
        return folderName
    }

    /// Fraction watched, for the progress hairline under the row.
    ///
    /// Nil below 5%, because a sliver of fill under an otherwise empty track
    /// reads as a stray underline rather than as progress, and nil above 98%,
    /// where the file is effectively finished.
    var progress: Double? {
        guard let duration, duration > 0, let resumeTime, resumeTime > 5 else { return nil }
        let fraction = resumeTime / duration
        return (0.05 ... 0.98).contains(fraction) ? fraction : nil
    }
}

extension RecentItem {
    init(url: URL, isVideo: Bool) {
        self.init(
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            path: url.path,
            displayName: url.deletingPathExtension().lastPathComponent,
            lastPlayed: Date(),
            taggedTitle: nil,
            artist: nil,
            album: nil,
            duration: nil,
            resumeTime: nil,
            isVideo: isVideo
        )
    }

    /// Resolves the bookmark, following the file if it moved.
    ///
    /// Returns the current URL plus a refreshed bookmark when the system reports
    /// the old one as stale, so the caller can write the update back.
    func resolveLocation() -> (url: URL, refreshedBookmark: Data?)? {
        if let bookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: resolved.path) {
                let refreshed = isStale ? try? resolved.bookmarkData() : nil
                return (resolved, refreshed)
            }
        }

        // No bookmark, or it pointed at something that no longer exists. The
        // cached path is the last chance — it still works for the common case of
        // a file that never moved.
        let fallback = url
        if FileManager.default.fileExists(atPath: fallback.path) {
            return (fallback, try? fallback.bookmarkData())
        }
        return nil
    }
}
