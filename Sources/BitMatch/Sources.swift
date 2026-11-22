import AppKit

/// What BitMatch does with the output device while a given app is the one playing.
enum SourceRule: Equatable {
    /// Follow the format the app reports for what it is playing. Apple Music reports every track
    /// in full; apps on macOS's media stack report a sample rate; the rest fall back to a preset.
    case auto
    /// Always use this sample rate.
    case fixed(Double)
    /// Leave the device alone.
    case ignore

    var storage: String {
        switch self {
        case .auto: return "auto"
        case .ignore: return "ignore"
        case .fixed(let rate): return String(Int(rate))
        }
    }

    init?(storage: String) {
        switch storage {
        case "auto": self = .auto
        case "ignore": self = .ignore
        default:
            guard let rate = Double(storage), rate > 0 else { return nil }
            self = .fixed(rate)
        }
    }
}

/// An app whose playback BitMatch can follow.
struct Source: Identifiable, Equatable {
    enum Kind { case music, spotify, browser, other }

    /// "music", "spotify", "browser", or the app's bundle identifier for anything else.
    let id: String
    let kind: Kind
    var name: String
    var defaultRule: SourceRule
    /// The rate `.auto` uses until the app reports what it is really playing. Nil means wait.
    var presetRate: Double? = nil

    /// A dedicated player outranks a browser tab that happens to be making sound.
    var rank: Int { kind == .browser ? 0 : 1 }

    /// Spotify plays through its own engine and never says what it is playing.
    var canReportFormat: Bool { kind != .spotify }

    /// Apple Music logs every track's format, so it is matched exactly.
    static let music = Source(id: "music", kind: .music, name: "Apple Music", defaultRule: .auto)
    /// Spotify's music catalogue, lossless included, is 44.1 kHz.
    static let spotify = Source(id: "spotify", kind: .spotify, name: "Spotify", defaultRule: .fixed(44100))
    /// YouTube and most web video carry 48 kHz audio.
    static let browser = Source(id: "browser", kind: .browser,
                                name: L("Web browsers", "웹 브라우저"), defaultRule: .fixed(48000),
                                presetRate: 48000)

    static let builtIn = [music, spotify, browser]

    /// Players BitMatch knows how to treat without being told. Each follows the format the app
    /// reports; `preset` covers the apps, and the moments, that report nothing.
    /// Apps that are not listed here are left alone until the user gives them a rule.
    private static let knownApps: [(bundle: String, name: String, preset: Double?)] = [
        // Services whose catalogue is 44.1 kHz.
        ("kr.co.bugs.macOS", "Bugs", 44100),
        ("com.iloen.macmelon", "Melon", 44100),
        ("kr.co.geniemusic.macpcp", "genie", 44100),
        ("kr.co.musicmates.radio", "FLO", 44100),
        ("com.naver.vibemacelectron", "VIBE", 44100),
        ("com.deezer.deezer-desktop", "Deezer", 44100),
        // Hi-res services: no single rate fits, so act only on what the app reports.
        ("com.tidal.desktop", "TIDAL", nil),
        ("com.qobuz.desktop", "Qobuz", nil),
        ("com.amazon.music", "Amazon Music", nil),
        // Video.
        ("com.apple.TV", "TV", 48000),
        ("com.apple.QuickTimePlayerX", "QuickTime Player", nil),
    ]

    /// The known player an app bundle ID belongs to. Some apps play from a companion process
    /// such as "com.amazon.music-renderer", hence the prefix match.
    static func known(forAppBundle bundle: String) -> Source? {
        guard let app = knownApps.first(where: {
            bundle == $0.bundle || bundle.hasPrefix($0.bundle + ".") || bundle.hasPrefix($0.bundle + "-")
        }) else { return nil }
        return Source(id: app.bundle, kind: .other, name: app.name, defaultRule: .auto, presetRate: app.preset)
    }

    /// The known players installed on this Mac, under the names the Finder shows.
    static func installedKnownApps() -> [Source] {
        knownApps.compactMap { app in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundle),
                  var source = known(forAppBundle: app.bundle)
            else { return nil }
            let shown = FileManager.default.displayName(atPath: url.path)
            source.name = shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown
            return source
        }
    }

    private static let browserBundlePrefixes = [
        "com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium",
        "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "com.naver.Whale", "app.zen-browser.zen", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser",
    ]

    /// Maps the bundle ID of a process that is playing audio to a built-in source, if it is one.
    /// Browsers play through helper processes, hence the prefix match.
    static func builtInID(forProcessBundle bundle: String) -> String? {
        if bundle == "com.apple.Music" { return music.id }
        if bundle.hasPrefix("com.spotify.client") { return spotify.id }
        if browserBundlePrefixes.contains(where: bundle.hasPrefix) { return browser.id }
        return nil
    }

    /// WebKit plays the sound of every web view from a shared helper, so the helper's own bundle ID
    /// does not say whether Safari is behind it or a chat app showing a video.
    static func isSharedWebHelper(_ bundle: String) -> Bool {
        bundle.hasPrefix("com.apple.WebKit")
    }

    /// "com.example.player.helper.Renderer" -> "com.example.player"
    static func appBundle(forProcessBundle bundle: String) -> String {
        guard let helper = bundle.range(of: ".helper", options: .caseInsensitive) else { return bundle }
        return String(bundle[..<helper.lowerBound])
    }
}
