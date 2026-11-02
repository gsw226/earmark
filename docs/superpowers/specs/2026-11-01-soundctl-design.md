# soundctl design

Mac menu bar app that routes each app's audio to a chosen output device and sets a per-app volume.
Example: aside (browser) → built-in speakers at 60%, Discord → earphones at 100%.

## Decisions

- Form: menu bar app (`MenuBarExtra`, window style). No Dock icon (`LSUIElement`).
- Rules are saved per bundle ID and re-applied automatically when the app plays audio again or soundctl restarts.
- "Launch at login" toggle in the popover (`SMAppService.mainApp`).
- Target: macOS 26. Swift Package + `Scripts/make-app.sh` to bundle the .app (same pattern as soundis-swift).

## Approach

Core Audio process taps (no virtual driver).

Per routed app:

1. `CATapDescription(stereoMixdownOfProcesses:)` with the app's process object IDs (main + helpers),
   `muteBehavior = .muted`, private. Process object IDs instead of the macOS 26 `bundleIDs` property: deterministic,
   and the route is rebuilt whenever the app's process set changes (e.g. Chromium's audio helper starts).
   Muted means the app's original output to the system default device is silenced.
2. `AudioHardwareCreateProcessTap` → tap object, read its UID (`kAudioTapPropertyUID`).
3. `AudioHardwareCreateAggregateDevice` with the target output device as the only sub-device (main sub-device, clock source)
   and the tap in `kAudioAggregateDeviceTapListKey` with `kAudioSubTapDriftCompensationKey = true`,
   `kAudioAggregateDeviceTapAutoStartKey = true`, private.
4. IOProc on the aggregate device: copy tap input buffers to output buffers, multiply by gain.

Rejected:
- Virtual HAL driver (BlackHole / Background Music style): needs admin install and coreaudiod restart; if it breaks, all system audio breaks.
- Relying on each app's own output setting: aside is a browser and has no app-wide output device picker.

## Components

| File | Responsibility |
|---|---|
| `AudioApps.swift` | Lists processes from `kAudioHardwarePropertyProcessObjectList` (bundle ID, PID, `IsRunningOutput`). Groups helper processes under their parent app by bundle ID prefix (`com.hnc.Discord.helper.Renderer` → `com.hnc.Discord`). Resolves app name/icon via `NSRunningApplication` / `NSWorkspace`. Observes process list and device list changes. Also lists output devices (UID, name). |
| `AppRoute.swift` | One app's routing engine: create/destroy tap + aggregate device + IOProc. `gain` is an atomic float read by the IOProc; changing it does not rebuild anything. |
| `RouteStore.swift` | `[bundleID: Rule]` in UserDefaults, `Rule = { deviceUID: String?, volume: Float }`. `deviceUID == nil` means system default. Devices stored by UID so a reconnected device is recognized. |
| `Model.swift` | Observable state for the UI: apps, devices, rules, failures. Keeps live routes in sync with rules, running apps and devices. Permission check and launch-at-login. |
| `App.swift` | Menu bar popover: one row per app [icon, name, device picker, volume slider 0–100%], then "Launch at login" toggle and Quit. |

App list shown = apps currently producing output ∪ apps that have a saved rule and are running.

## Output device controls

Top of the popover: one row per output device with a settable master volume or mute (devices without either are hidden):
[name] then [mute button, master volume slider]. Reads/writes `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`
and `kAudioDevicePropertyMute` (output scope). Listens to both per device so volume keys / Control Center changes show up.
A routed app's audio is silent if its target device is muted; soundctl never changes mute on its own (user decision 2026-11-02),
the user unmutes from the device row.

## Core rule

An app on the system default device at 100% volume gets no tap. Only apps the user actually changed are intercepted,
so untouched apps get no extra latency and no risk.

## Data flow

1. Launch: load rules, list processes. For each running app with a rule, create its `AppRoute`.
2. Process list changes: create routes for newly running apps that have rules; rebuild a route whose app gained or lost
   a process object.
3. User changes volume: update `gain` only, save rule.
4. User changes device: rebuild the aggregate device, save rule.
5. User sets an app back to default device + 100%: destroy the route, delete the rule.

Device "system default" with volume < 100%: the aggregate device targets the current default output device and is rebuilt
when the default output device changes.

## Error handling

| Case | Behavior |
|---|---|
| Target device disconnected (earphones unplugged) | Destroy the route so the app plays on the system default. Keep the rule. When the device reappears, re-apply. The picker shows the device name dimmed. |
| Audio capture permission denied | One line at the top of the popover ("오디오 권한 필요") with a button that opens System Settings. |
| soundctl crashes or quits | Taps and private aggregate devices belong to the process; the OS releases them and audio returns to normal. No recovery code. |
| Tap / aggregate creation fails | Tear down whatever was created, leave that app unrouted, mark its row as failed. Other apps are unaffected. |
| Sample rate / channel mismatch | Tap is a stereo mixdown; drift compensation on the aggregate handles clock and rate differences. |

`Info.plist` needs `NSAudioCaptureUsageDescription`. The app must be signed with a stable identity (Apple Development cert)
so the permission survives rebuilds.

## Testing

- One XCTest file: bundle-ID grouping (`com.hnc.Discord.helper` → `com.hnc.Discord`, unrelated IDs stay separate) and
  `RouteStore` save → load round trip.
- Manual checks (audio routing cannot be automated):
  1. aside → speakers, Discord → earphones: each plays on its device.
  2. Moving a volume slider takes effect immediately.
  3. Unplug earphones → Discord falls back to default; plug back in → returns to earphones.
  4. Restart soundctl → rules re-applied automatically.

## Out of scope

EQ, per-app microphone input, hotkeys, presets, volume above 100%.
