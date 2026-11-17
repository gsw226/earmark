import CoreAudio
import Foundation
import Synchronization

struct RouteError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

/// Gain shared with the realtime IO thread. Stored as Float bits in an atomic.
final class Gain: Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic(value.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Slider position 0...1 → amplitude. Squared so the bottom of the slider isn't all near-silence.
func amplitude(_ volume: Float) -> Float { volume * volume }

/// Routes one app's processes to one output device at a gain:
/// muted process tap → private aggregate device (output device + tap) → IOProc copies tap × gain to output.
final class AppRoute {
    let processes: [AudioObjectID]
    let deviceUID: String
    private let gain: Gain
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(processes: [AudioObjectID], deviceUID: String, volume: Float) throws {
        self.processes = processes
        self.deviceUID = deviceUID
        self.gain = Gain(amplitude(volume))
        do { try start() } catch { stop(); throw error }
    }

    deinit { stop() }

    func setVolume(_ volume: Float) { gain.value = amplitude(volume) }

    private func start() throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: processes)
        tap.uuid = UUID()
        tap.muteBehavior = .muted
        tap.isPrivate = true
        try check("create tap", AudioHardwareCreateProcessTap(tap, &tapID))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earmark",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check("create aggregate", AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID))

        let stereo = deviceID(forUID: deviceUID).map(stereoChannels) ?? (0, 1)
        let gain = self.gain
        var current = gain.value  // only touched on the IO thread
        try check("create IOProc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            let target = gain.value
            render(input: input, output: output, stereo: stereo, from: current, to: target)
            current = target
        })
        try useOnlyTapInput()
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    /// Turns off every aggregate input stream except the tap (the last one). Otherwise the output device's own mic
    /// opens too, which drops Bluetooth headsets like AirPods into the low-quality call profile.
    private func useOnlyTapInput() throws {
        guard let procID else { return }
        var address = caAddress(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check("stream usage size", AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        try check("get stream usage", AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw))
        let count = Int(usage.pointee.mNumberStreams)
        let isOn = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        for stream in 0..<count { isOn[stream] = stream == count - 1 ? 1 : 0 }
        try check("set stream usage", AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, raw))
    }

    func stop() {
        if let procID {
            let status = AudioDeviceStop(aggregateID, procID)
            if status != noErr { log.error("AudioDeviceStop failed (\(status))") }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw RouteError(step: step, status: status) }
    }
}

/// The device's preferred stereo pair as 0-based channel indices (e.g. channels 3/4 on some interfaces).
func stereoChannels(of device: AudioObjectID) -> (Int, Int) {
    var address = caAddress(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
    var pair: (UInt32, UInt32) = (1, 2)
    var size = UInt32(MemoryLayout.size(ofValue: pair))
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pair) == noErr,
          pair.0 > 0, pair.1 > 0 else { return (0, 1) }
    return (Int(pair.0) - 1, Int(pair.1) - 1)
}

/// Copies the stereo Float32 tap (the last input buffer) onto the device's stereo pair, gain ramped from `from` to `to`
/// across the buffer so slider moves don't click. Output channels are counted across buffers, so interleaved and
/// per-channel (non-interleaved) devices both work; channels outside the pair are silent. A mono output gets the left channel.
// ponytail: assumes Float32 on both sides (HAL IOProc canonical format); convert if a device ever reports otherwise.
func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
            stereo: (Int, Int), from: Float, to: Float) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let source = inputs.last
    let src = source?.mData?.assumingMemoryBound(to: Float.self)
    let inChannels = Int(max(source?.mNumberChannels ?? 1, 1))
    let inFrames = Int(source?.mDataByteSize ?? 0) / MemoryLayout<Float>.size / inChannels

    var firstChannel = 0
    for out in UnsafeMutableAudioBufferListPointer(output) {
        let outChannels = Int(max(out.mNumberChannels, 1))
        defer { firstChannel += outChannels }
        guard let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size
        dst.update(repeating: 0, count: outSamples)
        guard let src else { continue }
        let frames = min(outSamples / outChannels, inFrames)
        let step = frames > 0 ? (to - from) / Float(frames) : 0
        for channel in 0..<outChannels {
            let device = firstChannel + channel
            guard device == stereo.0 || device == stereo.1 else { continue }
            let tapChannel = device == stereo.0 ? 0 : min(1, inChannels - 1)
            for frame in 0..<frames {
                dst[frame * outChannels + channel] = src[frame * inChannels + tapChannel] * (from + step * Float(frame + 1))
            }
        }
    }
}
