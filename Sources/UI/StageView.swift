import AppKit
import Combine
import SwiftUI

/// The engine's view is display-only. Without this, AppKit hit-testing consumes
/// clicks over the picture and the SwiftUI tap gestures on the stage never fire.
private final class PassthroughView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// Sizes the engine's view directly rather than relying on Auto Layout.
    /// Constraints inside an NSViewRepresentable are not reliably re-solved when
    /// SwiftUI resizes the container, which left the video stuck at its original
    /// size when the window was resized.
    override func layout() {
        super.layout()
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}

/// Hosts whichever `NSView` the active engine renders into.
///
/// The engine's view is replaced wholesale when the backend changes, so this
/// watches `renderViewGeneration` rather than trying to diff view identity.
private struct EngineSurface: NSViewRepresentable {
    let player: PlayerController
    let generation: Int

    func makeNSView(context _: Context) -> NSView {
        let container = PassthroughView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let desired = player.renderView

        if let existing = container.subviews.first, existing === desired { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        guard let desired else { return }
        desired.translatesAutoresizingMaskIntoConstraints = true
        desired.autoresizingMask = [.width, .height]
        desired.frame = container.bounds
        container.addSubview(desired)
    }
}

struct StageView: View {
    @Environment(PlayerController.self) private var player
    @Environment(RecentsStore.self) private var recents

    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var isPointerOverControls = false
    @State private var isDropTargeted = false
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            Theme.stage

            if player.currentURL == nil {
                EmptyStage()
            } else if player.hasVideo {
                EngineSurface(player: player, generation: player.renderViewGeneration)
                    .id(player.renderViewGeneration)
            } else {
                AudioStage(info: player.mediaInfo, title: player.displayTitle, isPlaying: player.isPlaying)
                // Audio still needs the engine view in the tree for mpv, which
                // renders into its layer even when there is nothing to show.
                .background(
                    EngineSurface(player: player, generation: player.renderViewGeneration)
                        .id(player.renderViewGeneration)
                        .opacity(0.001)
                )
            }

            if let message = player.errorMessage {
                ErrorBanner(message: message)
            }

            if player.currentURL != nil {
                TransportBar()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 8)
                    .animation(.easeInOut(duration: 0.28), value: controlsVisible)
                    // Hover and hit testing must be attached before the
                    // full-height frame below. Applied after it, they cover the
                    // whole stage: every pointer position counts as "over the
                    // controls", which cancels the idle hide and swallows clicks
                    // meant for the picture.
                    .onHover { hovering in
                        isPointerOverControls = hovering
                        if hovering { showControls(thenHide: false) }
                        else { scheduleHide() }
                    }
                    .allowsHitTesting(controlsVisible)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        // No rounded corners, border or shadow in full screen: the stage is the
        // whole display, so there is nothing for it to be a panel against.
        .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : Theme.stageCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isFullScreen ? 0 : Theme.stageCornerRadius, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Color.white.opacity(isFullScreen ? 0 : 0.06),
                    lineWidth: isDropTargeted ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isFullScreen ? 0 : 0.55), radius: 22, y: 10)
        .contentShape(Rectangle())
        // Higher count first, so a double click is not consumed as two singles.
        .onTapGesture(count: 2) {
            guard player.hasVideo else { return }
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .onTapGesture(count: 1) {
            guard player.hasVideo, isFullScreen else { return }
            toggleControlsByClick()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
            showControls(thenHide: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            showControls(thenHide: true)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                // Any movement brings them back, and restarts the idle countdown.
                showControls(thenHide: true)
            case .ended:
                // Pointer left the stage entirely — same as going idle, but there
                // is nothing to wait for, so hide at once.
                hideControlsNow()
            }
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying { scheduleHide() } else { showControls(thenHide: false) }
        }
        .onChange(of: player.currentURL) { _, _ in showControls(thenHide: true) }
        // A file can turn out to have video after the initial guess said it did
        // not, at which point auto-hide should start applying.
        .onChange(of: player.hasVideo) { _, _ in showControls(thenHide: true) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            player.open(url: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: - Control auto-hide

    /// Full-screen click toggle. Also cancels any pending auto-hide, so the
    /// controls do not fade out a moment after being deliberately shown.
    private func toggleControlsByClick() {
        hideWorkItem?.cancel()
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    /// Used when the pointer leaves the stage, where waiting out the idle timer
    /// would leave the controls sitting over a picture nobody is pointing at.
    private func hideControlsNow() {
        hideWorkItem?.cancel()
        guard player.hasVideo, player.isPlaying, !isPointerOverControls else { return }
        controlsVisible = false
    }

    private func showControls(thenHide: Bool) {
        hideWorkItem?.cancel()
        if !controlsVisible { controlsVisible = true }
        if thenHide { scheduleHide() }
    }

    /// Controls stay put while paused, while the pointer is on them, and for
    /// audio, where there is no picture for them to be in the way of.
    private func scheduleHide() {
        hideWorkItem?.cancel()
        guard player.hasVideo, player.isPlaying, !isPointerOverControls else { return }

        let work = DispatchWorkItem {
            guard player.hasVideo, player.isPlaying, !isPointerOverControls else { return }
            controlsVisible = false
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

// MARK: - Audio presentation

private struct AudioStage: View {
    let info: MediaInfo
    let title: String
    let isPlaying: Bool

    var body: some View {
        VStack(spacing: 20) {
            artwork
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 28, y: 14)
                .scaleEffect(isPlaying ? 1.0 : 0.97)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isPlaying)

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let artist = info.artist ?? info.albumArtist {
                    Text(artist)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if let album = info.album {
                    Text(album)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                if !details.isEmpty {
                    Text(details.joined(separator: "  ·  "))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.top, 3)
                }

                if let composer = info.composer {
                    Text("Written by \(composer)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary.opacity(0.85))
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .padding(.bottom, 78)
    }

    /// The smaller facts, collapsed onto one line and omitted individually when
    /// the file does not carry them.
    private var details: [String] {
        var parts: [String] = []
        if let year = info.year { parts.append(String(year)) }
        if let genre = info.genre { parts.append(genre) }
        if let track = info.trackNumber {
            parts.append(info.trackTotal.map { "Track \(track) of \($0)" } ?? "Track \(track)")
        }
        return parts
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = info.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // A file with no embedded art falls back to AraPlay's own mark
            // rather than a grey box.
            Image("FallbackArtwork")
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

// MARK: - Empty stage

private struct EmptyStage: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)

            VStack(spacing: 5) {
                Text("Nothing playing")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Drop a file here, or press ⌘O")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        )
        .padding(20)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
    }
}
