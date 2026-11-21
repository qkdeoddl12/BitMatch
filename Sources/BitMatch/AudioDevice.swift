import CoreAudio
import Foundation

/// Thin Core Audio wrapper for reading and changing an output device's sample rate and bit depth.
enum AudioDevice {
    private static let standardRates: [Double] = [
        44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000,
    ]

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, initial: T) -> T? {
        var addr = addr
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    private static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type) -> [T] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let capacity = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: min(capacity, Int(size) / MemoryLayout<T>.stride)))
    }

    private static func set<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ newValue: T) -> Bool {
        var addr = addr
        return withUnsafePointer(to: newValue) {
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }

    // MARK: Reading

    static func defaultOutputID() -> AudioDeviceID? {
        let id = value(AudioObjectID(kAudioObjectSystemObject),
                       address(kAudioHardwarePropertyDefaultOutputDevice),
                       initial: AudioDeviceID(kAudioObjectUnknown))
        return id == kAudioObjectUnknown ? nil : id
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var text: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &text) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let text else { return nil }
        return text.takeRetainedValue() as String
    }

    static func name(_ device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName)?.trimmingCharacters(in: .whitespaces)
    }

    static func nominalRate(_ device: AudioDeviceID) -> Double? {
        value(device, address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
    }

    static func availableRates(_ device: AudioDeviceID) -> [Double] {
        let ranges = array(device, address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                standardRates.filter { range.mMinimum <= $0 && $0 <= range.mMaximum }.forEach { rates.insert($0) }
            }
        }
        return rates.sorted()
    }

    static func outputStream(_ device: AudioDeviceID) -> AudioStreamID? {
        array(device, address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
              of: AudioStreamID.self).first
    }

    static func physicalFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        value(stream, address(kAudioStreamPropertyPhysicalFormat), initial: AudioStreamBasicDescription())
    }

    /// The bit depth the device is physically outputting right now.
    static func bitDepth(_ device: AudioDeviceID) -> Int? {
        guard let stream = outputStream(device), let format = physicalFormat(stream) else { return nil }
        return Int(format.mBitsPerChannel)
    }

    // MARK: Switching

    /// The device rate that suits a track best:
    /// exact match > integer multiple (44.1 -> 88.2) > lowest rate above > highest available.
    static func bestRate(for target: Double, among rates: [Double]) -> Double? {
        if rates.contains(target) { return target }
        if let multiple = rates.first(where: { $0 > target && $0.truncatingRemainder(dividingBy: target) == 0 }) {
            return multiple
        }
        return rates.first(where: { $0 > target }) ?? rates.last
    }

    struct ApplyResult {
        /// The sample rate the device should end up at.
        var target: Double
        /// True if the device accepted a format change and is now moving to `target`.
        var changing: Bool
    }

    /// Matches the device to a track. A `bitDepth` of 0 keeps the device's current bit depth.
    /// Returns nil if the device reports no usable sample rates.
    static func apply(sampleRate wanted: Double, bitDepth: Int, to device: AudioDeviceID) -> ApplyResult? {
        guard let rate = bestRate(for: wanted, among: availableRates(device)) else { return nil }
        var changing = false

        if let stream = outputStream(device), let current = physicalFormat(stream) {
            let usable = array(stream, address(kAudioStreamPropertyAvailablePhysicalFormats),
                               of: AudioStreamRangedDescription.self)
                .filter {
                    $0.mFormat.mFormatID == kAudioFormatLinearPCM
                        && $0.mSampleRateRange.mMinimum <= rate && rate <= $0.mSampleRateRange.mMaximum
                }
            let sameChannels = usable.filter { $0.mFormat.mChannelsPerFrame == current.mChannelsPerFrame }
            let pool = sameChannels.isEmpty ? usable : sameChannels

            let depths = Set(pool.map { Int($0.mFormat.mBitsPerChannel) }).sorted()
            let wantedDepth = bitDepth > 0 ? bitDepth : Int(current.mBitsPerChannel)
            // Never go below the track's bit depth: padding is lossless, truncating is not.
            if let depth = depths.first(where: { $0 >= wantedDepth }) ?? depths.last {
                let matches = pool.filter { Int($0.mFormat.mBitsPerChannel) == depth }
                let pick = matches.first { $0.mFormat.mFormatFlags == current.mFormatFlags } ?? matches.first
                if var format = pick?.mFormat {
                    format.mSampleRate = rate
                    let same = current.mSampleRate == rate && current.mBitsPerChannel == format.mBitsPerChannel
                    if !same, set(stream, address(kAudioStreamPropertyPhysicalFormat), format) {
                        changing = true
                    }
                }
            }
        }

        if nominalRate(device) != rate, set(device, address(kAudioDevicePropertyNominalSampleRate), Float64(rate)) {
            changing = true
        }
        return ApplyResult(target: rate, changing: changing)
    }

    // MARK: Who is playing

    struct OutputProcess {
        var bundleID: String
        var pid: pid_t
    }

    /// Processes that have an active output stream right now. When `device` is given, processes
    /// that are playing to some other device are left out.
    static func processesPlaying(on device: AudioDeviceID?) -> [OutputProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return array(system, address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
            .compactMap { process in
                guard value(process, address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)) == 1,
                      let bundle = string(process, kAudioProcessPropertyBundleID), !bundle.isEmpty
                else { return nil }
                if let device {
                    let used = array(process,
                                     address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
                                     of: AudioObjectID.self)
                    if !used.isEmpty, !used.contains(device) { return nil }
                }
                let pid = value(process, address(kAudioProcessPropertyPID), initial: pid_t(0)) ?? 0
                return OutputProcess(bundleID: bundle, pid: pid)
            }
    }

    // MARK: Snapshot

    /// Everything the UI shows about the default output device, read in one go.
    struct Snapshot {
        var id: AudioDeviceID
        var name: String?
        var rate: Double?
        var bits: Int?
        var rates: [Double]
    }

    static func snapshot() -> Snapshot? {
        guard let id = defaultOutputID() else { return nil }
        return Snapshot(id: id, name: name(id), rate: nominalRate(id), bits: bitDepth(id), rates: availableRates(id))
    }
}
