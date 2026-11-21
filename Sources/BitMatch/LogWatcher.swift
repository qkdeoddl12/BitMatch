import Foundation

/// The audio format the Music app is actually rendering right now.
struct TrackFormat: Equatable {
    var codec: String       // "qlac" (ALAC), "qaac" (AAC), ...
    var rendition: String   // "Lossless", "Stereo", ...
    var sampleRate: Double
    var bitDepth: Int       // 0 for lossy codecs

    var isLossless: Bool { bitDepth > 0 }

    var qualityLabel: String {
        if isLossless { return sampleRate > 48000 ? "Hi-Res Lossless" : "Lossless" }
        return L("Lossy", "손실 압축")
    }

    /// The codec Music is decoding, in the name people know it by.
    var codecName: String {
        switch codec {
        case "qlac", "alac": return "ALAC"
        case "qaac", "aac": return "AAC"
        default: return codec.uppercased()
        }
    }

    /// Extracts the format from one line of the system log, or nil if the line is something else.
    ///
    /// Music logs a line like this whenever an item starts (or resumes) playing:
    /// `fpfs_ReportAudioPlaybackThroughFigLog: ... [AudioFormat qlac is decodable] ...
    ///  [Rendition Lossless] [SampleRate 44100] [BitDepth 16] ...`
    static func parse(_ line: String) -> TrackFormat? {
        guard line.contains("fpfs_ReportAudioPlaybackThroughFigLog"),
              let rateText = capture(#"\[SampleRate (\d+)\]"#, in: line),
              let rate = Double(rateText), rate > 0
        else { return nil }
        return TrackFormat(
            codec: capture(#"\[AudioFormat (\w+)"#, in: line) ?? "?",
            rendition: capture(#"\[Rendition ([^\]]+)\]"#, in: line) ?? "?",
            sampleRate: rate,
            bitDepth: Int(capture(#"\[BitDepth (\d+)\]"#, in: line) ?? "") ?? 0
        )
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// Follows the system log and reports the playback format every time Music logs one.
///
/// The log is read through `/usr/bin/log`, which can die or go quiet (after sleep, for instance).
/// The watcher restarts it when it exits, and `resync()` catches the case where it is alive but stuck.
final class LogWatcher: @unchecked Sendable {
    private static let predicate =
        #"process == "Music" AND subsystem == "com.apple.coremedia" AND eventMessage CONTAINS "fpfs_ReportAudioPlaybackThroughFigLog""#
    private static let maxFailures = 5

    /// `log --style compact` starts every line with a local timestamp like `2026-11-22 00:55:24.168`.
    private static let stampFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private let lock = NSLock()
    private var process: Process?
    private var generation = 0      // bumped for every new stream; older streams are ignored
    private var stopped = false
    private var failures = 0
    private var lastStamp: Date?    // timestamp of the newest format line seen from any source

    /// Called on the main queue. `live` is false for the format recovered from history at launch.
    private let onFormat: (_ format: TrackFormat, _ live: Bool) -> Void
    private let onFailure: (String) -> Void

    init(onFormat: @escaping (TrackFormat, Bool) -> Void, onFailure: @escaping (String) -> Void) {
        self.onFormat = onFormat
        self.onFailure = onFailure
    }

    // MARK: Lifecycle

    func start() {
        startStream()
        // The track that was already playing before launch logged its format in the past.
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let recent = Self.mostRecent(last: "15m") else { return }
            noteStamp(recent.stamp)
            DispatchQueue.main.async { self.onFormat(recent.format, false) }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let running = process
        process = nil
        lock.unlock()
        Self.kill(running)
    }

    /// Replaces the stream with a fresh one.
    func restart() {
        lock.lock()
        let old = process
        process = nil
        generation += 1     // the old stream's exit is now none of our business
        failures = 0
        lock.unlock()
        Self.kill(old)
        startStream()
    }

    /// Checks recent history for a format line the stream never delivered. If there is one,
    /// the stream is stuck: deliver the format and replace the stream.
    func resync() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let recent = Self.mostRecent(last: "2m") else { return }
            lock.lock()
            let seen = lastStamp
            lock.unlock()
            if let stamp = recent.stamp, let seen, stamp <= seen { return }
            appLog.notice("log stream missed a format line; restarting it")
            noteStamp(recent.stamp)
            DispatchQueue.main.async { self.onFormat(recent.format, true) }
            restart()
        }
    }

    // MARK: History

    private static func mostRecent(last window: String) -> (format: TrackFormat, stamp: Date?)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["show", "--last", window, "--style", "compact", "--predicate", predicate]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            let line = String(line)
            if let format = TrackFormat.parse(line) { return (format, stamp(of: line)) }
        }
        return nil
    }

    private static func stamp(of line: String) -> Date? {
        stampFormat.date(from: String(line.prefix(23)))
    }

    private func noteStamp(_ stamp: Date?) {
        guard let stamp else { return }
        lock.lock()
        if lastStamp.map({ stamp > $0 }) ?? true { lastStamp = stamp }
        lock.unlock()
    }

    // MARK: Stream

    private static func kill(_ process: Process?) {
        // SIGKILL, because a stuck process may never get around to handling SIGTERM.
        if let process, process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
    }

    private func startStream() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        generation += 1
        let mine = generation
        lock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors

        var pending = Data()    // only ever touched by this stream's read handler
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil     // end of file; don't spin
                return
            }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                self?.handle(line)
            }
        }
        task.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            let stderrText = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
            self?.streamEnded(generation: mine, stderr: stderrText)
        }

        do {
            try task.run()
        } catch {
            report(L("Can't read the system log: \(error.localizedDescription)",
                     "시스템 로그를 읽을 수 없습니다: \(error.localizedDescription)"))
            return
        }
        lock.lock()
        let current = generation == mine && !stopped
        if current { process = task }
        lock.unlock()
        if !current { Self.kill(task) }     // replaced or stopped while it was launching
    }

    private func handle(_ line: String) {
        guard let format = TrackFormat.parse(line) else { return }
        lock.lock()
        failures = 0
        lock.unlock()
        noteStamp(Self.stamp(of: line))
        DispatchQueue.main.async { self.onFormat(format, true) }
    }

    private func streamEnded(generation mine: Int, stderr: String) {
        lock.lock()
        let current = mine == generation && !stopped
        if current {
            failures += 1
            process = nil
        }
        let attempt = failures
        lock.unlock()
        guard current else { return }

        if stderr.localizedCaseInsensitiveContains("admin") {
            report(L("Reading the system log needs an administrator account.",
                     "시스템 로그를 읽으려면 관리자 계정이 필요합니다."))
            return
        }
        guard attempt <= Self.maxFailures else {
            report(L("Lost access to the system log. Quit and reopen BitMatch.",
                     "시스템 로그 연결이 끊겼습니다. BitMatch를 다시 실행해 주세요."))
            return
        }
        appLog.notice("log stream ended; restarting (attempt \(attempt, privacy: .public))")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.generation == mine && !self.stopped
            self.lock.unlock()
            if stillCurrent { self.startStream() }
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onFailure(message) }
    }
}
