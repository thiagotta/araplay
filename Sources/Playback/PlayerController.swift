import AVFoundation
import AppKit
import Observation

/// Owns the active engine and is the single source of truth the UI binds to.
///
/// Engine choice is invisible to the rest of the app: `PlayerController` picks
/// AVFoundation when it can, silently re-opens the same file on mpv when
/// AVFoundation turns out not to handle it, and keeps the playhead across the
/// swap so the fallback is not something the user sees.
@MainActor
@Observable
final class PlayerController {
    // MARK: - Published state

    private(set) var currentURL: URL?
    private(set) var currentItemID: UUID?
    private(set) var mediaInfo = MediaInfo()
    private(set) var engineKind: EngineKind?
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isSeeking = false
    private(set) var errorMessage: String?
    /// True while the stage should show a video canvas rather than artwork.
    private(set) var hasVideo = false
    /// Set when playback reaches the end and cleared by anything that moves the
    /// playhead. The transport swaps to a replay button while it is true.
    private(set) var isAtEnd = false

    var volume: Float = 1.0 {
        didSet {
            engine?.volume = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeDefaultsKey)
            if volume > 0, isMuted { isMuted = false }
        }
    }

    var isMuted = false {
        didSet { engine?.isMuted = isMuted }
    }

    var rate: Float = 1.0 {
        didSet { engine?.rate = rate }
    }

    // MARK: - Internals

    private static let volumeDefaultsKey = "playbackVolume"

    private let recents: RecentsStore
    private var engine: (any PlaybackEngine)?
    /// Retained so a mid-file engine swap can reload the same file.
    private var loadedURL: URL?
    private var hasTriedFallback = false
    private var progressSaveCounter = 0
    private var tagTask: Task<Void, Never>?
    private var resizeWork: DispatchWorkItem?
    /// The view size the current engine was built for, and when it was built.
    private var sizeAtActivation: CGSize = .zero
    private var lastActivation = Date.distantPast

    /// What to put on screen and in Now Playing: the tagged title when the file
    /// has one, the file name until then.
    var displayTitle: String {
        if let title = mediaInfo.title, !title.isEmpty { return title }
        return currentURL?.deletingPathExtension().lastPathComponent ?? "AraPlay"
    }

    /// The view the stage installs. Recreated whenever the engine changes, so
    /// the stage observes `renderViewGeneration` to know when to re-attach.
    private(set) var renderViewGeneration = 0
    var renderView: NSView? { engine?.renderView }

    init(recents: RecentsStore) {
        self.recents = recents
        if let stored = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) as? Float {
            volume = stored
        }
    }

    // MARK: - Opening files

    /// Opens a file in the existing window, pushing whatever was playing down
    /// into the recents list.
    func open(url: URL, resume: Bool = true) {
        let standardized = url.standardizedFileURL

        guard FileManager.default.fileExists(atPath: standardized.path) else {
            errorMessage = "\(standardized.lastPathComponent) could not be found."
            return
        }

        let looksLikeVideo = EngineSelector.looksLikeVideo(standardized)
        let item = recents.recordPlay(url: standardized, isVideo: looksLikeVideo)
        historyIndex = 0
        beginPlayback(url: standardized, item: item, isVideo: looksLikeVideo, resume: resume)
    }

    /// Opens a recents entry, following the file if it has moved since.
    func open(item: RecentItem) {
        guard let location = item.resolveLocation() else {
            errorMessage = "\(item.displayName) is missing. It may have been deleted or moved to a disconnected volume."
            Task { await recents.refreshAvailability() }
            return
        }
        recents.updateLocation(id: item.id, url: location.url, bookmark: location.refreshedBookmark)
        open(url: location.url)
    }

    private func beginPlayback(url: URL, item: RecentItem, isVideo: Bool, resume: Bool) {
        persistProgress(force: true)

        // Retire the outgoing engine before the asynchronous engine decision
        // below. Otherwise it keeps playing while the next file is being sized
        // up, and its time updates land on the new entry once `currentItemID`
        // moves — which is how a three-second play ends up recorded as a
        // minute-long resume position.
        engine?.shutdown()
        engine = nil
        engineKind = nil
        isPlaying = false
        renderViewGeneration += 1

        errorMessage = nil
        isAtEnd = false
        hasTriedFallback = false
        loadedURL = url
        currentURL = url
        currentTime = 0
        duration = 0

        hasVideo = isVideo
        // Deliberately no title here: it is filled from tags, and the UI falls
        // back to the file name through `displayTitle` until they arrive.
        mediaInfo = MediaInfo(hasVideo: isVideo)

        currentItemID = item.id
        let startAt = resume ? (item.resumeTime ?? 0) : 0

        Task {
            let kind = await EngineSelector.decide(for: url)
            guard loadedURL == url else { return } // superseded by a newer open
            activate(engineKind: kind, url: url, startAt: startAt)
        }

        loadTags(for: url)
    }

    // MARK: - History navigation

    /// Position of the playing file within `recents.items`, which is what the
    /// previous/next buttons step through.
    ///
    /// Stepping deliberately does *not* reorder the list. Moving each visited
    /// file to the top would make "next" return to where "previous" came from,
    /// leaving the two buttons ping-ponging between a pair of files instead of
    /// walking the history. Opening a file any other way still moves it to the top.
    private(set) var historyIndex: Int?

    /// How far into a file the back button stops meaning "previous track" and
    /// starts meaning "start this one over" — the convention every audio player
    /// shares. Internal so the transport's tooltip can quote it.
    static let restartThreshold: Double = 2

    var canGoPrevious: Bool { neighborIndex(step: 1) != nil }
    var canGoNext: Bool { neighborIndex(step: -1) != nil }

    /// Older entries sit further down the array, so stepping to the *previous*
    /// track means moving forward through it. Missing files are skipped.
    private func neighborIndex(step: Int) -> Int? {
        guard let historyIndex else { return nil }
        var index = historyIndex + step
        while recents.items.indices.contains(index) {
            if !recents.isMissing(recents.items[index]) { return index }
            index += step
        }
        return nil
    }

    /// The back button: restarts the current file, or steps back one when
    /// pressed in the first couple of seconds.
    func skipBackward() {
        guard currentTime < Self.restartThreshold, canGoPrevious else {
            seek(to: 0)
            return
        }
        playPrevious()
    }

    func playPrevious() {
        guard let index = neighborIndex(step: 1) else { return }
        playHistoryItem(at: index)
    }

    func playNext() {
        guard let index = neighborIndex(step: -1) else { return }
        playHistoryItem(at: index)
    }

    private func playHistoryItem(at index: Int) {
        guard recents.items.indices.contains(index) else { return }
        let item = recents.items[index]

        guard let location = item.resolveLocation() else {
            errorMessage = "\(item.displayName) is missing. It may have been deleted or moved to a disconnected volume."
            Task { await recents.refreshAvailability() }
            return
        }
        recents.updateLocation(id: item.id, url: location.url, bookmark: location.refreshedBookmark)

        historyIndex = index
        beginPlayback(url: location.url, item: item, isVideo: item.isVideo, resume: true)
    }

    // MARK: - Tags

    /// Reads the file's tags alongside playback. Runs for every file regardless
    /// of engine, because AVFoundation parses tags for far more formats than it
    /// can decode.
    private func loadTags(for url: URL) {
        tagTask?.cancel()
        tagTask = Task { [weak self] in
            let tags = await MediaMetadataReader.read(url: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.loadedURL == url else { return }
                self.mediaInfo = self.mediaInfo.applying(tags)
                self.storeTagsInRecents()
            }
        }
    }

    /// Mirrors artist and album into the recents entry so the sidebar can label
    /// rows with them instead of the containing folder.
    private func storeTagsInRecents() {
        guard let currentItemID else { return }
        recents.updateMetadata(
            id: currentItemID,
            title: mediaInfo.title,
            artist: mediaInfo.artist ?? mediaInfo.albumArtist,
            album: mediaInfo.album
        )
    }

    private func activate(engineKind kind: EngineKind, url: URL, startAt: Double) {
        resizeWork?.cancel()
        lastActivation = Date()
        sizeAtActivation = .zero
        engine?.shutdown()

        let newEngine: any PlaybackEngine = switch kind {
        case .avFoundation: AVFoundationEngine()
        case .mpv: MPVEngine()
        }
        newEngine.delegate = self
        newEngine.volume = volume
        newEngine.isMuted = isMuted
        newEngine.rate = rate

        engine = newEngine
        engineKind = kind
        renderViewGeneration += 1

        newEngine.load(url: url, startAt: startAt)
        newEngine.play()
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let engine else { return }
        if isAtEnd { replay(); return }
        engine.togglePlayPause()
    }

    func play() {
        guard engine != nil else { return }
        if isAtEnd { replay(); return }
        engine?.play()
    }

    /// Starts the finished file again from the top. Pressing play at the end of
    /// a file should restart it rather than do nothing.
    func replay() {
        guard let engine else { return }
        isAtEnd = false
        seek(to: 0)
        engine.play()
    }

    func pause() {
        engine?.pause()
        persistProgress(force: true)
    }

    func seek(to seconds: Double) {
        guard let engine else { return }
        let target = seconds.clamped(to: 0 ... max(duration, 0))
        if target < max(duration - 0.5, 0) { isAtEnd = false }
        currentTime = target
        engine.seek(to: target)
    }

    func seek(byOffset offset: Double) {
        guard engine != nil else { return }
        seek(to: currentTime + offset)
    }

    /// Called while the user drags the scrubber, so incoming time updates from
    /// the engine do not fight the thumb.
    func beginScrubbing() { isSeeking = true }

    func endScrubbing(at seconds: Double) {
        isSeeking = false
        seek(to: seconds)
    }

    func toggleMute() { isMuted.toggle() }

    func stop() {
        persistProgress(force: true)
        tagTask?.cancel()
        engine?.shutdown()
        engine = nil
        engineKind = nil
        currentURL = nil
        loadedURL = nil
        currentItemID = nil
        historyIndex = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        mediaInfo = MediaInfo()
        renderViewGeneration += 1
    }

    // MARK: - Progress

    private func persistProgress(force: Bool = false) {
        guard let currentItemID, duration > 0 || force else { return }
        guard currentTime > 0 else { return }
        recents.updateProgress(id: currentItemID, time: currentTime, duration: duration > 0 ? duration : nil)
    }

    func applicationWillTerminate() {
        persistProgress(force: true)
        engine?.shutdown()
        recents.saveNow()
    }
}

