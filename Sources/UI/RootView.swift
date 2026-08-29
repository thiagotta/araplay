import SwiftUI

struct RootView: View {
    @Environment(PlayerController.self) private var player
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    /// Inset between the stage and the window edge. The same on both sides and
    /// the bottom so the stage reads as an evenly bezelled panel; only the top
    /// differs, where it has the title bar to clear.
    private let stageInset: CGFloat = 12

    /// Height of the system title bar. The traffic lights sit 9–23pt from the
    /// window top, so a strip of this height centres the title on them.
    private let titleBarHeight: CGFloat = 32

    @State private var isFullScreen = false

    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 296
    /// Below the lower bound a row's title truncates to uselessness; above the
    /// upper bound the sidebar starts competing with the picture.
    private let sidebarWidthRange: ClosedRange<Double> = 240 ... 460

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                RecentsSidebar()
                    .frame(width: sidebarWidth.clamped(to: sidebarWidthRange))
                    .overlay(alignment: .topTrailing) {
                        SidebarToggle(isVisible: $sidebarVisible)
                            .padding(.top, stageInset)
                            .padding(.trailing, 10)
                    }
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(width: $sidebarWidth, range: sidebarWidthRange)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider().overlay(Theme.hairline)
            }

            ZStack(alignment: .topLeading) {
                StageView()

                if !sidebarVisible {
                    SidebarToggle(isVisible: $sidebarVisible)
                        .padding(10)
                }
            }
            // Full screen is all picture: no title bar to clear and no window
            // edge to sit inside, so the stage goes edge to edge.
            // SwiftUI already insets content below the title bar, so only the
            // margin itself belongs here — adding the bar's height again left a
            // dead band above the stage.
            .padding(.top, isFullScreen ? 0 : stageInset)
            .padding(.horizontal, isFullScreen ? 0 : stageInset)
            .padding(.bottom, isFullScreen ? 0 : stageInset)
        }
        .background(Theme.canvas)
        .overlay(alignment: .top) { titleBarStrip }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .animation(.easeInOut(duration: 0.22), value: sidebarVisible)
        .navigationTitle(player.displayTitle)
        .onReceive(NotificationCenter.default.publisher(for: .araPlayToggleSidebar)) { _ in
            sidebarVisible.toggle()
        }
    }
}

private extension RootView {
    /// Drawn into the strip kept clear above the stage. The window hides the
    /// system title bar, so there is no title otherwise — but that strip is also
    /// the window's drag handle and its double-click-to-fill target, so the
    /// label must not take clicks.
    @ViewBuilder
    var titleBarStrip: some View {
        if !isFullScreen {
            ZStack {
                // Behind the label, so dragging and double-clicking work anywhere
                // in the strip that is not a traffic light.
                TitleBarInteractionArea()
                titleBarLabel
            }
            .frame(maxWidth: .infinity, minHeight: titleBarHeight, maxHeight: titleBarHeight)
            // SwiftUI insets content below the title bar; without this the strip
            // lands under the traffic lights instead of beside them.
            .ignoresSafeArea(edges: .top)
        }
    }

    var titleBarLabel: some View {
        Text(windowTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Keeps a long title clear of the traffic lights, which end at x=69.
            .padding(.horizontal, 92)
            .frame(maxWidth: .infinity)
            // The strip below handles dragging and double-clicks; the label must
            // not intercept them.
            .allowsHitTesting(false)
    }

    var windowTitle: String {
        guard player.currentURL != nil else { return "AraPlay" }
        return "AraPlay — \(player.displayTitle)"
    }
}

extension Notification.Name {
    static let araPlayToggleSidebar = Notification.Name("araPlayToggleSidebar")
}

private struct SidebarToggle: View {
    @Binding var isVisible: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isVisible.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isVisible ? "Hide Recents" : "Show Recents")
    }
}

/// Restores the title-bar behaviour a transparent title bar gives up.
///
/// With `titlebarAppearsTransparent` and a hidden title, `NSTitlebarContainerView`
/// hit-tests to nil everywhere except the traffic lights, so clicks fall through
/// to the SwiftUI content and the window never sees them. Dragging and
/// double-clicking therefore stop working. This puts both back.
private struct TitleBarInteractionArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { TitleBarInteractionView() }
    func updateNSView(_: NSView, context _: Context) {}
}

private final class TitleBarInteractionView: NSView {
    /// So a drag can start on a window that is not yet focused.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// Mirrors System Settings → Desktop & Dock → "Double-click a window's title
    /// bar to". `zoom` toggles between the screen-filling standard frame and the
    /// previous size, which covers both the Fill and Maximize settings.
    private func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

/// Drag handle for the sidebar's trailing edge.
///
/// It sits just inside the sidebar rather than straddling the divider: an
/// overlay hanging outside its parent's bounds is not reliably hit-tested, and
/// a 1pt divider is too thin to grab in any case.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    @State private var widthAtDragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Anchor to the width at the start of the drag, so the
                        // handle tracks the pointer instead of accelerating away
                        // as translations accumulate.
                        let start = widthAtDragStart ?? width
                        if widthAtDragStart == nil { widthAtDragStart = start }
                        width = (start + value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}
