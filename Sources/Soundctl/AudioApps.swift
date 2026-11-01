import AppKit
import CoreAudio

// MARK: - Core Audio property helpers

func caAddress(_ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func caIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = caAddress(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func caValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = caAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func caString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = caAddress(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

/// Calls `handler` on the main queue whenever a system-object property changes.
func observeSystem(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
    var address = caAddress(selector)
    AudioObjectAddPropertyListenerBlock(systemObject, &address, .main) { _, _ in handler() }
}

// MARK: - Apps

/// An app with one or more Core Audio process objects (main process + helpers).
struct AudioApp: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var isPlaying: Bool
    var id: String { bundleID }
}

/// `com.hnc.Discord.helper.Renderer` → `com.hnc.Discord` when `com.hnc.Discord` is a running app.
/// Longest matching app wins; unmatched IDs map to themselves.
func parentBundleID(of id: String, apps: Set<String>) -> String {
    apps.filter { id == $0 || id.hasPrefix($0 + ".") }.max { $0.count < $1.count } ?? id
}

/// Running apps that own Core Audio process objects, helpers folded into their parent app.
func listAudioApps() -> [AudioApp] {
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let byID = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
                          uniquingKeysWith: { a, _ in a })
    let appIDs = Set(byID.keys)
    let me = Bundle.main.bundleIdentifier

    var apps: [String: AudioApp] = [:]
    for process in caIDs(systemObject, kAudioHardwarePropertyProcessObjectList) {
        guard let bundle = caString(process, kAudioProcessPropertyBundleID), !bundle.isEmpty else { continue }
        let parent = parentBundleID(of: bundle, apps: appIDs)
        guard parent != me, let app = byID[parent] else { continue }
        let playing = (caValue(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0
        apps[parent, default: AudioApp(bundleID: parent, name: app.localizedName ?? parent,
                                       icon: app.icon, processes: [], isPlaying: false)]
            .processes.append(process)
        if playing { apps[parent]?.isPlaying = true }
    }
    return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

// MARK: - Output devices

struct OutputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Physical/virtual output devices, excluding aggregates (ours included).
func listOutputDevices() -> [OutputDevice] {
    caIDs(systemObject, kAudioHardwarePropertyDevices).compactMap { device in
        guard !caIDs(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty,
              caValue(device, kAudioDevicePropertyTransportType, UInt32(0)) != kAudioDeviceTransportTypeAggregate,
              let uid = caString(device, kAudioDevicePropertyDeviceUID),
              let name = caString(device, kAudioObjectPropertyName) else { return nil }
        return OutputDevice(uid: uid, name: name)
    }
}

func defaultOutputUID() -> String? {
    guard let device = caValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
          device != kAudioObjectUnknown else { return nil }
    return caString(device, kAudioDevicePropertyDeviceUID)
}

func deviceID(forUID uid: String) -> AudioObjectID? {
    caIDs(systemObject, kAudioHardwarePropertyDevices).first { caString($0, kAudioDevicePropertyDeviceUID) == uid }
}
