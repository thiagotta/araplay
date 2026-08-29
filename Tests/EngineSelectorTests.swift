import Foundation
import Testing
@testable import AraPlay

struct EngineSelectorTests {
    @Test func mpvIsCompiledIntoTheTestBuild() {
        #expect(EngineSelector.isMPVAvailable)
    }

    // MARK: - Routing

    @Test func knownUnsupportedContainersSkipStraightToMPV() async {
        // These never reach the AVFoundation probe: it either rejects them or,
        // worse, half-opens them (MKV with undecodable audio being the classic).
        for name in ["movie.mkv", "movie.webm", "song.opus", "song.ogg", "movie.avi", "song.ape"] {
            let kind = await EngineSelector.decide(for: URL(fileURLWithPath: "/tmp/\(name)"))
            #expect(kind == .mpv, "\(name) should route to mpv")
        }
    }

    @Test func unreadableFileFallsBackToMPV() async {
        // The probe cannot prove AVFoundation can play it, and mpv is the engine
        // that can cope with almost anything — so doubt resolves to mpv.
        let ghost = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp4")
        let kind = await EngineSelector.decide(for: ghost)
        #expect(kind == .mpv)
    }

    // MARK: - Video guess for the stage layout

    @Test func videoContainersLookLikeVideo() {
        for ext in ["mkv", "mp4", "mov", "webm", "avi", "ts"] {
            #expect(EngineSelector.looksLikeVideo(URL(fileURLWithPath: "/tmp/file.\(ext)")), "\(ext)")
        }
    }

    @Test func audioFilesDoNotLookLikeVideo() {
        for ext in ["mp3", "flac", "opus", "wav", "m4a"] {
            #expect(!EngineSelector.looksLikeVideo(URL(fileURLWithPath: "/tmp/file.\(ext)")), "\(ext)")
        }
    }
}
