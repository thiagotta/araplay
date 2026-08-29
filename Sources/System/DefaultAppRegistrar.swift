import AppKit
import Observation
import UniformTypeIdentifiers

/// Makes AraPlay the system's default handler for media files.
///
/// macOS has no single "default music player" switch the way iOS does — defaults
/// are stored per content type. So "Make AraPlay the default audio player" means
/// claiming every common audio type in one pass, which is what this does.
@MainActor
@Observable
final class DefaultAppRegistrar {
    enum Category: String, CaseIterable, Identifiable {
        case audio
        case video

        var id: String { rawValue }

        var title: String {
            switch self {
            case .audio: "audio"
            case .video: "video"
            }
        }

        /// Concrete types only. LaunchServices stores defaults against the
        /// specific type of a file, so claiming the abstract `public.audio`
        /// alone would not change what a double-clicked MP3 opens with.
        var contentTypes: [UTType] {
            switch self {
            case .audio:
                [
                    .mp3, .wav, .aiff, .mpeg4Audio,
                    UTType("public.aifc-audio"),
                    UTType("public.ac3-audio"),
                    UTType("com.apple.coreaudio-format"),
                    UTType("org.xiph.flac"),
                    UTType("org.xiph.opus"),
                    UTType("org.xiph.vorbis"),
                    UTType("org.xiph.ogg-audio"),
                    UTType("com.microsoft.windows-media-wma"),
                    UTType("com.monkeysaudio.ape"),
                    UTType("com.wavpack.wv"),
                    UTType("com.sony.dsf"),
                ].compactMap(\.self)
            case .video:
                [
                    .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video,
                    UTType("org.matroska.mkv"),
                    UTType("org.webmproject.webm"),
                    UTType("com.microsoft.windows-media-wmv"),
                    UTType("org.videolan.flv"),
                    UTType("org.videolan.ts"),
                    UTType("public.3gpp"),
                ].compactMap(\.self)
            }
        }
    }

    /// Categories where AraPlay currently owns the representative type.
    private(set) var defaultCategories: Set<Category> = []
    private(set) var lastError: String?
    private(set) var isWorking = false

    init() {
        refresh()
    }

    /// A cheap proxy for "are we the default": MP3 and MP4 stand in for their
    /// whole categories rather than round-tripping every type on every refresh.
    private func representativeType(for category: Category) -> UTType {
        switch category {
        case .audio: .mp3
        case .video: .mpeg4Movie
        }
    }

    func refresh() {
        let ourBundle = Bundle.main.bundleURL.standardizedFileURL
        var owned: Set<Category> = []
        for category in Category.allCases {
            let handler = NSWorkspace.shared.urlForApplication(toOpen: representativeType(for: category))
            if handler?.standardizedFileURL == ourBundle {
                owned.insert(category)
            }
        }
        defaultCategories = owned
    }

    func isDefault(for category: Category) -> Bool {
        defaultCategories.contains(category)
    }

    /// Claims every type in the category. Individual failures are expected and
    /// tolerated: a type another app declares exclusively, or one this system
    /// does not know, will throw without invalidating the rest.
    func makeDefault(for category: Category) async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        let appURL = Bundle.main.bundleURL
        var failures: [String] = []

        for type in category.contentTypes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
            } catch {
                failures.append(type.identifier)
            }
        }

        refresh()

        if !isDefault(for: category) {
            lastError = "macOS did not accept AraPlay as the default \(category.title) player. "
                + "This usually means the app needs to be in /Applications and launched from there at least once."
        } else if !failures.isEmpty {
            // Partial success is the normal case; say which types were refused
            // so the user is not surprised later by one file type opening elsewhere.
            lastError = "Set as default for \(category.title), except: \(failures.joined(separator: ", "))."
        }
    }

    /// Registers the bundle with LaunchServices so it shows up in "Open With"
    /// without needing a Finder relaunch. Useful during development, where the
    /// app is run from a build directory the system has not indexed.
    static func registerWithLaunchServices() {
        let bundleURL = Bundle.main.bundleURL
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
