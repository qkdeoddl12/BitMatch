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
    /// What the followed app's own media engine last reported, when its rule is "auto".
    @Published private(set) var activeStream: StreamFormat?
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
    private var helperOwners: [pid_t: ProcessOwner.Answer] = [:]   // shared web helpers playing right now
    /// The newest stream format each process reported, numbered in order of arrival.
    private var streams: [pid_t: (format: StreamFormat, order: Int)] = [:]
    private var streamsSeen = 0
    /// The processes each source was last heard playing from.
    private var sourcePIDs: [String: Set<pid_t>] = [:]

    /// Who a shared web helper is playing for. Replaced by the self-test.
    var ownerOfProcess: (pid_t) -> ProcessOwner.Answer = ProcessOwner.of
    /// The display name of a running, regular app, or nil if the bundle ID is not one.
    /// Replaced by the self-test.
    var runningAppName: (String) -> String? = { bundle in
        guard bundle != Bundle.main.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
              app.activationPolicy == .regular
        else { return nil }
        return app.localizedName ?? bundle
    }

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
        // Known players that are installed are listed from the start, and so are the apps the
        // user gave a rule to, even when they are not running.
        var extra = Source.installedKnownApps()
        let listed = Set((Source.builtIn + extra).map(\.id))
        extra += rules
            .filter { !listed.contains($0.key) && $0.value != .ignore }
            .map { id, _ in
                var source = Source.known(forAppBundle: id)
                    ?? Source(id: id, kind: .other, name: id, defaultRule: .ignore)
                source.name = savedNames[id] ?? source.name
                return source
            }
        sources += extra.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appLog.notice("listed players: \(self.sources.map(\.id).joined(separator: ", "), privacy: .public)")
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
            onStream: { [weak self] stream, live in
                Task { @MainActor in self?.received(stream, live: live) }
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

    /// An app's media engine announced the stream it is about to play.
    func received(_ stream: StreamFormat, live: Bool) {
        // History only fills in for processes that have not reported since launch.
        if !live, streams[stream.pid] != nil { return }
        streamsSeen += 1
        streams[stream.pid] = (stream, streamsSeen)
        if streams.count > 64 {
            // Keep the newer half. Processes that matter report again with their next stream.
            let cutoff = streams.values.map(\.order).sorted()[streams.count / 2]
            streams = streams.filter { $0.value.order >= cutoff }
        }
        guard let source = activeSource, sourcePIDs[source.id]?.contains(stream.pid) == true else {
            // Not the app being followed, at least not yet. Kept in case it starts playing.
            appLog.info("""
                stream format from pid \(stream.pid, privacy: .public): \
                \(stream.codec, privacy: .public) \(Int(stream.sampleRate), privacy: .public) Hz
                """)
            return
        }
        appLog.notice("""
            stream format (\(live ? "live" : "history", privacy: .public)) from \(source.id, privacy: .public): \
            \(stream.codec, privacy: .public) \(Int(stream.sampleRate), privacy: .public) Hz
            """)
        refreshRequest()
    }

    /// The stream format a source's own processes last reported.
    private func stream(for source: Source) -> StreamFormat? {
        guard source.kind != .music, source.canReportFormat else { return nil }
        return (sourcePIDs[source.id] ?? [])
            .compactMap { streams[$0] }
            .max { $0.order < $1.order }?
            .format
    }

    /// Applies again if the active source now calls for something other than what was last asked.
    private func refreshRequest() {
        let wanted = wantedFormat()
        if wanted?.rate != lastRequest?.rate || wanted?.depth != lastRequest?.depth {
            applyActive()
        } else {
            noteActiveStream()
        }
    }

    private func noteActiveStream() {
        let current = activeSource.flatMap { rule(for: $0) == .auto ? stream(for: $0) : nil }
        if current != activeStream { activeStream = current }
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
        var pidsNow: [String: Set<pid_t>] = [:]
        func heard(_ id: String, from pid: pid_t) {
            playingNow.insert(id)
            pidsNow[id, default: []].insert(pid)
        }
        var found = sources
        let helperPIDs = Set(processes.filter { Source.isSharedWebHelper($0.bundleID) }.map(\.pid))
        helperOwners = helperOwners.filter { helperPIDs.contains($0.key) }
        for process in processes {
            var processBundle = process.bundleID
            if Source.isSharedWebHelper(processBundle) {
                // Safari's sound and a video inside a chat app come from the same kind of helper,
                // so go by the app that owns this one.
                switch helperOwner(of: process.pid) {
                case .app(let owner):
                    processBundle = owner
                case .notAnApp:
                    continue
                case .unknown:
                    // Can't tell, so assume the usual case: a browser.
                    heard(Source.browser.id, from: process.pid)
                    continue
                }
            }
            if let id = Source.builtInID(forProcessBundle: processBundle) {
                heard(id, from: process.pid)
                continue
            }
            let known = Source.known(forAppBundle: Source.appBundle(forProcessBundle: processBundle))
            let bundle = known?.id ?? Source.appBundle(forProcessBundle: processBundle)
            if found.contains(where: { $0.id == bundle }) {
                heard(bundle, from: process.pid)
            } else if !notApps.contains(bundle) {
                // Only real apps count: no daemons, no agents, and not BitMatch itself.
                if let name = runningAppName(bundle) {
                    var source = known ?? Source(id: bundle, kind: .other, name: name, defaultRule: .ignore)
                    source.name = name
                    found.append(source)
                    heard(bundle, from: process.pid)
                } else {
                    notApps.insert(bundle)
                }
            }
        }
        // A silent source keeps its last processes, so its stream format survives a pause.
        for (id, pids) in pidsNow { sourcePIDs[id] = pids }
        // Forget apps that went quiet and were never given a rule.
        found.removeAll { source in
            source.kind == .other && !playingNow.contains(source.id)
                && rule(for: source) == .ignore && expandedSourceID != source.id
        }
        if found != sources { sources = found }
        for source in sources {
            streak[source.id] = playingNow.contains(source.id) ? (streak[source.id] ?? 0) + 1 : 0
        }
        // The same app may have moved on to a stream with another format.
        if !reevaluate() { refreshRequest() }
    }

    /// Looks up the owner once per helper, for as long as that helper keeps playing.
    private func helperOwner(of pid: pid_t) -> ProcessOwner.Answer {
        if let known = helperOwners[pid] { return known }
        let answer = ownerOfProcess(pid)
        helperOwners[pid] = answer
        let owner: String
        switch answer {
        case .app(let bundle): owner = bundle
        case .notAnApp: owner = "a background process"
        case .unknown: owner = "an unknown owner"
        }
        appLog.notice("web audio from pid \(pid, privacy: .public) belongs to \(owner, privacy: .public)")
        return answer
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
        case .auto:
            if source.kind == .music { return trackFormat?.sampleRate }
            return activeStream?.sampleRate ?? source.presetRate
        case .fixed(let rate): return rate
        case .ignore: return nil
        }
    }

    /// The Apple Music track format, when Apple Music is the source being followed.
    private var followedTrack: TrackFormat? {
        guard let source = activeSource, source.kind == .music, rule(for: source) == .auto else { return nil }
        return trackFormat
    }

    /// True while the followed app is on "auto" but has given BitMatch nothing to go on.
    private var isWaitingForFormat: Bool {
        guard let source = activeSource, source.kind != .music, rule(for: source) == .auto else { return false }
        return activeStream == nil && source.presetRate == nil
    }

    var sourceLabel: String {
        activeSource?.name ?? L("Source", "소스")
    }

    var sourceDetail: String {
        guard sourceRate != nil else { return "—" }
        if let track = followedTrack {
            return track.isLossless ? "\(track.bitDepth)-bit · \(track.codecName)" : track.codecName
        }
        if let stream = activeStream { return stream.codecName }
        let preset = L("Preset", "지정 값")
        return matchBitDepth ? "\(Self.presetBitDepth)-bit · \(preset)" : preset
    }

    var sourceCaption: String {
        if isWaitingForFormat { return L("No format reported · pick a rate below", "형식 정보 없음 · 아래에서 값 선택") }
        guard sourceRate != nil else { return L("Waiting for playback", "재생 대기 중") }
        if let track = followedTrack { return track.qualityLabel }
        if activeStream != nil { return L("Reported by the app", "앱이 알려 준 형식") }
        return L("Set per app below", "아래에서 앱별 설정")
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
            if source.kind == .music {
                guard let track = trackFormat else { return nil }
                return (track.sampleRate, matchBitDepth ? track.bitDepth : 0)
            }
            // Other apps report a sample rate at most, never a bit depth.
            guard let rate = stream(for: source)?.sampleRate ?? source.presetRate else { return nil }
            return (rate, matchBitDepth ? Self.presetBitDepth : 0)
        case .fixed(let preset):
            return (preset, matchBitDepth ? Self.presetBitDepth : 0)
        case .ignore:
            return nil
        }
    }

    /// Puts the output device into the format the active source calls for.
    func applyActive() {
        noteActiveStream()
        lastRequest = wantedFormat()
        guard live else { return }
        guard let request = lastRequest else {
            devices.refresh()
            return
        }
        appLog.notice("""
            asking for \(Int(request.rate), privacy: .public) Hz for \(self.activeSourceID ?? "?", privacy: .public)\
            \(self.activeStream == nil ? "" : " (reported by the app)", privacy: .public)
            """)
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
    enum SampleScene { case appleMusic, spotify, otherPlayer }

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
        case .otherPlayer:
            // A player on "auto" whose media engine reported the stream it is playing.
            let players = ["kr.co.bugs.macOS", "com.apple.TV"].compactMap(Source.known(forAppBundle:))
            state.sources += players
            state.activeSourceID = "com.apple.TV"
            state.activeStream = StreamFormat(pid: 0, codec: "aac ", sampleRate: 48000)
            state.expandedSourceID = "com.apple.TV"
            state.deviceRate = 48000
            state.deviceBits = 24
        }
        return state
    }
}
