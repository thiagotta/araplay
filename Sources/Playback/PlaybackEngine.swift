import AppKit
import Foundation

/// Which backend is driving playback.
///
/// AraPlay prefers `avFoundation` because it is the OS-native path: hardware
/// decode, the lowest power draw, and room to grow into AirPlay and PiP. `mpv`
/// is the catch-all for everything AVFoundation refuses to open (MKV, Opus,
/// VP9-in-WebM, APE, ...).
enum EngineKind: String, Sendable {
    case avFoundation
    case mpv

    var displayName: String {
        switch self {
        case .avFoundation: "AVFoundation"
        case .mpv: "mpv"
        }
    }
}

/// Everything the UI needs to know about the loaded media.
///
/// Assembled from two independent sources: the engine reports what it is
/// actually decoding (video or not, and at what size), while `MediaMetadataReader`
/// reads the file's tags. Whichever arrives second fills in the gaps rather than
/// replacing what is already known.
struct MediaInfo: Equatable, Sendable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?

    var hasVideo: Bool = false
    var naturalSize: CGSize?
    var artwork: Data?

    /// True when there is something worth showing beyond a bare file name.
    var hasTags: Bool {
        artist != nil || album != nil || genre != nil || year != nil || composer != nil
    }

    /// Returns a copy with every value `other` actually carries copied over.
    ///
    /// The engine report and the tag read arrive in either order and each knows
    /// only part of the picture, so the merge is deliberately order-tolerant:
    /// a source can add what it knows but never blank out what another found.
    func applying(_ other: MediaInfo) -> MediaInfo {
        var merged = self
        if let value = other.title { merged.title = value }
        if let value = other.artist { merged.artist = value }
        if let value = other.albumArtist { merged.albumArtist = value }
        if let value = other.album { merged.album = value }
        if let value = other.composer { merged.composer = value }
        if let value = other.genre { merged.genre = value }
        if let value = other.year { merged.year = value }
        if let value = other.trackNumber { merged.trackNumber = value }
        if let value = other.trackTotal { merged.trackTotal = value }
        if let value = other.naturalSize { merged.naturalSize = value }
        if let value = other.artwork { merged.artwork = value }
        if other.hasVideo { merged.hasVideo = true }
        return merged
    }
}

enum PlaybackFailure: Error {
    /// The engine could not open the file at all — the caller should try the
    /// next engine in line rather than surfacing this to the user.
    case unsupported(underlying: Error?)
    /// The file opened but playback broke down partway through.
    case playbackFailed(underlying: Error?)
    case fileMissing
}

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func engineDidUpdateTime(_ engine: PlaybackEngine, time: Double)
    func engineDidUpdateDuration(_ engine: PlaybackEngine, duration: Double)
    func engineDidChangePlaying(_ engine: PlaybackEngine, isPlaying: Bool)
    func engineDidLoadMediaInfo(_ engine: PlaybackEngine, info: MediaInfo)
    func engineDidFinish(_ engine: PlaybackEngine)
    func engineDidFail(_ engine: PlaybackEngine, failure: PlaybackFailure)
    /// The engine's view changed size. Only mpv reports this, and only because
    /// it cannot discover the size for itself once running.
    func engineViewDidResize(_ engine: PlaybackEngine, size: CGSize)
}

/// A uniform surface over AVFoundation and mpv so `PlayerController` can swap
/// one for the other mid-file without the UI noticing.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    var delegate: PlaybackEngineDelegate? { get set }

    /// The layer-backed view that renders video. Always present so the stage
    /// can install it once; stays black for audio-only files.
    var renderView: NSView { get }

    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }

    var volume: Float { get set }
    /// Muting is separate from volume so the UI can restore the prior level.
    var isMuted: Bool { get set }
    var rate: Float { get set }

    func load(url: URL, startAt: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func shutdown()
}

extension PlaybackEngine {
    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(byOffset offset: Double) {
        let target = (currentTime + offset).clamped(to: 0 ... max(duration, 0))
        seek(to: target)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
