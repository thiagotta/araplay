import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recents = RecentsStore()
    private(set) lazy var player = PlayerController(recents: recents)
    let registrar = DefaultAppRegistrar()

    private var nowPlaying: NowPlayingCenter?
    private var nowPlayingTimer: Timer?
    /// Files handed over before the window existed, replayed once it does.
    private var pendingOpenURL: URL?

    func applicationDidFinishLaunching(_: Notification) {
        // The player is dark by design; opting in explicitly keeps it dark for
        // users running the system in light mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        DefaultAppRegistrar.registerWithLaunchServices()

        let center = NowPlayingCenter(player: player)
        nowPlaying = center
        trackPlayerState()

        // Control Center extrapolates the playhead from the rate, so a slow
        // heartbeat is enough to keep it honest after seeks.
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.isPlaying else { return }
                self.nowPlaying?.update(from: self.player)
            }
        }

        if let pendingOpenURL {
            self.pendingOpenURL = nil
            player.open(url: pendingOpenURL)
        }
    }

    // MARK: - Opening files from the system

    /// Every open from the Finder, the Dock, or `open(1)` lands here. Because
    /// AraPlay uses a single `Window` scene, this reuses the existing window and
    /// whatever was playing gets pushed down the recents list.
    func application(_: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }

        guard nowPlaying != nil else {
            // Launched by this open; the window is not up yet.
            pendingOpenURL = url
            return
        }

        player.open(url: url)
        presentWindow()
    }

    // MARK: - Dock menu

    /// The ten most recent playable files, for right-click quick play from the
    /// Dock. Missing files are left out rather than shown struck through: a Dock
    /// menu has no room to explain why an entry would not play.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let available = recents.items.lazy.filter { !self.recents.isMissing($0) }.prefix(10)
        guard !available.isEmpty else { return nil }

        let menu = NSMenu()
        for item in available {
            let entry = NSMenuItem(
                title: item.label,
                action: #selector(playRecentFromDock(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = item.id
            if let artist = item.artist, !artist.isEmpty {
                entry.toolTip = "\(item.label) — \(artist)"
            }
            entry.image = NSImage(
                systemSymbolName: item.isVideo ? "film" : "music.note",
                accessibilityDescription: nil
            )
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func playRecentFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = recents.items.first(where: { $0.id == id })
        else { return }
        player.open(item: item)
        presentWindow()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { presentWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {
        nowPlayingTimer?.invalidate()
        player.applicationWillTerminate()
    }

    private func presentWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu actions

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.openableTypes
        panel.message = "Choose an audio or video file"
        panel.prompt = "Play"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.open(url: url)
    }

    /// The open panel filters on declared types; the extension list catches
    /// formats macOS has no UTI for but mpv can still play.
    private static let openableTypes: [UTType] = {
        var types: [UTType] = [.audio, .movie, .video, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff]
        let extras = [
            "org.matroska.mkv", "org.webmproject.webm", "org.xiph.flac", "org.xiph.opus",
            "org.xiph.ogg-audio", "com.monkeysaudio.ape", "com.wavpack.wv", "com.sony.dsf",
            "org.videolan.flv", "org.videolan.ts", "com.microsoft.windows-media-wmv",
            "com.microsoft.windows-media-wma",
        ]
        types.append(contentsOf: extras.compactMap { UTType($0) })
        for ext in ["mkv", "webm", "opus", "ape", "wv", "flv", "ts", "m2ts", "rmvb", "ogv"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    // MARK: - Now Playing

    /// Re-arms `withObservationTracking` after each change, since it only fires
    /// once per registration. `currentTime` is deliberately not observed — it
    /// changes ten times a second and the timer above covers it.
    private func trackPlayerState() {
        withObservationTracking {
            _ = player.isPlaying
            _ = player.duration
            _ = player.mediaInfo
            _ = player.currentURL
            _ = player.rate
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.nowPlaying?.update(from: self.player)
                self.trackPlayerState()
            }
        }
    }
}