// MARK: - PlaybackEngineDelegate

extension PlayerController: PlaybackEngineDelegate {
    func engineDidUpdateTime(_ engine: any PlaybackEngine, time: Double) {
        guard engine === self.engine, !isSeeking else { return }
        currentTime = time

        // Roughly every two seconds of playback, cheap enough to run inline and
        // frequent enough that a crash loses almost nothing.
        progressSaveCounter += 1
        if progressSaveCounter >= 20 {
            progressSaveCounter = 0
            persistProgress()
        }
    }

    func engineDidUpdateDuration(_ engine: any PlaybackEngine, duration: Double) {
        guard engine === self.engine else { return }
        self.duration = duration
    }

    func engineDidChangePlaying(_ engine: any PlaybackEngine, isPlaying: Bool) {
        guard engine === self.engine else { return }
        self.isPlaying = isPlaying
        if !isPlaying { persistProgress() }
    }

    func engineDidLoadMediaInfo(_ engine: any PlaybackEngine, info: MediaInfo) {
        guard engine === self.engine else { return }
        mediaInfo = mediaInfo.applying(info)
        if info.hasVideo { hasVideo = true }
        storeTagsInRecents()
    }

    func engineDidFinish(_ engine: any PlaybackEngine) {
        guard engine === self.engine else { return }
        isPlaying = false
        isAtEnd = true
        if let currentItemID { recents.clearResume(id: currentItemID) }
    }

