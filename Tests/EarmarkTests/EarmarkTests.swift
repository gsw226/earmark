import CoreAudio
import XCTest
@testable import Earmark

final class EarmarkTests: XCTestCase {
    func testHelpersGroupUnderParentApp() {
        let apps: Set = ["com.hnc.Discord", "at.studio.AsideBrowser", "com.apple.Music"]
        XCTAssertEqual(parentBundleID(of: "com.hnc.Discord.helper.Renderer", apps: apps), "com.hnc.Discord")
        XCTAssertEqual(parentBundleID(of: "at.studio.AsideBrowser.helper", apps: apps), "at.studio.AsideBrowser")
        XCTAssertEqual(parentBundleID(of: "com.hnc.Discord", apps: apps), "com.hnc.Discord")
        XCTAssertEqual(parentBundleID(of: "com.hnc.DiscordPTB", apps: apps), "com.hnc.DiscordPTB")
        XCTAssertEqual(parentBundleID(of: "com.apple.WebKit.GPU", apps: apps), "com.apple.WebKit.GPU")
    }

    func testRulesRoundTrip() {
        let defaults = UserDefaults(suiteName: "earmark-tests")!
        defer { defaults.removePersistentDomain(forName: "earmark-tests") }
        let store = RouteStore(defaults: defaults)
        let rules = ["com.hnc.Discord": Rule(deviceUID: "airpods", deviceName: "AirPods", volume: 0.5)]
        store.save(rules)
        XCTAssertEqual(store.load(), rules)
        XCTAssertTrue(Rule().isDefault)
        XCTAssertFalse(Rule(volume: 0.5).isDefault)
    }

    func testRenderScalesStereoTapIntoOutput() {
        var tap: [Float] = [1, -1, 0.5, -0.5]          // 2 frames, interleaved stereo
        var out = [Float](repeating: 9, count: 6)       // room for 3 frames → last frame zeroed
        tap.withUnsafeMutableBufferPointer { tapPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: 16, mData: UnsafeMutableRawPointer(tapPtr.baseAddress)))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: 24, mData: UnsafeMutableRawPointer(outPtr.baseAddress)))
                render(input: &input, output: &output, stereo: (0, 1), from: 0.5, to: 0.5)
            }
        }
        XCTAssertEqual(out, [0.5, -0.5, 0.25, -0.25, 0, 0])
    }

    /// Three mono output buffers (non-interleaved), stereo pair on channels 2/3: channel 1 stays silent,
    /// L and R land in their own buffers, and gain ramps 0 → 1 across the 2 frames.
    func testRenderNonInterleavedStereoPairWithRamp() {
        var tap: [Float] = [1, -1, 1, -1]
        let channels = (0..<3).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 2) }
        defer { channels.forEach { $0.deallocate() } }
        tap.withUnsafeMutableBufferPointer { tapPtr in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 16, mData: UnsafeMutableRawPointer(tapPtr.baseAddress)))
            let output = AudioBufferList.allocate(maximumBuffers: 3)
            defer { free(output.unsafeMutablePointer) }
            for (i, channel) in channels.enumerated() {
                channel.update(repeating: 9, count: 2)
                output[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: UnsafeMutableRawPointer(channel))
            }
            render(input: &input, output: output.unsafeMutablePointer, stereo: (1, 2), from: 0, to: 1)
        }
        let outs = channels.map { Array(UnsafeBufferPointer(start: $0, count: 2)) }
        XCTAssertEqual(outs, [[0, 0], [0.5, 1], [-0.5, -1]])
    }

    func testVolumeCurve() {
        XCTAssertEqual(amplitude(1), 1)
        XCTAssertEqual(amplitude(0.5), 0.25)
        XCTAssertEqual(amplitude(0), 0)
    }
}
