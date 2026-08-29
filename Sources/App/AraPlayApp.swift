import SwiftUI

@main
struct AraPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A `Window` rather than a `WindowGroup`: AraPlay is a single-window app
        // so that every file the system hands it reuses the same window.
        Window("AraPlay", id: "main") {
            RootView()
                .environment(appDelegate.player)
                .environment(appDelegate.recents)
                .frame(minWidth: 720, minHeight: 460)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1080, height: 660)
        .commands { menuCommands }

        Settings {
            SettingsView()
                .environment(appDelegate.registrar)
                .environment(appDelegate.recents)
                .preferredColorScheme(.dark)
        }
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { appDelegate.showOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Recents Sidebar") {
                NotificationCenter.default.post(name: .araPlayToggleSidebar, object: nil)
            }
            .keyboardShortcut("\\", modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Search Recents") {
                NotificationCenter.default.post(name: .araPlayFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Playback") {
            let player = appDelegate.player

            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(player.currentURL == nil)

            Divider()

            Button("Previous") { player.skipBackward() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.currentURL == nil)

            Button("Next") { player.playNext() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canGoNext)

            Divider()

            Button("Back 10 Seconds") { player.seek(byOffset: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(player.currentURL == nil)

            Button("Forward 10 Seconds") { player.seek(byOffset: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(player.currentURL == nil)

            Button("Back 60 Seconds") { player.seek(byOffset: -60) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(player.currentURL == nil)

            Button("Forward 60 Seconds") { player.seek(byOffset: 60) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(player.currentURL == nil)

            Divider()

            Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                .keyboardShortcut("m", modifiers: .command)

            Button("Volume Up") { player.volume = min(player.volume + 0.05, 1) }
                .keyboardShortcut(.upArrow, modifiers: [])

            Button("Volume Down") { player.volume = max(player.volume - 0.05, 0) }
                .keyboardShortcut(.downArrow, modifiers: [])

            Divider()

            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(player.currentURL == nil)
        }
    }
}
