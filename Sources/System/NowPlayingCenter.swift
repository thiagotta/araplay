import AppKit
import MediaPlayer

/// Publishes what AraPlay is playing to Control Center and the Now Playing
/// widget, and accepts the hardware media keys.
///
/// This is most of what "feels like a real system audio player" means in
/// practice: F8 pauses it, the Control Center tile shows the artwork, and the
/// scrubber there moves the playhead here.
@MainActor
final class NowPlayingCenter {
    private weak var player: PlayerController?
    private var hasRegisteredCommands = false
    private var lastArtworkData: Data?
    private var cachedArtwork: MPMediaItemArtwork?

    init(player: PlayerController) {
        self.player = player
        registerCommands()
    }

    private func registerCommands() {
        guard !hasRegisteredCommands else { return }
        hasRegisteredCommands = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.play()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.togglePlayPause()
            return .success
        }

        center.stopCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.pause()
            return .success
        }

        // Previous/next walk the recents history, which is AraPlay's stand-in
        // for a playlist. Previous follows the usual audio-player rule of
        // restarting the current file unless it just started.
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let player = self?.player else { return .commandFailed }
            player.skipBackward()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let player = self?.player, player.canGoNext else { return .noSuchContent }
            player.playNext()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [30]
        center.skipBackwardCommand.preferredIntervals = [15]

        center.skipForwardCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            player.seek(byOffset: event.interval)
            return .success
        }

        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            player.seek(byOffset: -event.interval)
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let player = self?.player,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            player.seek(to: event.positionTime)
            return .success
        }

    }

    /// Mirrors the player's state into the Now Playing info centre. Called
    /// whenever the observed state changes rather than on a timer — Control
    /// Center extrapolates the playhead from `elapsedTime` and `rate`.
    func update(from player: PlayerController) {
        let center = MPNowPlayingInfoCenter.default()

        guard player.currentURL != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = player.displayTitle
        if let artist = player.mediaInfo.artist { info[MPMediaItemPropertyArtist] = artist }
        if let albumArtist = player.mediaInfo.albumArtist { info[MPMediaItemPropertyAlbumArtist] = albumArtist }
        if let album = player.mediaInfo.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let composer = player.mediaInfo.composer { info[MPMediaItemPropertyComposer] = composer }
        if let genre = player.mediaInfo.genre { info[MPMediaItemPropertyGenre] = genre }
        if let track = player.mediaInfo.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = track }
        if let total = player.mediaInfo.trackTotal { info[MPMediaItemPropertyAlbumTrackCount] = total }
        if player.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = player.duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? Double(player.rate) : 0.0
        info[MPNowPlayingInfoPropertyMediaType] = player.hasVideo
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue

        if let artwork = artwork(for: player.mediaInfo.artwork) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
    }

    /// Building an `MPMediaItemArtwork` decodes the image, so it is cached until
    /// the underlying bytes change.
    private func artwork(for data: Data?) -> MPMediaItemArtwork? {
        guard let data else {
            lastArtworkData = nil
            cachedArtwork = nil
            return nil
        }
        if data == lastArtworkData { return cachedArtwork }
        guard let image = NSImage(data: data) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        lastArtworkData = data
        cachedArtwork = artwork
        return artwork
    }
}
