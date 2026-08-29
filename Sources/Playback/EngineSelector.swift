import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Decides which backend opens a given file.
///
/// The policy is "AVFoundation unless proven otherwise": it is cheaper, cooler,
/// and unlocks AirPlay/PiP/Now Playing. Anything AVFoundation can't prove it can
/// play goes to mpv. `PlayerController` still keeps a runtime fallback in case
/// this probe is wrong in the optimistic direction.
enum EngineSelector {
    /// Whether an mpv backend was compiled into this build.
    static var isMPVAvailable: Bool {
        #if canImport(Libmpv)
        true
        #else
        false
        #endif
    }

    /// Containers and codecs AVFoundation is known to reject, or to open with
    /// only part of the streams decodable (silent MKV audio being the classic).
    /// Probing these wastes time and can produce a half-working AVPlayer, so
    /// they skip the probe entirely.
    private static let mpvOnlyExtensions: Set<String> = [
        "mkv", "mka", "mks", "webm",
        "avi", "divx", "ogm",
        "flv", "f4v",
        "wmv", "asf", "wma",
        "rm", "rmvb",
        "vob", "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "tp",
        "ogg", "oga", "ogv", "opus", "spx",
        "ape", "wv", "tta", "tak", "mpc",
        "dsf", "dff",
        "amv", "nut", "y4m", "mxf", "dv",
        "it", "mod", "s3m", "xm", "mid", "midi",
    ]

    static func decide(for url: URL) async -> EngineKind {
        guard isMPVAvailable else { return .avFoundation }

        let ext = url.pathExtension.lowercased()
        if mpvOnlyExtensions.contains(ext) {
            return .mpv
        }

        return await canAVFoundationPlay(url) ? .avFoundation : .mpv
    }

    /// Asks AVFoundation directly rather than trusting a format allowlist: it
    /// loads the asset's tracks and requires at least one decodable audio or
    /// video track.
    private static func canAVFoundationPlay(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        do {
            guard try await asset.load(.isPlayable) else { return false }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for track in videoTracks + audioTracks {
                if try await track.load(.isDecodable) { return true }
            }
            return false
        } catch {
            return false
        }
    }

    /// A best-effort guess used before the file is opened, so the stage can pick
    /// its layout (video canvas vs. artwork) without a flash of the wrong one.
    static func looksLikeVideo(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
            if type.conforms(to: .audio) { return false }
        }
        let videoExtensions: Set<String> = [
            "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "divx", "wmv", "asf",
            "flv", "f4v", "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "vob", "ogv",
            "rm", "rmvb", "3gp", "3g2", "mxf", "dv", "y4m",
        ]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
}