    /// mpv cannot discover the window size once it has been handed a layer, so
    /// after the first frame it keeps rendering for the viewport it was built
    /// with: the picture stays its original size while the window grows.
    /// Rebuilding the engine is the one reliable way to make it take the new
    /// size, so it happens once the resize settles rather than during the drag.
    func engineViewDidResize(_ engine: any PlaybackEngine, size: CGSize) {
        guard engine === self.engine, engine.kind == .mpv, hasVideo, loadedURL != nil else { return }

        // A freshly built engine's view settles over several layout passes.
        // Those are the size it was built for, not a change to react to.
        guard Date().timeIntervalSince(lastActivation) > 1.0 else {
            sizeAtActivation = size
            return
        }
        guard abs(size.width - sizeAtActivation.width) > 1
            || abs(size.height - sizeAtActivation.height) > 1 else { return }

        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildEngineAfterResize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func rebuildEngineAfterResize() {
        guard engineKind == .mpv, let loadedURL else { return }
        let wasPlaying = isPlaying
        let position = currentTime
        activate(engineKind: .mpv, url: loadedURL, startAt: position)
        // `activate` always starts playing; honour a paused file.
        if !wasPlaying { engine?.pause() }
    }

    func engineDidFail(_ engine: any PlaybackEngine, failure: PlaybackFailure) {
        guard engine === self.engine else { return }

        // AVFoundation could not open it after all — hand the file to mpv at the
        // position we had reached, without telling the user anything happened.
        if case .unsupported = failure,
           engine.kind == .avFoundation,
           !hasTriedFallback,
           EngineSelector.isMPVAvailable,
           let loadedURL
        {
            hasTriedFallback = true
            activate(engineKind: .mpv, url: loadedURL, startAt: currentTime)
            return
        }

        isPlaying = false
        errorMessage = Self.describe(failure, fileName: loadedURL?.lastPathComponent)
    }

    private static func describe(_ failure: PlaybackFailure, fileName: String?) -> String {
        let name = fileName ?? "This file"
        switch failure {
        case .fileMissing:
            return "\(name) could not be found."
        case .unsupported(let underlying):
            let detail = underlying?.localizedDescription
            return detail.map { "\(name) could not be played: \($0)" }
                ?? "\(name) is not in a format AraPlay can play."
        case .playbackFailed(let underlying):
            let detail = underlying?.localizedDescription
            return detail.map { "Playback of \(name) stopped: \($0)" }
                ?? "Playback of \(name) stopped unexpectedly."
        }
    }
}
