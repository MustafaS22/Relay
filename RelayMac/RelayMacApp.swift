import AppKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import RelayCore
import SwiftUI

@main
struct RelayMacApp: App {
    @StateObject private var model = HostModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Relay", id: "dashboard") {
            Dashboard(model: model)
                .frame(minWidth: 760, minHeight: 535)
                .tint(.relayAccent)
        }
        .defaultSize(width: 940, height: 610)

        MenuBarExtra {
            Text(model.streaming ? "Sharing with \(model.viewerName ?? "a device")" :
                    model.sharing ? (model.paused ? "Sharing paused" : "Ready to share") : "Sharing off")
            if model.sharing {
                Button(model.paused ? "Resume Sharing" : "Pause Sharing", action: model.togglePause)
            }
            Button(model.sharing || model.previewing || model.pairing ? "Stop Sharing" : "Start Sharing") {
                if model.sharing || model.previewing || model.pairing { model.stopEverything() } else { model.startSharing() }
            }
            Divider()
            Button("Open Relay") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink()
            Divider()
            Button("Quit Relay") {
                model.stopEverything()
                NSApp.terminate(nil)
            }
        } label: {
            Label("Relay", systemImage: model.streaming ? "rectangle.inset.filled.badge.record" :
                    model.previewing ? "rectangle.on.rectangle.circle.fill" : "rectangle.on.rectangle")
        }

        Settings {
            RelaySettings(model: model)
                .tint(.relayAccent)
        }
    }
}

private struct RelaySettings: View {
    @ObservedObject var model: HostModel
    @State private var address = ""

