import AVFoundation
import Foundation

/// Reads tags out of a media file independently of playback.
///
/// Kept separate from the engines on purpose: AVFoundation parses tags for far
/// more formats than it can decode, so even a file that ends up playing on mpv
/// usually gets its artist, album and cover art from here. mpv fills in the rest
/// for containers AVFoundation cannot open at all.
enum MediaMetadataReader {
    /// Tags only — never video track information, and never an invented title.
    /// An untagged file comes back with `title == nil`; the UI's own fallback
    /// chain (`displayTitle`, `RecentItem.label`) shows the file name, and a
    /// fabricated title here would be cached into recents as if it were a tag.
    static func read(url: URL) async -> MediaInfo {
        var info = MediaInfo()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let items = try? await allMetadata(of: asset), !items.isEmpty else { return info }

        if let title = await string(items, Keys.title), !title.isEmpty { info.title = title }
        info.artist = await string(items, Keys.artist)
        info.albumArtist = await string(items, Keys.albumArtist)
        info.album = await string(items, Keys.album)
        info.composer = await string(items, Keys.composer)
        info.genre = await string(items, Keys.genre).flatMap(normalizeGenre)

        if let raw = await string(items, Keys.year) { info.year = extractYear(from: raw) }

        if let raw = await string(items, Keys.track) {
            let parsed = parseTrack(raw)
            info.trackNumber = parsed.number
            info.trackTotal = parsed.total
        }
        if let total = await string(items, Keys.trackTotal).flatMap({ Int($0) }) {
            info.trackTotal = total
        }

        info.artwork = await data(items, Keys.artwork)
        return info
    }

    private static func allMetadata(of asset: AVURLAsset) async throws -> [AVMetadataItem] {
        async let common = asset.load(.commonMetadata)
        async let formatSpecific = asset.load(.metadata)
        // Common metadata first so its normalized values win ties over the
        // container-specific spellings of the same tag.
        return try await common + formatSpecific
    }

    // MARK: - Field lookup

    /// Identifiers per field, in priority order, covering ID3 (MP3), iTunes
    /// (M4A/MP4) and QuickTime spellings of the same concepts.
    private enum Keys {
        static let title: [AVMetadataIdentifier] = [
            .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName,
            .quickTimeMetadataTitle,
        ]
        static let artist: [AVMetadataIdentifier] = [
            .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist,
            .quickTimeMetadataArtist, .id3MetadataOriginalArtist,
        ]
        static let albumArtist: [AVMetadataIdentifier] = [
            .id3MetadataBand, .iTunesMetadataAlbumArtist,
        ]
        static let album: [AVMetadataIdentifier] = [
            .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum,
            .quickTimeMetadataAlbum,
        ]
        static let composer: [AVMetadataIdentifier] = [
            .id3MetadataComposer, .iTunesMetadataComposer, .quickTimeMetadataComposer,
        ]
        static let genre: [AVMetadataIdentifier] = [
            .id3MetadataContentType, .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre,
            .quickTimeMetadataGenre,
        ]
        static let year: [AVMetadataIdentifier] = [
            .id3MetadataRecordingTime, .id3MetadataYear, .iTunesMetadataReleaseDate,
            .commonIdentifierCreationDate, .quickTimeMetadataYear,
        ]
        static let track: [AVMetadataIdentifier] = [
            .id3MetadataTrackNumber, .iTunesMetadataTrackNumber,
        ]
        static let trackTotal: [AVMetadataIdentifier] = [
            .iTunesMetadataDiscNumber,
        ]
        static let artwork: [AVMetadataIdentifier] = [
            .commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt,
        ]
    }

    private static func string(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Some ID3 frames arrive as numbers rather than text.
                if let number = try? await item.load(.numberValue) {
                    return number.stringValue
                }
            }
        }
        return nil
    }

    private static func data(_ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier]) async -> Data? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = try? await item.load(.dataValue), !value.isEmpty { return value }
            }
        }
        return nil
    }

    // MARK: - Value cleanup

    /// ID3 genres can arrive as a bare ID3v1 index or as "(17)Rock". Keep the
    /// text, drop the index; a numeric-only genre is not worth showing.
    static func normalizeGenre(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("("), let close = value.firstIndex(of: ")") {
            let index = value[value.index(after: value.startIndex) ..< close]
            if Int(index) != nil {
                value = String(value[value.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if value.isEmpty || Int(value) != nil { return nil }
        return value
    }

    /// Dates show up as "2001", "2001-07-23" or a full timestamp.
    static func extractYear(from raw: String) -> Int? {
        guard let match = raw.range(of: "\\d{4}", options: .regularExpression) else { return nil }
        return Int(raw[match])
    }

    /// ID3 track numbers are commonly "3/14".
    static func parseTrack(_ raw: String) -> (number: Int?, total: Int?) {
        let parts = raw.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let first = parts.first else { return (nil, nil) }
        return (Int(first), parts.count > 1 ? Int(parts[1]) : nil)
    }
}
