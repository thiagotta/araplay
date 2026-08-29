import AppKit

#if canImport(Libmpv)
import Libmpv

/// Works around a MoltenVK bug where the drawable is forced to 1x1 to complete a
/// presentation, which leaves the layer stuck at 1x1 and flickering.
/// See https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard Int(newValue.width) > 1, Int(newValue.height) > 1 else { return }
            super.drawableSize = newValue
        }
    }

    /// Toggling EDR only takes effect from the main thread, and mpv sets this
    /// from its render thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

final class MPVHostView: NSView {
    let metalLayer = MPVMetalLayer()
    /// Reported after the layer geometry is brought up to date.
    var onResize: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: the view supplies its own root layer with the Metal
        // layer as a sublayer. AppKit therefore does NOT manage the sublayer's
        // geometry — `updateLayerGeometry()` below is what keeps it pinned to
        // the bounds, and it must be called from every size-changing override.
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    // This view hosts its own layer, so AppKit does not manage the sublayer's
    // geometry and layout() is not guaranteed on every bounds change. Catching
    // the frame change directly keeps the drawable in step with the window.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayerGeometry()
    }

    /// Also fires when the window moves between displays of different scale,
    /// which changes how many pixels the same point size needs.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerGeometry()
    }

    private func updateLayerGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let drawable = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard metalLayer.frame != bounds || metalLayer.drawableSize != drawable else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawable
        CATransaction.commit()
        onResize?(bounds.size)
    }
}

@MainActor
final class MPVEngine: PlaybackEngine {
    let kind: EngineKind = .mpv
    weak var delegate: PlaybackEngineDelegate?

    private var mpv: OpaquePointer?
    /// The same handle, reachable from the event thread. mpv calls back from its
    /// own threads, so the pump cannot touch main-actor state to find it.
    /// Cleared before the handle is destroyed, which is what makes the pump stop.
    nonisolated(unsafe) private var sharedHandle: OpaquePointer?
    private let handleLock = NSLock()

    private let hostView = MPVHostView(frame: .zero)
    private let eventQueue = DispatchQueue(label: "com.araplay.mpv.events", qos: .userInitiated)
    /// Balances the `passRetained` handed to mpv's wakeup callback.
    private var callbackToken: UnsafeMutableRawPointer?
    private var hasShutDown = false

    /// mpv reports "file loaded" before it reports failures, so an error that
    /// arrives while this is set means the file is unsupported and the caller
    /// should not have routed it here.
    private var isOpening = false
    private var info = MediaInfo()
    /// mpv exposes a still cover image as a video track. Observed, not polled,
    /// so the width/height handlers can consult it without calling into mpv.
    private var isAlbumArt = false
    /// Used to tell a real title tag from mpv's filename fallback.
    private var loadedURL: URL?

    var renderView: NSView { hostView }

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false

    var volume: Float = 1.0 {
        didSet { setDouble("volume", Double(volume) * 100) }
    }

    var isMuted: Bool = false {
        didSet { setFlag("mute", isMuted) }
    }

    var rate: Float = 1.0 {
        didSet { setDouble("speed", Double(rate)) }
    }

    init() {
        setupMPV()
        hostView.onResize = { [weak self] size in
            guard let self else { return }
            self.delegate?.engineViewDidResize(self, size: size)
        }
    }

    // MARK: - Setup