    var body: some View {
        Form {
            Section("Sharing") {
                Toggle("Launch Relay at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLaunchAtLogin))
                Toggle("Allow paired devices without asking", isOn: $model.autoAllow)
                Text("Sharing pauses while this Mac is locked or asleep. Stop Sharing turns off access until you start it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Internet Relay") {
                TextField("Server URL", text: $address, prompt: Text("https://relay.example.com"))
                    .onSubmit(saveAddress)
                Button("Save Address", action: saveAddress)
                    .disabled(address == model.relayService)
                Text("Required for viewing from another network. A paired viewer learns this server the next time it connects on the same Wi-Fi.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 510)
        .onAppear { address = model.relayService }
    }

    private func saveAddress() {
        model.setRelayService(address)
        if model.error == nil { address = model.relayService }
    }
}

private struct Dashboard: View {
    @ObservedObject var model: HostModel
    @State private var showPairing = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                heading
                preview
                if !model.permission { permission }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                metrics
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            inspector
        }
        .onAppear(perform: model.refreshDisplays)
        .sheet(isPresented: $showPairing, onDismiss: { model.setPairing(false) }) {
            PairingPanel(model: model)
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.relayAccent)
                .frame(width: 44, height: 44)
                .background(Color.relayAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.title2.weight(.semibold))
                Text("This Mac").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if model.sharing { model.stopEverything() } else { model.startSharing() }
            } label: {
                Label(model.sharing ? "Stop Sharing" : "Start Sharing",
                      systemImage: model.sharing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.streaming ? .red : .relayAccent)
            .controlSize(.large)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.9))
            if model.previewing {
                LayerView(displayLayer: model.preview)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Live display preview")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 38, weight: .light))
                    Text("Display Preview").font(.headline)
                    Button("Show Preview", action: model.togglePreview)
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .disabled(!model.permission)
                }
                .foregroundStyle(.white.opacity(0.78))
            }
            if model.previewing {
                VStack {
                    HStack {
                        Label("Preview", systemImage: "circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Button("Hide Preview", action: model.togglePreview)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording permission required", systemImage: "lock.shield")
                .font(.headline)
            Text("Allow Relay in Screen & System Audio Recording. Reopen Relay if macOS asks you to restart the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Request Permission", action: model.requestPermission)
                Link("Open System Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 16) {
            Label(status, systemImage: model.streaming ? "circle.fill" : "circle")
                .foregroundStyle(model.streaming ? .red : .secondary)
            Spacer()
            if let stats = model.stats {
                Text("\(stats.captured) capture fps")
                Text("\(stats.encoded) encode fps")
                Text(String(format: "%.2f Mbps", Double(stats.bitrate) / 1_000_000))
                Text("\(stats.dropped) drops")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var status: String {
        if model.streaming { return "Sharing live" }
        if model.paused { return "Sharing paused" }
        if model.sharing { return model.listening ? "Available to connect" : "Starting sharing…" }
        return "Sharing off"
    }

    private var inspector: some View {
        Form {
            Section("Sharing") {
                Picker("Display", selection: Binding(get: { model.selected }, set: { if let id = $0 { model.choose(id) } })) {
                    if model.displays.isEmpty { Text("Unavailable").tag(nil as UInt32?) }
                    ForEach(model.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                Picker("Quality", selection: Binding(get: { model.quality }, set: model.setQuality)) {
                    ForEach(Quality.allCases) { Text($0.title).tag($0) }
                }
                if model.effective != model.quality {
                    LabeledContent("Adaptive quality", value: model.effective.title)
                }
                LabeledContent("Screen Recording", value: model.permission ? "Allowed" : "Required")
                if model.sharing { Button(model.paused ? "Resume Sharing" : "Pause Sharing", action: model.togglePause) }
            }
            Section("Devices") {
                if let name = model.viewerName {
                    Label(name, systemImage: "iphone")
                        .badge(model.streaming ? "Live" : "Connected")
                }
                if let name = model.accessRequest {
                    Text("\(name) wants to view your screen.")
                    HStack {
                        Button("Decline") { model.approveViewing(false) }
                        Button("Allow") { model.approveViewing(true) }.buttonStyle(.borderedProminent)
                    }
                }
                Button("Pair a Device…", systemImage: "plus") {
                    model.setPairing(true)
                    showPairing = model.pairing
                }
                .disabled(model.viewerName != nil)
                if model.phones.isEmpty {
                    Text("No paired devices").foregroundStyle(.secondary)
                }
                ForEach(model.phones) { phone in
                    LabeledContent(phone.name) {
                        Button("Revoke", role: .destructive) { model.revoke(phone) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

private struct PairingPanel: View {
    @ObservedObject var model: HostModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a Device").font(.title2.weight(.semibold))
            if let approval = model.approval {
                Label("Allow \(approval) to pair?", systemImage: "iphone")
                HStack {
                    Button("Decline", role: .cancel) { model.approvePairing(false) }
                    Button("Allow & Pair") {
                        model.approvePairing(true)
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                }
            } else if let code = model.code {
                Text(code).font(.system(size: 42, weight: .medium, design: .monospaced))
                    .accessibilityLabel("Pairing code \(code)")
                Text("Enter this code on your iPhone or iPad.")
                if let expiry = model.codeExpires {
                    Text("Expires \(expiry, style: .relative)").foregroundStyle(.secondary)
                }
            } else {
                Text("Scan this code with your iPhone or iPad camera, or select this Mac in Relay and enter the fingerprint.")
                    .foregroundStyle(.secondary)
                if let url = model.pairURL, let image = qr(url) {
                    Image(nsImage: image).interpolation(.none)
                        .resizable().scaledToFit()
                        .frame(width: 156, height: 156)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("QR code for this Mac")
                }
                if let pin = model.pin {
                    Text(model.serviceName).font(.headline)
                    Text(pin.grouped).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.secondary) }
            Button("Done", role: .cancel) { dismiss() }.keyboardShortcut(.escape, modifiers: [])
        }
        .padding(24)
        .frame(width: 416, alignment: .leading)
        .onChange(of: model.pairing) { _, enabled in if !enabled { dismiss() } }
    }

    private func qr(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let code = filter.outputImage,
              let image = CIContext().createCGImage(code, from: code.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

private struct LayerView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = displayLayer
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private extension Color {
    static let relayAccent = Color(red: 0.30, green: 0.32, blue: 0.78)
}
