import Foundation

/// First capture group of `pattern` in `text`.
private func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

/// A Core Audio four-character codec code in the name people know it by.
func codecDisplayName(_ code: String) -> String {
    switch code.trimmingCharacters(in: .whitespaces).lowercased() {
    case "qlac", "alac": return "ALAC"
    case "qaac", "aac": return "AAC"
    case "aach", "aacp": return "HE-AAC"
    case "flac", "qflc": return "FLAC"
    case "lpcm": return "PCM"
    case ".mp3", "mp3": return "MP3"
    case "opus": return "Opus"
    case "ac-3": return "Dolby Digital"
    case "ec-3": return "Dolby Digital Plus"
    default: return code.trimmingCharacters(in: .whitespaces).uppercased()
    }
}

/// What an app's media engine says it is about to play.
///
/// Any app that plays through macOS's own media stack (AVPlayer, Safari, the TV app) reports one,
/// so this reaches far beyond Apple Music. It carries a sample rate but no bit depth.
struct StreamFormat: Equatable {
    var pid: pid_t
    var codec: String       // four-character code: "aac ", "lpcm", "alac", ...
    var sampleRate: Double

    var codecName: String { codecDisplayName(codec) }

    /// CoreMedia logs a line like this from the playing process whenever it opens an audio queue:
    /// `Safari[123:4ab] [com.apple.coremedia:] ... Creating AudioQueue with format:'aac ',
    ///  framesPerPacket:1024, sampleRate:44100, ...`
    static func parse(_ line: String) -> StreamFormat? {
        guard line.contains("Creating AudioQueue with format"),
              let pidText = capture(#"\[(\d+):[0-9a-fA-F]+\] \[com\.apple\.coremedia"#, in: line),
              let pid = pid_t(pidText),
              let rateText = capture(#"sampleRate:(\d+)"#, in: line),
              let rate = Double(rateText), rate >= 8000, rate <= 768_000
        else { return nil }
        return StreamFormat(pid: pid, codec: capture(#"format:'(.{4})'"#, in: line) ?? "?", sampleRate: rate)
    }
}

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
    var codecName: String { codecDisplayName(codec) }

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
}

/// Follows the system log and reports the playback format every time Music logs one, plus the
/// stream format any other app's media engine announces.
///
/// The log is read through `/usr/bin/log`, which can die or go quiet (after sleep, for instance).
/// The watcher restarts it when it exits, and `resync()` catches the case where it is alive but stuck.
final class LogWatcher: @unchecked Sendable {
    private static let predicate = #"subsystem == "com.apple.coremedia" AND "#
        + #"((process == "Music" AND eventMessage CONTAINS "fpfs_ReportAudioPlaybackThroughFigLog") "#
        + #"OR eventMessage CONTAINS "Creating AudioQueue with format")"#
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
    private let onStream: (_ stream: StreamFormat, _ live: Bool) -> Void
    private let onFailure: (String) -> Void

    init(onFormat: @escaping (TrackFormat, Bool) -> Void,
         onStream: @escaping (StreamFormat, Bool) -> Void,
         onFailure: @escaping (String) -> Void) {
        self.onFormat = onFormat
        self.onStream = onStream
        self.onFailure = onFailure
    }

    // MARK: Lifecycle

    func start() {
        startStream()
        // Whatever was already playing before launch logged its format in the past.
        DispatchQueue.global(qos: .utility).async { [self] in
            let lines = Self.history(last: "1h")
            // One entry per process: the newest.
            var streams: [pid_t: StreamFormat] = [:]
            for line in lines {
                if let stream = StreamFormat.parse(line) { streams[stream.pid] = stream }
            }
            let recent = Self.mostRecent(in: lines).flatMap { found in
                // A track that started more than a quarter of an hour ago is unlikely to be this one.
                found.stamp.map { $0.timeIntervalSinceNow > -15 * 60 } ?? true ? found : nil
            }
            noteStamp(recent?.stamp)
            DispatchQueue.main.async {
                if let recent { self.onFormat(recent.format, false) }
                for stream in streams.values { self.onStream(stream, false) }
            }
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
            guard let recent = Self.mostRecent(in: Self.history(last: "2m")) else { return }
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

    /// The matching log lines from the recent past, oldest first.
    private static func history(last window: String) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["show", "--last", window, "--style", "compact", "--predicate", predicate]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The newest Music track format among `lines`.
    private static func mostRecent(in lines: [String]) -> (format: TrackFormat, stamp: Date?)? {
        for line in lines.reversed() {
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
        if let format = TrackFormat.parse(line) {
            lock.lock()
            failures = 0
            lock.unlock()
            noteStamp(Self.stamp(of: line))
            DispatchQueue.main.async { self.onFormat(format, true) }
        } else if let stream = StreamFormat.parse(line) {
            lock.lock()
            failures = 0
            lock.unlock()
            DispatchQueue.main.async { self.onStream(stream, true) }
        }
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
