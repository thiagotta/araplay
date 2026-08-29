import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(DefaultAppRegistrar.self) private var registrar
    @Environment(RecentsStore.self) private var recents

    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section {
                ForEach(DefaultAppRegistrar.Category.allCases) { category in
                    defaultAppRow(for: category)
                }

                if let error = registrar.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Default Player")
            } footer: {
                Text("macOS stores default apps per file type rather than one setting for all media, so each button claims every common type in that group at once.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Recents") {
                LabeledContent("Remembered") {
                    Text("\(recents.items.count) of \(RecentsStore.capacity)")
                        .foregroundStyle(Theme.textSecondary)
                }

                if !recents.missingIDs.isEmpty {
                    LabeledContent("Missing files") {
                        HStack(spacing: 8) {
                            Text("\(recents.missingIDs.count)")
                                .foregroundStyle(Theme.textSecondary)
                            Button("Remove") { recents.removeMissing() }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Clear Recents…", role: .destructive) { isConfirmingClear = true }
                        .disabled(recents.items.isEmpty)
                }
            }

            Section("Playback Engine") {
                LabeledContent("Preferred") {
                    Text("AVFoundation")
                        .foregroundStyle(Theme.textSecondary)
                }
                LabeledContent("Fallback") {
                    Text(EngineSelector.isMPVAvailable ? "mpv (bundled)" : "Not available in this build")
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("AraPlay plays with AVFoundation where it can, for hardware decode and Now Playing support, and falls back to mpv for formats AVFoundation does not open.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { registrar.refresh() }
        .confirmationDialog(
            "Clear all recently played files?",
            isPresented: $isConfirmingClear
        ) {
            Button("Clear \(recents.items.count) Items", role: .destructive) { recents.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the history only. No media files are deleted.")
        }
    }

    private func defaultAppRow(for category: DefaultAppRegistrar.Category) -> some View {
        LabeledContent("Default \(category.title) player") {
            if registrar.isDefault(for: category) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("AraPlay")
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Button("Make Default") {
                    Task { await registrar.makeDefault(for: category) }
                }
                .disabled(registrar.isWorking)
            }
        }
    }
}
