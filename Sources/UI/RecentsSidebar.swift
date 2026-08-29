import AppKit
import SwiftUI

extension Notification.Name {
    static let araPlayFocusSearch = Notification.Name("araPlayFocusSearch")
}

struct RecentsSidebar: View {
    @Environment(RecentsStore.self) private var recents
    @Environment(PlayerController.self) private var player

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var results: [RecentItem] {
        recents.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if recents.items.isEmpty {
                emptyState
            } else if results.isEmpty {
                noMatchesState
            } else {
                list
            }
        }
        // Width is owned by RootView, which lets the user drag it.
        .frame(maxWidth: .infinity)
        .background(Theme.sidebar)
        .task { await recents.refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: .araPlayFocusSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A file may have been deleted while AraPlay was in the background.
            Task { await recents.refreshAvailability() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Recents")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(recents.items.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            searchField
        }
        // SwiftUI already insets content below the title bar, which is what
        // clears the traffic lights. Only the margin belongs here — adding the
        // bar's height again left the header sitting low in dead space.
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSearchFocused ? Theme.accent : Theme.textTertiary)

            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .focused($isSearchFocused)
                .onExitCommand { query = ""; isSearchFocused = false }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSearchFocused ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.12), value: isSearchFocused)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(results) { item in
                    RecentRow(
                        item: item,
                        isMissing: recents.isMissing(item),
                        isCurrent: item.id == player.currentItemID,
                        isPlaying: item.id == player.currentItemID && player.isPlaying
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { player.open(item: item) }
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func contextMenu(for item: RecentItem) -> some View {
        let missing = recents.isMissing(item)

        Button(missing ? "Locate and Play…" : "Play") {
            if missing { locate(item) } else { player.open(item: item) }
        }

        if item.resumeTime != nil {
            Button("Play from Beginning") {
                if let location = item.resolveLocation() {
                    player.open(url: location.url, resume: false)
                }
            }
        }

        Divider()

        Button("Reveal in Finder") {
            guard let location = item.resolveLocation() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([location.url])
        }
        .disabled(missing)

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }

        Divider()

        Button("Remove from Recents") { recents.remove(id: item.id) }

        if !recents.missingIDs.isEmpty {
            Button("Remove All Missing Files") { recents.removeMissing() }
        }
    }

    /// Lets the user point AraPlay at a file that moved somewhere the bookmark
    /// could not follow, rather than making them re-open it from the Finder.
    private func locate(_ item: RecentItem) {
        let panel = NSOpenPanel()
        panel.message = "Locate “\(item.displayName)”"
        panel.prompt = "Play"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = item.url.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        recents.updateLocation(id: item.id, url: url, bookmark: try? url.bookmarkData())
        player.open(url: url)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Nothing played yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Files you open will collect here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Text("No matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("for “\(query)”")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Row

private struct RecentRow: View {
    let item: RecentItem
    let isMissing: Bool
    let isCurrent: Bool
    let isPlaying: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(titleColor)
                    .strikethrough(isMissing, color: Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    if isMissing {
                        Text("Missing")
                            .foregroundStyle(Theme.accent.opacity(0.85))
                    } else {
                        Text(item.subtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // The timestamp keeps its full width and the artist
                        // gives way instead. Without this the time wraps onto a
                        // second line in a narrow sidebar.
                        Text("·")
                            .fixedSize()
                        Text(Format.lastPlayed(item.lastPlayed))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

                if let progress = item.progress {
                    ProgressHairline(fraction: progress)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 0)

            if let duration = item.duration, !isMissing {
                Text(Format.time(duration))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(background)
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2.5)
                    .padding(.vertical, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .help(isMissing ? "\(item.path) — not found" : item.path)
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.16) : Color.white.opacity(0.05))
                .frame(width: 28, height: 28)

            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isMissing ? Theme.textTertiary : (isCurrent ? Theme.accent : Theme.textSecondary))
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
        }
    }

    private var symbolName: String {
        if isMissing { return "questionmark.square.dashed" }
        if isPlaying { return "waveform" }
        return item.isVideo ? "film.fill" : "music.note"
    }

    private var titleColor: Color {
        if isMissing { return Theme.textTertiary }
        return isCurrent ? Theme.textPrimary : Theme.textPrimary.opacity(0.88)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isCurrent ? Theme.rowSelected : (isHovering ? Theme.rowHover : .clear))
    }
}

/// The thin "you left off here" bar under a partially played row.
private struct ProgressHairline: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(Theme.accent.opacity(0.7))
                    .frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: 2)
        // Narrower than the text column so it reads as a gauge rather than a
        // rule running under the row.
        .frame(maxWidth: 132, alignment: .leading)
    }
}
