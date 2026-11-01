import AppKit
import CoreAudio
import Observation
import ServiceManagement

/// Owns rules and live routes; keeps routes in sync with running apps and connected devices.
@MainActor @Observable
final class Model {
    private(set) var apps: [AudioApp] = []
    private(set) var devices: [OutputDevice] = []
    private(set) var rules: [String: Rule]
    private(set) var failed: [String: String] = [:]
    private(set) var permissionDenied = false
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private var routes: [String: AppRoute] = [:]
    @ObservationIgnored private let store = RouteStore()

    init() {
        rules = store.load()
        for selector in [kAudioHardwarePropertyProcessObjectList,
                         kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            observeSystem(selector) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }

    func rule(for bundleID: String) -> Rule { rules[bundleID] ?? Rule() }

    func refresh() {
        devices = listOutputDevices()
        let running = listAudioApps()
        apps = running.filter { $0.isPlaying || rules[$0.bundleID] != nil }
        permissionDenied = audioCapturePermission() == .denied
        let byID = Dictionary(running.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
        for id in Set(routes.keys).union(rules.keys) { apply(id, app: byID[id]) }
    }

    func setDevice(_ uid: String?, for bundleID: String) {
        let name = devices.first { $0.uid == uid }?.name
        update(bundleID) {
            $0.deviceUID = uid
            if let name { $0.deviceName = name }
        }
    }

    func setVolume(_ volume: Float, for bundleID: String) {
        update(bundleID) { $0.volume = volume }
    }

    func setLaunchAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func update(_ bundleID: String, _ change: (inout Rule) -> Void) {
        var rule = rule(for: bundleID)
        change(&rule)
        rules[bundleID] = rule.isDefault ? nil : rule
        store.save(rules)
        apply(bundleID, app: apps.first { $0.bundleID == bundleID })
    }

    /// Makes the live route for one app match its rule. No rule, app not running,
    /// or target device missing → no route (app plays on the system default). Rule is kept.
    private func apply(_ bundleID: String, app: AudioApp?) {
        let rule = rule(for: bundleID)
        guard let app, !rule.isDefault,
              let target = rule.deviceUID ?? defaultOutputUID(),
              devices.contains(where: { $0.uid == target }) else {
            routes[bundleID] = nil
            failed[bundleID] = nil
            return
        }
        if let route = routes[bundleID], route.deviceUID == target, Set(route.processes) == Set(app.processes) {
            route.volume = rule.volume
            return
        }
        routes[bundleID] = nil
        do {
            routes[bundleID] = try AppRoute(processes: app.processes, deviceUID: target, volume: rule.volume)
            failed[bundleID] = nil
        } catch {
            failed[bundleID] = "\(error)"
        }
    }
}

// MARK: - Audio capture permission

enum Permission { case granted, denied, unknown }

/// Reads the "System Audio Recording" TCC state. There is no public API, so this uses TCC's preflight
/// (same approach as Apple's sample-adjacent tools); unknown means "not asked yet" — the first tap asks.
func audioCapturePermission() -> Permission {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
          let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
    switch unsafeBitCast(symbol, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .unknown
    }
}