    private func setupMPV() {
        guard let handle = mpv_create() else {
            NSLog("AraPlay: mpv_create failed")
            return
        }
        mpv = handle
        handleLock.lock()
        sharedHandle = handle
        handleLock.unlock()

        #if DEBUG
        check(mpv_request_log_messages(handle, "warn"))
        #else
        check(mpv_request_log_messages(handle, "no"))
        #endif

        // Render into our CAMetalLayer rather than letting mpv make a window.
        var layer = hostView.metalLayer
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layer))

        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        // AraPlay is local-files-only, so there is no reason to carry youtube-dl
        // or any network protocol handling.
        setOption("ytdl", "no")
        // The app owns the transport UI and the media keys; mpv should not also
        // grab them or draw its own OSD.
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("input-media-keys", "no")
        setOption("osc", "no")
        setOption("osd-level", "0")

        // Ignore any ~/.config/mpv on this machine. A stray user config could
        // re-enable the Lua scripts disabled below and crash the app, and AraPlay
        // should behave identically whatever mpv setup a user happens to have.
        setOption("config", "no")
        // Every one of mpv's built-in helpers is a Lua script, and LuaJIT compiles
        // code at runtime — which Hardened Runtime terminates as an invalid code
        // signature. AraPlay draws its own transport and OSD, so none of them are
        // wanted anyway; switching them off stops LuaJIT ever starting.
        setOption("load-scripts", "no")
        setOption("load-console", "no")
        setOption("load-stats-overlay", "no")
        setOption("load-auto-profiles", "no")
        setOption("load-select", "no")
        setOption("load-commands", "no")
        // Stay alive between files and hold the last frame at EOF so the window
        // does not flash black before the UI reacts.
        setOption("idle", "yes")
        setOption("keep-open", "yes")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")

        check(mpv_initialize(handle))

        for (name, format) in Self.observedProperties {
            mpv_observe_property(handle, 0, name, format)
        }

        let token = Unmanaged.passRetained(self).toOpaque()
        callbackToken = token
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let engine = Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue()
            engine.pumpEvents()
        }, token)
    }

    private static let observedProperties: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("media-title", MPV_FORMAT_STRING),
        ("width", MPV_FORMAT_INT64),
        ("height", MPV_FORMAT_INT64),
        // Tags are observed rather than read back on demand. mpv_get_property is
        // synchronous and takes the core's dispatch lock, so calling it from
        // inside mpv's own event delivery deadlocks the main thread.
        ("metadata/by-key/title", MPV_FORMAT_STRING),
        ("metadata/by-key/artist", MPV_FORMAT_STRING),
        ("metadata/by-key/album", MPV_FORMAT_STRING),
        ("metadata/by-key/album_artist", MPV_FORMAT_STRING),
        ("metadata/by-key/composer", MPV_FORMAT_STRING),
        ("metadata/by-key/genre", MPV_FORMAT_STRING),
        ("metadata/by-key/date", MPV_FORMAT_STRING),
        ("metadata/by-key/track", MPV_FORMAT_STRING),
        ("current-tracks/video/albumart", MPV_FORMAT_FLAG),
    ]

    // MARK: - PlaybackEngine

    func load(url: URL, startAt: Double) {
        guard mpv != nil else {
            delegate?.engineDidFail(self, failure: .unsupported(underlying: nil))
            return
        }
        isOpening = true
        loadedURL = url
        duration = 0
        currentTime = 0
        info = MediaInfo()

        // loadfile is `<url> [flags [index [options]]]`. The index sits between
        // the flags and the per-file options, so it has to be supplied even when
        // unused — otherwise "start=" lands in the index slot, fails to parse as
        // an integer, and the file silently never loads at all.
        var args = [url.path, "replace", "-1"]
        if startAt > 0 {
            args.append("start=\(startAt)")
        }
        command("loadfile", args: args)
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute+exact"])
        currentTime = seconds
        delegate?.engineDidUpdateTime(self, time: seconds)
    }

    func shutdown() {
        guard !hasShutDown, let handle = mpv else { return }
        hasShutDown = true
        mpv_set_wakeup_callback(handle, nil, nil)

        // Retire the handle before destroying it: the pump reads it under the
        // lock and bails when it is gone, and the drain waits for any iteration
        // that already picked it up.
        handleLock.lock()
        sharedHandle = nil
        handleLock.unlock()
        eventQueue.sync {}

        mpv_terminate_destroy(handle)
        mpv = nil
        if let callbackToken {
            Unmanaged<MPVEngine>.fromOpaque(callbackToken).release()
            self.callbackToken = nil
        }
    }

    // MARK: - Events

    /// Called by mpv from an arbitrary thread; hops to our serial queue and
    /// drains the event pipe.
    private nonisolated func pumpEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.handleLock.lock()
                let handle = self.sharedHandle
                self.handleLock.unlock()

                guard let handle else { return }
                guard let event = mpv_wait_event(handle, 0) else { return }
                if event.pointee.event_id == MPV_EVENT_NONE { return }
                self.handle(event: event.pointee)
                if event.pointee.event_id == MPV_EVENT_SHUTDOWN { return }
            }
        }
    }

    private nonisolated func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = UnsafePointer<mpv_event_property>(OpaquePointer(event.data))?.pointee else { return }
            let name = String(cString: data.name)
            let value = Self.unwrap(property: data)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(property: name, value: value) } }

        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { MainActor.assumeIsolated { self.isOpening = false } }

        case MPV_EVENT_END_FILE:
            guard let data = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.data))?.pointee else { return }
            let reason = data.reason
            let errorCode = data.error
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handleEndFile(reason: reason, errorCode: errorCode) }
            }

        case MPV_EVENT_LOG_MESSAGE:
            guard let message = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.data))?.pointee,
                  let prefix = message.prefix, let text = message.text else { return }
            NSLog("AraPlay mpv [%@] %@", String(cString: prefix), String(cString: text).trimmingCharacters(in: .newlines))

        default:
            break
        }
    }

    private nonisolated static func unwrap(property: mpv_event_property) -> Any? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_DOUBLE: return data.assumingMemoryBound(to: Double.self).pointee
        case MPV_FORMAT_FLAG: return data.assumingMemoryBound(to: Int32.self).pointee != 0
        case MPV_FORMAT_INT64: return data.assumingMemoryBound(to: Int64.self).pointee
        case MPV_FORMAT_STRING:
            guard let cString = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return String(cString: cString)
        default: return nil
        }
    }

    private func apply(property name: String, value: Any?) {
        switch name {
        case "time-pos":
            guard let time = value as? Double else { return }
            currentTime = time
            delegate?.engineDidUpdateTime(self, time: time)

        case "duration":
            guard let seconds = value as? Double, seconds > 0, seconds != duration else { return }
            duration = seconds
            delegate?.engineDidUpdateDuration(self, duration: seconds)

        case "pause":
            guard let paused = value as? Bool else { return }
            let playing = !paused
            guard playing != isPlaying else { return }
            isPlaying = playing
            delegate?.engineDidChangePlaying(self, isPlaying: playing)

        case "eof-reached":
            if value as? Bool == true { delegate?.engineDidFinish(self) }

        case "media-title":
            // mpv falls back to the file name when a file carries no title tag,
            // extension and all. That is not a title; the UI has its own fallback.
            guard let title = value as? String, !title.isEmpty,
                  title != loadedURL?.lastPathComponent else { return }
            info.title = title
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "width":
            guard let width = value as? Int64, width > 0, !isAlbumArt else { return }
            info.hasVideo = true
            info.naturalSize = CGSize(width: Double(width), height: info.naturalSize?.height ?? 0)
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "height":
            guard let height = value as? Int64, height > 0, !isAlbumArt else { return }
            info.hasVideo = true
            info.naturalSize = CGSize(width: info.naturalSize?.width ?? 0, height: Double(height))
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "current-tracks/video/albumart":
            isAlbumArt = value as? Bool ?? false

        case "metadata/by-key/title":
            guard let title = value as? String, !title.isEmpty else { return }
            info.title = title
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/artist":
            info.artist = value as? String
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/album":
            info.album = value as? String
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/album_artist":
            info.albumArtist = value as? String
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/composer":
            info.composer = value as? String
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/genre":
            info.genre = value as? String
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/date":
            info.year = (value as? String).flatMap(MediaMetadataReader.extractYear(from:))
            delegate?.engineDidLoadMediaInfo(self, info: info)

        case "metadata/by-key/track":
            let parsed = (value as? String).map(MediaMetadataReader.parseTrack(_:))
            info.trackNumber = parsed?.number
            info.trackTotal = parsed?.total
            delegate?.engineDidLoadMediaInfo(self, info: info)

        default:
            break
        }
    }

    private func handleEndFile(reason: mpv_end_file_reason, errorCode: Int32) {
        switch reason {
        case MPV_END_FILE_REASON_ERROR:
            let error = NSError(
                domain: "org.mpv",
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: mpv_error_string(errorCode))]
            )
            let failure: PlaybackFailure = isOpening
                ? .unsupported(underlying: error)
                : .playbackFailed(underlying: error)
            isOpening = false
            delegate?.engineDidFail(self, failure: failure)
        case MPV_END_FILE_REASON_EOF:
            delegate?.engineDidFinish(self)
        default:
            break
        }
    }

    // MARK: - Property helpers

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        check(mpv_set_option_string(mpv, name, value))
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    }

    private func command(_ name: String, args: [String] = []) {
        guard let mpv else { return }
        var pointers: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        defer { pointers.forEach { free(UnsafeMutableRawPointer(mutating: $0)) } }
        pointers.withUnsafeMutableBufferPointer { buffer in
            check(mpv_command(mpv, buffer.baseAddress))
        }
    }

    private func check(_ status: CInt) {
        guard status < 0 else { return }
        NSLog("AraPlay: mpv error %@", String(cString: mpv_error_string(status)))
    }
}

#else

/// Compiled when MPVKit is not linked. Keeps `PlayerController` buildable and
/// reports every file as unsupported so the UI can explain the situation.
@MainActor
final class MPVEngine: PlaybackEngine {
    let kind: EngineKind = .mpv
    weak var delegate: PlaybackEngineDelegate?

    private let placeholder = NSView(frame: .zero)
    var renderView: NSView { placeholder }

    var currentTime: Double { 0 }
    var duration: Double { 0 }
    var isPlaying: Bool { false }
    var volume: Float = 1.0
    var isMuted: Bool = false
    var rate: Float = 1.0

    func load(url _: URL, startAt _: Double) {
        delegate?.engineDidFail(self, failure: .unsupported(underlying: nil))
    }

    func play() {}
    func pause() {}
    func seek(to _: Double) {}
    func shutdown() {}
}

#endif
