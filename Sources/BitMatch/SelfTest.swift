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
        // Three web views, all playing through the same kind of shared helper.
        let safari = AudioDevice.OutputProcess(bundleID: "com.apple.WebKit.GPU", pid: 10)
        let chatApp = AudioDevice.OutputProcess(bundleID: "com.apple.WebKit.GPU", pid: 11)
        let ownerless = AudioDevice.OutputProcess(bundleID: "com.apple.WebKit.GPU", pid: 12)
        let owners: [pid_t: ProcessOwner.Answer] = [10: .app("com.apple.Safari"), 11: .app("com.example.chat")]
        state.ownerOfProcess = { owners[$0] ?? .unknown }
        // Two more apps: a streaming service BitMatch knows, and a player it has never heard of.
        let bugs = AudioDevice.OutputProcess(bundleID: "kr.co.bugs.macOS", pid: 20)
        let tidal = AudioDevice.OutputProcess(bundleID: "com.tidal.desktop.helper", pid: 21)
        let stranger = AudioDevice.OutputProcess(bundleID: "com.example.player", pid: 22)
        state.runningAppName = { ["kr.co.bugs.macOS": "Bugs", "com.tidal.desktop": "TIDAL",
                                  "com.example.player": "Player"][$0] }
        func stream(_ pid: pid_t, _ codec: String, _ rate: Double) -> StreamFormat {
            StreamFormat(pid: pid, codec: codec, sampleRate: rate)
        }
        let hiRes = TrackFormat(codec: "qlac", rendition: "Lossless", sampleRate: 96000, bitDepth: 24)
        let cd = TrackFormat(codec: "qlac", rendition: "Lossless", sampleRate: 44100, bitDepth: 16)
        let playing = NowPlaying(title: "t", artist: "a", isPlaying: true)
        let paused = NowPlaying(title: "t", artist: "a", isPlaying: false)

        state.handleActivity([daemon])
        expect("an unknown background process is ignored", source: nil, rate: nil)

        state.handleActivity([chatApp])
        state.handleActivity([chatApp])
        expect("a web view inside another app is not a browser", source: nil, rate: nil)

        state.handleActivity([safari, chatApp])
        state.handleActivity([safari, chatApp])
        expect("Safari's web audio counts as a browser", source: "browser", rate: 48000, depth: 24)

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

        state.handleActivity([ownerless])
        state.handleActivity([ownerless])
        expect("web audio with no known owner is assumed to be a browser", source: "browser", rate: 48000, depth: 24)

        state.setRule(.fixed(88200), for: .spotify)
        state.playerChanged("spotify", playing)
        expect("a changed preset is used", source: "spotify", rate: 88200, depth: 24)

        state.matchBitDepth = false
        expect("bit depth matching off keeps the device's depth", source: "spotify", rate: 88200, depth: 0)

        state.autoSwitch = false
        expect("auto-switch off leaves the device alone", source: "spotify", rate: nil)

        // Other players and the stream formats they report.
        state.autoSwitch = true
        state.matchBitDepth = true
        state.playerChanged("spotify", paused)
        state.handleActivity([])
        expect("with everything quiet the last source stays", source: "browser", rate: 48000, depth: 24)

        state.handleActivity([stranger])
        state.handleActivity([stranger])
        expect("an app BitMatch doesn't know never takes over", source: "browser", rate: 48000, depth: 24)

        state.handleActivity([bugs])
        state.handleActivity([bugs])
        expect("a known 44.1 kHz service starts on its preset", source: "kr.co.bugs.macOS", rate: 44100, depth: 24)

        state.received(stream(20, "flac", 96000), live: true)
        expect("the rate the app reports replaces the preset", source: "kr.co.bugs.macOS", rate: 96000, depth: 24)

        state.received(stream(99, "aac ", 22050), live: true)
        expect("a stream from some other process changes nothing", source: "kr.co.bugs.macOS", rate: 96000)

        state.received(stream(20, "flac", 48000), live: false)
        expect("history never overrides a live stream format", source: "kr.co.bugs.macOS", rate: 96000)

        state.handleActivity([])
        expect("a pause keeps the reported rate", source: "kr.co.bugs.macOS", rate: 96000)

        state.received(stream(21, "flac", 192000), live: true)
        state.handleActivity([tidal])
        state.handleActivity([tidal])
        expect("a format reported before playback is used once it starts", source: "com.tidal.desktop", rate: 192000, depth: 24)

        state.received(stream(21, "flac", 44100), live: true)
        expect("the next track's rate is followed", source: "com.tidal.desktop", rate: 44100, depth: 24)

        state.setRule(.fixed(88200), for: state.sources.first { $0.id == "com.tidal.desktop" }!)
        state.received(stream(21, "flac", 96000), live: true)
        expect("a fixed rate ignores what the app reports", source: "com.tidal.desktop", rate: 88200, depth: 24)

        state.handleActivity([stranger])
        state.handleActivity([stranger])
        state.setRule(.auto, for: state.sources.first { $0.id == "com.example.player" }!)
        expect("an unknown app on auto waits for a reported format", source: "com.example.player", rate: nil)

        state.received(stream(22, "lpcm", 176400), live: true)
        expect("and follows it once one arrives", source: "com.example.player", rate: 176400, depth: 24)

        state.setRule(.auto, for: .browser)
        state.handleActivity([safari])
        state.handleActivity([safari])
        expect("a browser on auto falls back to 48 kHz", source: "browser", rate: 48000, depth: 24)

        state.received(stream(10, "aac ", 44100), live: true)
        expect("and follows the rate Safari reports", source: "browser", rate: 44100, depth: 24)

        state.handleActivity([chrome])
        state.handleActivity([chrome])
        expect("a browser that reports nothing gets 48 kHz again", source: "browser", rate: 48000, depth: 24)

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        return failures == 0
    }
}
