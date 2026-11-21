import CoreAudio
import Foundation
import os

/// Runs every Core Audio call on one background queue, so a slow or disappearing device
/// can never stall the menu bar.
final class DeviceController: @unchecked Sendable {
    /// Called on the main queue with the device's current state. `settled` is true when this
    /// is the outcome of the most recent `match` request.
    var onSnapshot: ((AudioDevice.Snapshot?, _ settled: Bool) -> Void)?
    /// Called on the main queue when the default output device changes.
    var onDefaultDeviceChange: (() -> Void)?
    /// Called on the main queue every couple of seconds with the apps that are playing audio.
    var onActivity: (([AudioDevice.OutputProcess]) -> Void)?

    /// How often to look at which apps are playing. Also the unit of the "is it still playing" debounce.
    private static let activityInterval: TimeInterval = 2

    /// How long to wait for a device to finish changing format before reporting what it did.
    private static let settleTimeout: TimeInterval = 2.5

    private let queue = DispatchQueue(label: "bitmatch.audio", qos: .userInitiated)
    private let latestRequest = OSAllocatedUnfairLock(initialState: 0)

    // Touched only on `queue`.
    private var watched = AudioDeviceID(kAudioObjectUnknown)
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var activityTimer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.activityInterval, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.reportActivity() }
        timer.resume()
        activityTimer = timer

        var addr = AudioDevice.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.onDefaultDeviceChange?()
        }
        refresh()
    }

    /// Looks at which apps are playing right away instead of waiting for the next tick.
    func pollActivityNow() {
        queue.async { [self] in reportActivity() }
    }

    private func reportActivity() {
        let playing = AudioDevice.processesPlaying(on: AudioDevice.defaultOutputID())
        DispatchQueue.main.async { self.onActivity?(playing) }
    }

    /// Re-reads the device without changing it.
    func refresh() {
        queue.async { [self] in publish(settled: false) }
    }

    /// Puts the default output device into the given format, then reports where it ended up.
    /// Requests made while an earlier one is still waiting replace it, so skipping quickly
    /// through tracks only ever switches to the track you land on.
    func match(sampleRate: Double, bitDepth: Int) {
        let mine = latestRequest.withLock { count -> Int in
            count += 1
            return count
        }
        queue.async { [self] in
            guard isLatest(mine) else { return }
            if let device = AudioDevice.defaultOutputID(),
               let result = AudioDevice.apply(sampleRate: sampleRate, bitDepth: bitDepth, to: device),
               result.changing {
                appLog.notice("switching output device to \(Int(result.target), privacy: .public) Hz")
                // Core Audio applies format changes asynchronously; give the device time to get there.
                let deadline = Date().addingTimeInterval(Self.settleTimeout)
                while AudioDevice.nominalRate(device) != result.target, Date() < deadline, isLatest(mine) {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            // A newer request will report for itself.
            if isLatest(mine) { publish(settled: true) }
        }
    }

    private func isLatest(_ request: Int) -> Bool {
        latestRequest.withLock { $0 == request }
    }

    private func publish(settled: Bool) {
        let snapshot = AudioDevice.snapshot()
        watch(snapshot?.id)
        DispatchQueue.main.async { self.onSnapshot?(snapshot, settled) }
    }

    /// Follows the sample rate of one device, so the UI stays right when something else changes it.
    private func watch(_ device: AudioDeviceID?) {
        let target = device ?? AudioDeviceID(kAudioObjectUnknown)
        guard target != watched else { return }
        var addr = AudioDevice.address(kAudioDevicePropertyNominalSampleRate)
        if let rateListener, watched != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(watched, &addr, queue, rateListener)
        }
        watched = target
        rateListener = nil
        guard target != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.publish(settled: false)
        }
        if AudioObjectAddPropertyListenerBlock(target, &addr, queue, listener) == noErr {
            rateListener = listener
        }
    }
}
