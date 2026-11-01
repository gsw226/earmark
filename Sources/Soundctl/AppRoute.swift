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

/// Routes one app's processes to one output device at a gain:
/// muted process tap → private aggregate device (output device + tap) → IOProc copies tap × gain to output.
final class AppRoute {
    let processes: [AudioObjectID]
    let deviceUID: String
    private let gain: Gain
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var volume: Float {
        get { gain.value }
        set { gain.value = newValue }
    }

    init(processes: [AudioObjectID], deviceUID: String, volume: Float) throws {
        self.processes = processes
        self.deviceUID = deviceUID
        self.gain = Gain(volume)
        do { try start() } catch { stop(); throw error }
    }

    deinit { stop() }

    private func start() throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: processes)
        tap.uuid = UUID()
        tap.muteBehavior = .muted
        tap.isPrivate = true
        try check("create tap", AudioHardwareCreateProcessTap(tap, &tapID))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "soundctl",
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

        // Input buffers = the output device's own input streams (e.g. a USB headset mic), then the tap.
        let tapBuffer = deviceID(forUID: deviceUID)
            .map { caIDs($0, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count } ?? 0
        let gain = self.gain
        try check("create IOProc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            render(input: input, output: output, tapBuffer: tapBuffer, gain: gain.value)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
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

/// Copies the interleaved stereo Float32 tap buffer into every output buffer, scaled by `gain`.
/// Output channel c takes tap channel min(c, 1); a mono output gets the left channel.
// ponytail: assumes Float32 on both sides (HAL IOProc canonical format); convert if a device ever reports otherwise.
func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
            tapBuffer: Int, gain: Float) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    let source = tapBuffer < inputs.count ? inputs[tapBuffer] : nil

    for out in outputs {
        guard let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let outChannels = Int(max(out.mNumberChannels, 1))
        let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size
        guard let source, let src = source.mData?.assumingMemoryBound(to: Float.self) else {
            dst.update(repeating: 0, count: outSamples)
            continue
        }
        let inChannels = Int(max(source.mNumberChannels, 1))
        let frames = min(outSamples / outChannels, Int(source.mDataByteSize) / MemoryLayout<Float>.size / inChannels)
        for frame in 0..<frames {
            for channel in 0..<outChannels {
                dst[frame * outChannels + channel] = src[frame * inChannels + min(channel, inChannels - 1)] * gain
            }
        }
        (dst + frames * outChannels).update(repeating: 0, count: outSamples - frames * outChannels)
    }
}
