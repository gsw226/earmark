import SwiftUI

@main
struct SoundctlApp: App {
    @State private var model = Model()

    var body: some Scene {
        MenuBarExtra("Earmark", systemImage: "speaker.wave.2.fill") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.permissionDenied {
                HStack {
                    Text("오디오 권한 필요")
                    Spacer()
                    Button("설정 열기") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                }
            }
            ForEach(model.devices.filter { $0.volume != nil || $0.muted != nil }) { device in
                DeviceRow(model: model, device: device)
            }
            Divider()
            ForEach(model.apps) { app in
                AppRow(model: model, app: app)
            }
            Divider()
            Toggle("로그인 시 실행", isOn: Binding(get: { model.launchAtLogin },
                                                set: { model.setLaunchAtLogin($0) }))
            Button("종료") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }
}

struct DeviceRow: View {
    let model: Model
    let device: OutputDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.name).lineLimit(1)
            HStack(spacing: 6) {
                if let muted = device.muted {
                    Button { model.setMuted(!muted, of: device) } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(muted ? "음소거 해제" : "음소거")
                    .accessibilityLabel(muted ? "음소거 해제" : "음소거")
                }
                if let volume = device.volume {
                    Slider(value: Binding(get: { Double(volume) },
                                          set: { model.setMasterVolume(Float($0), of: device) }),
                           in: 0...1)
                }
            }
        }
    }
}

struct AppRow: View {
    let model: Model
    let app: AudioApp

    var body: some View {
        let rule = model.rule(for: app.bundleID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(app.name).lineLimit(1)
                if let error = model.failed[app.bundleID] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(error)
                }
                Spacer()
                Picker("", selection: Binding(get: { rule.deviceUID },
                                              set: { model.setDevice($0, for: app.bundleID) })) {
                    Text("시스템 기본").tag(String?.none)
                    ForEach(model.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    if let uid = rule.deviceUID, !model.devices.contains(where: { $0.uid == uid }) {
                        Text(rule.deviceName ?? uid).foregroundStyle(.secondary).tag(String?.some(uid))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Slider(value: Binding(get: { Double(rule.volume) },
                                  set: { model.setVolume(Float($0), for: app.bundleID) }),
                   in: 0...1)
        }
    }
}
