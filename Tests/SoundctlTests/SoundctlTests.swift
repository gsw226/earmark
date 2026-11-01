import CoreAudio
import XCTest
@testable import Soundctl

final class SoundctlTests: XCTestCase {
    func testHelpersGroupUnderParentApp() {
        let apps: Set = ["com.hnc.Discord", "at.studio.AsideBrowser", "com.apple.Music"]
        XCTAssertEqual(parentBundleID(of: "com.hnc.Discord.helper.Renderer", apps: apps), "com.hnc.Discord")
        XCTAssertEqual(parentBundleID(of: "at.studio.AsideBrowser.helper", apps: apps), "at.studio.AsideBrowser")
        XCTAssertEqual(parentBundleID(of: "com.hnc.Discord", apps: apps), "com.hnc.Discord")
        XCTAssertEqual(parentBundleID(of: "com.hnc.DiscordPTB", apps: apps), "com.hnc.DiscordPTB")
        XCTAssertEqual(parentBundleID(of: "com.apple.WebKit.GPU", apps: apps), "com.apple.WebKit.GPU")
    }

    func testRulesRoundTrip() {
        let defaults = UserDefaults(suiteName: "soundctl-tests")!
        defer { defaults.removePersistentDomain(forName: "soundctl-tests") }
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
                render(input: &input, output: &output, tapBuffer: 0, gain: 0.5)
            }
        }
        XCTAssertEqual(out, [0.5, -0.5, 0.25, -0.25, 0, 0])
    }
}
