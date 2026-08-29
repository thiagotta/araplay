import AppKit
import SwiftUI

struct TransportBar: View {
    @Environment(PlayerController.self) private var player

    /// Where the thumb sits while the user drags, before the seek is committed.
    @State private var scrubPreview: Double?

    private var displayedTime: Double {
        scrubPreview ?? player.currentTime
    }

    var body: some View {
        VStack(spacing: 10) {
            scrubberRow
            controlsRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    // MARK: - Scrubber

    private var scrubberRow: some View {
        HStack(spacing: 10) {
            Text(Format.time(displayedTime))
                .transportTimeLabel()

            Scrubber(
                current: displayedTime,
                duration: player.duration,
                onBegin: {
                    player.beginScrubbing()
                },
                onChange: { time in
                    scrubPreview = time
                },
                onEnd: { time in
                    scrubPreview = nil
                    player.endScrubbing(at: time)
                }
            )

            Text(Format.remaining(displayedTime, player.duration))
                .transportTimeLabel()
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 14) {
            transportCluster
            VolumeControl()

            Spacer(minLength: 8)

            if let kind = player.engineKind {
                EngineBadge(kind: kind)
            }

            SpeedMenu()

            TransportButton(symbol: "arrow.up.left.and.arrow.down.right", size: 13) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .help("Toggle Full Screen")
        }
    }

    /// A finished file offers to play again rather than showing a play button
    /// that appears to do nothing.
    private var playSymbol: String {
        if player.isAtEnd { return "arrow.clockwise" }
        return player.isPlaying ? "pause.fill" : "play.fill"
    }

    /// SwiftUI centres a symbol's text box — the font's ascent and descent —
    /// rather than its ink, so each glyph lands slightly off inside the circle.
    /// These are measured from the rendered button, not guessed.
    private var playSymbolNudge: CGSize {
        switch playSymbol {
        case "play.fill": CGSize(width: 0.70, height: 0)
        case "arrow.clockwise": CGSize(width: 0.39, height: -0.63)
        default: .zero
        }
    }

    /// Skip, previous, play, next, skip — kept tight so the five read as one
    /// group rather than five unrelated buttons.
    private var transportCluster: some View {
        HStack(spacing: 6) {
            TransportButton(symbol: "gobackward.15", size: 15) {
                player.seek(byOffset: -15)
            }
            .help("Back 15 seconds")

            TransportButton(symbol: "backward.end.fill", size: 13, action: player.skipBackward)
                .help(player.canGoPrevious
                    ? "Start over, or previous file if within \(Int(PlayerController.restartThreshold))s"
                    : "Start over")

            Button(action: player.togglePlayPause) {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 34, height: 34)
                    Image(systemName: playSymbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: playSymbolNudge.width, y: playSymbolNudge.height)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isAtEnd ? "Play Again" : (player.isPlaying ? "Pause" : "Play"))

            TransportButton(symbol: "forward.end.fill", size: 13, action: player.playNext)
                .disabled(!player.canGoNext)
                .opacity(player.canGoNext ? 1 : 0.35)
                .help("Next file")

            TransportButton(symbol: "goforward.30", size: 15) {
                player.seek(byOffset: 30)
            }
            .help("Forward 30 seconds")
        }
    }
}

// MARK: - Scrubber

private struct Scrubber: View {
    let current: Double
    let duration: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return (current / duration).clamped(to: 0 ... 1)
    }

    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height: CGFloat = isActive ? 5 : 3
            let filled = width * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: height)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, filled), height: height)

                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: max(0, filled - 5.5))
                    .opacity(isActive ? 1 : 0)
            }
            .frame(height: 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isActive)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            onBegin()
                        }
                        onChange(time(at: value.location.x, width: width))
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        isDragging = false
                        onEnd(time(at: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 16)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return ((x / width).clamped(to: 0 ... 1)) * duration
    }
}

// MARK: - Pieces

private struct TransportButton: View {
    let symbol: String
    var size: CGFloat = 14
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct VolumeControl: View {
    @Environment(PlayerController.self) private var player
    @State private var isHovering = false

    private var symbol: String {
        if player.isMuted || player.volume <= 0.001 { return "speaker.slash.fill" }
        if player.volume < 0.33 { return "speaker.wave.1.fill" }
        if player.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        @Bindable var player = player

        HStack(spacing: 6) {
            Button(action: player.toggleMute) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(player.isMuted ? "Unmute" : "Mute")

            // The slider is only worth its width while the pointer is nearby.
            if isHovering {
                Slider(value: $player.volume, in: 0 ... 1)
                    .controlSize(.mini)
                    .tint(Theme.accent)
                    .frame(width: 68)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

private struct SpeedMenu: View {
    @Environment(PlayerController.self) private var player

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { speed in
                Button {
                    player.rate = speed
                } label: {
                    HStack {
                        Text(label(for: speed))
                        if abs(player.rate - speed) < 0.01 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(label(for: player.rate))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(player.rate == 1.0 ? Theme.textSecondary : Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    private func label(for speed: Float) -> String {
        speed == rounded(speed) ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    private func rounded(_ value: Float) -> Float { value.rounded() }
}

/// Quietly shows which backend is in use. Mostly a development aid, but it also
/// explains why AirPlay is available for some files and not others.
private struct EngineBadge: View {
    let kind: EngineKind

    var body: some View {
        Text(kind == .mpv ? "mpv" : "AV")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .help("Playing with \(kind.displayName)")
    }
}

private extension View {
    func transportTimeLabel() -> some View {
        font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 52, alignment: .center)
    }
}
