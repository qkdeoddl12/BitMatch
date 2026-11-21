import AppKit
import ServiceManagement

struct NowPlaying: Equatable {
    var title: String?
    var artist: String?
    var isPlaying: Bool
}

@MainActor
final class AppState: ObservableObject {
    enum MatchStatus { case idle, switching, matched, mismatch }

    enum MenuBarStyle: String, CaseIterable {
        case iconAndRate, rateOnly, iconOnly
    }

    // What is playing
    @Published private(set) var sources: [Source] = Source.builtIn
    @Published private(set) var rules: [String: SourceRule] = [:]
    @Published private(set) var activeSourceID: String?
    @Published private(set) var nowPlaying: [String: NowPlaying] = [:]
    /// The format of Apple Music's current track.
    @Published private(set) var trackFormat: TrackFormat?
    /// The source whose rule picker is open in the popover.
    @Published var expandedSourceID: String?

    // Output device
    @Published private(set) var deviceName: String?
    @Published private(set) var deviceRate: Double?
    @Published private(set) var deviceBits: Int?
    @Published private(set) var deviceRates: [Double] = []
    @Published private(set) var isSwitching = false

    @Published var problem: String?
    @Published private(set) var launchAtLogin = false

    @Published var autoSwitch: Bool {
        didSet {
            if live { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch") }
            applyActive()
        }
    }
    @Published var matchBitDepth: Bool {
        didSet {
            if live { UserDefaults.standard.set(matchBitDepth, forKey: "matchBitDepth") }
            applyActive()
        }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet {
            if live { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
        }
    }

    /// The format most recently asked of the output device, or nil if the device is being left alone.
    private(set) var lastRequest: (rate: Double, depth: Int)?

    /// False for previews and self-tests, which must not touch hardware or saved settings.
    private let live: Bool

    /// Apps other than Apple Music don't report a bit depth. 24-bit holds Spotify's lossless tier
    /// exactly and leaves room to spare for anything lossy.
    static let presetBitDepth = 24

    private let devices = DeviceController()
    private var watcher: LogWatcher?

    // Playback tracking. `streak` counts consecutive activity checks in which a source was playing.
    private var streak: [String: Int] = [:]
    private var playing: [String: Bool] = [:]           // what Music and Spotify last announced
    private var graceUntil: [String: Date] = [:]        // trust an announcement until the next check confirms it
    private var audibleSince: [String: Date] = [:]
    private var notApps: Set<String> = []               // bundle IDs already ruled out as sources

    private var lastLiveFormat = Date.distantPast
    private var lastResync = Date.distantPast

    /// `live: false` builds an inert instance for previews and self-tests.
    init(live: Bool = true) {
        self.live = live
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["autoSwitch": true, "matchBitDepth": true])
        autoSwitch = defaults.bool(forKey: "autoSwitch")
        matchBitDepth = defaults.bool(forKey: "matchBitDepth")
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .iconAndRate
        guard live else { return }

        let savedRules = defaults.dictionary(forKey: "sourceRules") as? [String: String] ?? [:]
        let savedNames = defaults.dictionary(forKey: "sourceNames") as? [String: String] ?? [:]
        rules = savedRules.compactMapValues(SourceRule.init(storage:))
        // Apps the user gave a rule to stay listed even when they are not running.
        let known = Set(Source.builtIn.map(\.id))
        sources += rules
            .filter { !known.contains($0.key) && $0.value != .ignore }
            .map { Source(id: $0.key, kind: .other, name: savedNames[$0.key] ?? $0.key, defaultRule: .ignore) }
            .sorted { $0.name < $1.name }
        start()
    }

    private func start() {
        launchAtLogin = SMAppService.mainApp.status == .enabled

        devices.onSnapshot = { [weak self] snapshot, settled in
            Task { @MainActor in self?.show(snapshot, settled: settled) }
        }
        devices.onDefaultDeviceChange = { [weak self] in
            Task { @MainActor in self?.applyActive() }
        }
        devices.onActivity = { [weak self] processes in
            Task { @MainActor in self?.handleActivity(processes) }
        }
        devices.start()

        let watcher = LogWatcher(
            onFormat: { [weak self] format, live in
                Task { @MainActor in self?.received(format, live: live) }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.problem = message }
            }
        )
        watcher.start()
        self.watcher = watcher

        // Both players broadcast every track and play-state change. No permission needed.
        observePlayer(Source.music.id, notification: "com.apple.Music.playerInfo")
        observePlayer(Source.spotify.id, notification: "com.spotify.client.PlaybackStateChanged")

        // Sleep can leave the log stream stuck and the device back at its old rate.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            appLog.notice("woke from sleep; restarting the log stream")
            watcher.restart()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.applyActive()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in watcher.stop() }
    }

    private func observePlayer(_ id: String, notification: String) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(notification), object: nil, queue: .main
        ) { [weak self] note in
            let info = NowPlaying(
                title: note.userInfo?["Name"] as? String,
                artist: note.userInfo?["Artist"] as? String,
                isPlaying: note.userInfo?["Player State"] as? String == "Playing"
            )
            Task { @MainActor in self?.playerChanged(id, info) }
        }
    }

    // MARK: Inputs

    func playerChanged(_ id: String, _ info: NowPlaying) {
        nowPlaying[id] = info
        playing[id] = info.isPlaying
        if info.isPlaying {
            graceUntil[id] = Date().addingTimeInterval(5)
            if live, id == Source.music.id { expectFormatSoon() }
        }
        reevaluate()
        if live { devices.pollActivityNow() }
    }

    func received(_ format: TrackFormat, live: Bool) {
        // History is only a fallback for the track that was already playing at launch.
        if !live, trackFormat != nil { return }
        if live {
            // A fresh format line means Music started rendering this instant.
            lastLiveFormat = Date()
            playing[Source.music.id] = true
            graceUntil[Source.music.id] = Date().addingTimeInterval(5)
        }
        // Music often logs the same format twice in a row; only note real changes.
        if format != trackFormat {
            appLog.notice("""
                track format (\(live ? "live" : "history", privacy: .public)): \
                \(format.codec, privacy: .public) \(Int(format.sampleRate), privacy: .public) Hz \
                \(format.bitDepth, privacy: .public)-bit
                """)
        }
        problem = nil
        trackFormat = format
        if !reevaluate(), activeSourceID == Source.music.id { applyActive() }
    }

    /// Music says something is playing, so a format line should have just arrived or be about to.
    /// If none shows up, ask the watcher to check whether its log stream has gone quiet.
    private func expectFormatSoon() {
        let announced = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            let sawFormat = self.lastLiveFormat > announced.addingTimeInterval(-4)
            guard !sawFormat, Date().timeIntervalSince(self.lastResync) > 15 else { return }
            self.lastResync = Date()
            self.watcher?.resync()
        }
    }

    func handleActivity(_ processes: [AudioDevice.OutputProcess]) {
        var playingNow = Set<String>()
        var found = sources
        for process in processes {
            if let id = Source.builtInID(forProcessBundle: process.bundleID) {
                playingNow.insert(id)
                continue
            }
            let bundle = Source.appBundle(forProcessBundle: process.bundleID)
            if found.contains(where: { $0.id == bundle }) {
                playingNow.insert(bundle)
            } else if !notApps.contains(bundle) {
                // Only real apps count: no daemons, no agents, and not BitMatch itself.
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
                if let app, app.activationPolicy == .regular, bundle != Bundle.main.bundleIdentifier {
                    found.append(Source(id: bundle, kind: .other, name: app.localizedName ?? bundle, defaultRule: .ignore))
                    playingNow.insert(bundle)
                } else {
                    notApps.insert(bundle)
                }
            }
        }
        // Forget apps that went quiet and were never given a rule.
        found.removeAll { source in
            source.kind == .other && !playingNow.contains(source.id)
                && rule(for: source) == .ignore && expandedSourceID != source.id
        }
        if found != sources { sources = found }
        for source in sources {
            streak[source.id] = playingNow.contains(source.id) ? (streak[source.id] ?? 0) + 1 : 0
        }
        reevaluate()
    }

    private func show(_ snapshot: AudioDevice.Snapshot?, settled: Bool) {
        deviceName = snapshot?.name
        deviceRate = snapshot?.rate
        deviceBits = snapshot?.bits
        deviceRates = snapshot?.rates ?? []
        if settled { isSwitching = false }
    }

    // MARK: Choosing the source

    private func isAudible(_ source: Source, at now: Date) -> Bool {
        let checks = streak[source.id] ?? 0
        switch source.kind {
        case .music, .spotify:
            // These announce play and pause themselves, so they can be trusted on the first sighting.
            if playing[source.id] == false { return false }
            return checks >= 1 || (graceUntil[source.id] ?? .distantPast) > now
        case .browser, .other:
            // Everything else has to keep playing for two checks, which filters out blips.
            return checks >= 2
        }
    }

    /// Picks the source to follow and applies its rule if the choice changed. Returns true if it did.
    @discardableResult
    private func reevaluate() -> Bool {
        let now = Date()
        for source in sources {
            if rule(for: source) != .ignore, isAudible(source, at: now) {
                if audibleSince[source.id] == nil { audibleSince[source.id] = now }
            } else {
                audibleSince[source.id] = nil
            }
        }
        // Highest rank wins; within a rank, whichever started most recently.
        let best = sources
            .compactMap { source in audibleSince[source.id].map { (source: source, since: $0) } }
            .max { ($0.source.rank, $0.since) < ($1.source.rank, $1.since) }?
            .source

        // When nothing is audible, stay on the last source instead of guessing.
        var next = best?.id ?? activeSourceID
        if let id = next, sources.first(where: { $0.id == id }).map({ rule(for: $0) == .ignore }) ?? true {
            next = nil
        }
        guard next != activeSourceID else { return false }
        activeSourceID = next
        appLog.notice("now following: \(next ?? "nothing", privacy: .public)")
        applyActive()
        return true
    }

    // MARK: Derived state

    var activeSource: Source? {
        sources.first { $0.id == activeSourceID }
    }

    func rule(for source: Source) -> SourceRule {
        rules[source.id] ?? source.defaultRule
    }

    /// The sample rate the active source calls for.
    var sourceRate: Double? {
        guard let source = activeSource else { return nil }
        switch rule(for: source) {
        case .auto: return trackFormat?.sampleRate
        case .fixed(let rate): return rate
        case .ignore: return nil
        }
    }

    /// The Apple Music track format, when Apple Music is the source being followed.
    private var followedTrack: TrackFormat? {
        guard let source = activeSource, rule(for: source) == .auto else { return nil }
        return trackFormat
    }

    var sourceLabel: String {
        activeSource?.name ?? L("Source", "소스")
    }

    var sourceDetail: String {
        guard sourceRate != nil else { return "—" }
        guard let track = followedTrack else {
            let preset = L("Preset", "지정 값")
            return matchBitDepth ? "\(Self.presetBitDepth)-bit · \(preset)" : preset
        }
        return track.isLossless ? "\(track.bitDepth)-bit · \(track.codecName)" : track.codecName
    }

    var sourceCaption: String {
        guard sourceRate != nil else { return L("Waiting for playback", "재생 대기 중") }
        return followedTrack?.qualityLabel ?? L("Set per app below", "아래에서 앱별 설정")
    }

    var activeNowPlaying: NowPlaying? {
        guard let id = activeSourceID, let info = nowPlaying[id], info.title != nil else { return nil }
        return info
    }

    var status: MatchStatus {
        guard let wanted = sourceRate, let rate = deviceRate else { return .idle }
        if isSwitching { return .switching }
        if rate != wanted { return .mismatch }
        if let track = followedTrack, track.isLossless, let bits = deviceBits, bits < track.bitDepth {
            return .mismatch
        }
        return .matched
    }

    var statusLabel: String {
        switch status {
        case .idle: return L("Idle", "대기 중")
        case .switching: return L("Switching", "전환 중")
        case .matched: return L("Matched", "일치")
        case .mismatch: return L("Mismatch", "불일치")
        }
    }

    /// Explains a mismatch that will not resolve by itself.
    var mismatchNote: String? {
        guard status == .mismatch, let wanted = sourceRate, let rate = deviceRate else { return nil }
        if !autoSwitch {
            return L("Auto-switch is off, so macOS is converting the audio.",
                     "자동 전환이 꺼져 있어 macOS가 오디오를 변환하고 있습니다.")
        }
        let device = deviceName ?? L("This device", "이 장치")
        if rate != wanted {
            if deviceRates.contains(wanted) {
                return L("Couldn't switch \(device). Another app may have exclusive control of it.",
                         "\(device)을(를) 전환하지 못했습니다. 다른 앱이 장치를 독점하고 있을 수 있습니다.")
            }
            return L("\(device) doesn't support \(formatRate(wanted)). Using the closest rate instead.",
                     "\(device)은(는) \(formatRate(wanted))를 지원하지 않아 가장 가까운 값을 사용합니다.")
        }
        if !matchBitDepth {
            return L("The device is set below this track's bit depth. Turn on “Match bit depth too” to fix it.",
                     "장치의 비트뎁스가 곡보다 낮습니다. “비트뎁스도 맞추기”를 켜면 해결됩니다.")
        }
        let bits = followedTrack?.bitDepth ?? 0
        return L("\(device) can't output \(bits)-bit at this rate.",
                 "\(device)은(는) 이 샘플레이트에서 \(bits)-bit 출력을 지원하지 않습니다.")
    }

    var menuBarRate: String {
        deviceRate.map(formatRate) ?? "—"
    }

    // MARK: Actions

    /// The format the active source calls for, or nil if the device should be left alone.
    private func wantedFormat() -> (rate: Double, depth: Int)? {
        guard autoSwitch, let source = activeSource else { return nil }
        switch rule(for: source) {
        case .auto:
            guard let track = trackFormat else { return nil }
            return (track.sampleRate, matchBitDepth ? track.bitDepth : 0)
        case .fixed(let preset):
            return (preset, matchBitDepth ? Self.presetBitDepth : 0)
        case .ignore:
            return nil
        }
    }

    /// Puts the output device into the format the active source calls for.
    func applyActive() {
        lastRequest = wantedFormat()
        guard live else { return }
        guard let request = lastRequest else {
            devices.refresh()
            return
        }
        isSwitching = true
        devices.match(sampleRate: request.rate, bitDepth: request.depth)
    }

    func setRule(_ rule: SourceRule, for source: Source) {
        rules[source.id] = rule
        if live {
            let defaults = UserDefaults.standard
            defaults.set(rules.mapValues(\.storage), forKey: "sourceRules")
            var names = defaults.dictionary(forKey: "sourceNames") as? [String: String] ?? [:]
            names[source.id] = source.name
            defaults.set(names, forKey: "sourceNames")
        }
        if !reevaluate(), source.id == activeSourceID { applyActive() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = L("Couldn't change the login item: \(error.localizedDescription)",
                        "로그인 항목을 바꾸지 못했습니다: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

extension AppState {
    enum SampleScene { case appleMusic, spotify }

    /// Fixed sample data for screenshots.
    static func sample(_ scene: SampleScene) -> AppState {
        let state = AppState(live: false)
        state.deviceName = "USB DAC"
        state.deviceRates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        switch scene {
        case .appleMusic:
            state.activeSourceID = Source.music.id
            state.nowPlaying[Source.music.id] = NowPlaying(title: "Midnight Signal", artist: "The Samplers", isPlaying: true)
            state.trackFormat = TrackFormat(codec: "qlac", rendition: "Lossless", sampleRate: 96000, bitDepth: 24)
            state.deviceRate = 96000
            state.deviceBits = 24
        case .spotify:
            state.activeSourceID = Source.spotify.id
            state.nowPlaying[Source.spotify.id] = NowPlaying(title: "Paper Lanterns", artist: "The Samplers", isPlaying: true)
            state.expandedSourceID = Source.spotify.id
            state.deviceRate = 44100
            state.deviceBits = 24
        }
        return state
    }
}
