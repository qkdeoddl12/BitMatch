import Foundation

/// What BitMatch does with the output device while a given app is the one playing.
enum SourceRule: Equatable {
    /// Follow the real format of each track. Only Apple Music reports one.
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

    /// A dedicated player outranks a browser tab that happens to be making sound.
    var rank: Int { kind == .browser ? 0 : 1 }

    /// Apple Music logs every track's format, so it is matched exactly.
    static let music = Source(id: "music", kind: .music, name: "Apple Music", defaultRule: .auto)
    /// Spotify's music catalogue, lossless included, is 44.1 kHz.
    static let spotify = Source(id: "spotify", kind: .spotify, name: "Spotify", defaultRule: .fixed(44100))
    /// YouTube and most web video carry 48 kHz audio.
    static let browser = Source(id: "browser", kind: .browser,
                                name: L("Web browsers", "웹 브라우저"), defaultRule: .fixed(48000))

    static let builtIn = [music, spotify, browser]

    private static let browserBundlePrefixes = [
        "com.apple.Safari", "com.apple.WebKit", "com.google.Chrome", "org.chromium.Chromium",
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

    /// "com.example.player.helper.Renderer" -> "com.example.player"
    static func appBundle(forProcessBundle bundle: String) -> String {
        guard let helper = bundle.range(of: ".helper", options: .caseInsensitive) else { return bundle }
        return String(bundle[..<helper.lowerBound])
    }
}
