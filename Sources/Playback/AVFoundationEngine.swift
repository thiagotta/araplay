import AVFoundation
import AppKit

/// Hosts an `AVPlayerLayer` and keeps it sized to the view.
final class AVPlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Keep AppKit's own backing layer rather than substituting one, which
        // would make the view layer-hosting and hand us its geometry to manage.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The layer tree must not animate along with live resizes, or the video
        // lags a frame behind the window edge.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

@MainActor
final class AVFoundationEngine: NSObject, PlaybackEngine {
    let kind: EngineKind = .avFoundation
    weak var delegate: PlaybackEngineDelegate?

    private let player = AVPlayer()
    private let hostView = AVPlayerHostView(frame: .zero)
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var metadataTask: Task<Void, Never>?

    /// Set while `load` is settling. A failure during this window means the file
    /// is unsupported (so the controller should retry with mpv); a failure after
    /// it means playback broke mid-stream.
    private var isOpening = false
    private var pendingStartTime: Double = 0

    var renderView: NSView { hostView }

    var currentTime: Double {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : 0
    }

    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var rate: Float = 1.0 {
        didSet { if isPlaying { player.rate = rate } }
    }

    override init() {
        super.init()
        hostView.playerLayer.player = player
        player.actionAtItemEnd = .pause
        installObservers()
    }

    // MARK: - Loading

    func load(url: URL, startAt: Double) {
        isOpening = true
        pendingStartTime = startAt
        duration = 0

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        observeItem(item)
        player.replaceCurrentItem(with: item)

        loadTrackShape(of: asset)
    }

    /// Reports only what is being decoded. Tags — including artwork — come from
    /// `MediaMetadataReader`, which runs for every file regardless of engine.
    private func loadTrackShape(of asset: AVURLAsset) {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            var info = MediaInfo()

            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
                info.hasVideo = true
                if let size = try? await videoTrack.load(.naturalSize) {
                    let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
                    info.naturalSize = size.applying(transform).standardizedSize
                }
            }

            guard !Task.isCancelled else { return }
            let resolved = info
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.delegate?.engineDidLoadMediaInfo(self, info: resolved)
            }
        }
    }

    // MARK: - Transport

    func play() {
        player.rate = rate
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        delegate?.engineDidUpdateTime(self, time: seconds)
    }

    func shutdown() {
        metadataTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
    }

    // MARK: - Observation

    private func installObservers() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.delegate?.engineDidUpdateTime(self, time: time.seconds)
            }
        }

        // KVO fires on whichever thread mutated the property, which for AVPlayer
        // is often not the main one — so every handler hops explicitly rather
        // than asserting isolation it does not have.
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, playing != self.isPlaying else { return }
                    self.isPlaying = playing
                    self.delegate?.engineDidChangePlaying(self, isPlaying: playing)
                }
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        durationObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch status {
                    case .readyToPlay: self.finishOpening()
                    case .failed: self.reportFailure(error)
                    default: break
                    }
                }
            }
        }

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let duration = item.duration
            guard duration.isNumeric else { return }
            let seconds = duration.seconds
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, seconds > 0, seconds != self.duration else { return }
                    self.duration = seconds
                    self.delegate?.engineDidUpdateDuration(self, duration: seconds)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.engineDidFinish(self)
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reportFailure(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            }
        }
    }

    private func finishOpening() {
        guard isOpening else { return }
        isOpening = false
        if pendingStartTime > 0 {
            seek(to: pendingStartTime)
            pendingStartTime = 0
        }
    }

    private func reportFailure(_ error: Error?) {
        let failure: PlaybackFailure = isOpening
            ? .unsupported(underlying: error)
            : .playbackFailed(underlying: error)
        isOpening = false
        delegate?.engineDidFail(self, failure: failure)
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        durationObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
    }
}

private extension CGSize {
    /// Video tracks carry a rotation transform; applying it can flip signs.
    var standardizedSize: CGSize { CGSize(width: abs(width), height: abs(height)) }
}
