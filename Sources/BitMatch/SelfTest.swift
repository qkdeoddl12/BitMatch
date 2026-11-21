import Foundation

/// `BitMatch --selftest` feeds made-up playback events through the source-selection logic and
/// checks what it would ask of the output device. No real device or saved setting is touched.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        let state = AppState(live: false)
        state.autoSwitch = true
        state.matchBitDepth = true

        func expect(_ step: String, source: String?, rate: Double?, depth: Int? = nil) {
            let request = state.lastRequest
            let ok = state.activeSourceID == source && request?.rate == rate
                && (depth == nil || request?.depth == depth)
            if !ok { failures += 1 }
            let got = "\(state.activeSourceID ?? "nothing") @ \(request.map { "\(Int($0.rate))/\($0.depth)" } ?? "leave alone")"
            print("\(ok ? "PASS" : "FAIL")  \(step)  ->  \(got)")
        }

        let spotify = AudioDevice.OutputProcess(bundleID: "com.spotify.client", pid: 1)
        let chrome = AudioDevice.OutputProcess(bundleID: "com.google.Chrome.helper", pid: 2)
        let music = AudioDevice.OutputProcess(bundleID: "com.apple.Music", pid: 3)
        let daemon = AudioDevice.OutputProcess(bundleID: "com.example.not-an-app", pid: 4)
        let hiRes = TrackFormat(codec: "qlac", rendition: "Lossless", sampleRate: 96000, bitDepth: 24)
        let cd = TrackFormat(codec: "qlac", rendition: "Lossless", sampleRate: 44100, bitDepth: 16)
        let playing = NowPlaying(title: "t", artist: "a", isPlaying: true)
        let paused = NowPlaying(title: "t", artist: "a", isPlaying: false)

        state.handleActivity([daemon])
        expect("an unknown background process is ignored", source: nil, rate: nil)

        state.handleActivity([spotify, daemon])
        expect("Spotify playing uses its preset", source: "spotify", rate: 44100, depth: 24)

        state.received(hiRes, live: true)
        expect("an Apple Music track starting takes over", source: "music", rate: 96000, depth: 24)

        state.handleActivity([spotify, music])
        expect("stays on Apple Music while both play", source: "music", rate: 96000, depth: 24)

        state.playerChanged("music", paused)
        expect("pausing Apple Music hands back to Spotify", source: "spotify", rate: 44100, depth: 24)

        state.handleActivity([spotify, chrome])
        expect("a browser blip changes nothing", source: "spotify", rate: 44100)
        state.handleActivity([spotify, chrome])
        expect("a music player outranks a browser", source: "spotify", rate: 44100)

        state.playerChanged("spotify", paused)
        expect("with Spotify paused the browser is followed", source: "browser", rate: 48000, depth: 24)

        state.handleActivity([])
        expect("silence keeps the last source", source: "browser", rate: 48000)

        state.playerChanged("music", playing)
        expect("resuming Apple Music returns to its track", source: "music", rate: 96000, depth: 24)

        state.received(cd, live: true)
        expect("the next track's format is applied", source: "music", rate: 44100, depth: 16)

        state.received(hiRes, live: false)
        expect("history never overrides a live format", source: "music", rate: 44100, depth: 16)

        state.setRule(.ignore, for: .music)
        expect("turning Apple Music off stops following it", source: nil, rate: nil)

        state.setRule(.fixed(88200), for: .spotify)
        state.playerChanged("spotify", playing)
        expect("a changed preset is used", source: "spotify", rate: 88200, depth: 24)

        state.matchBitDepth = false
        expect("bit depth matching off keeps the device's depth", source: "spotify", rate: 88200, depth: 0)

        state.autoSwitch = false
        expect("auto-switch off leaves the device alone", source: "spotify", rate: nil)

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        return failures == 0
    }
}
