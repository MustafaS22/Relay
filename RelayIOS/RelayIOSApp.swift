import AVFoundation
import RelayCore
import SwiftUI

@main
struct RelayIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            DeviceList(model: model)
                .tint(Color(red: 0.30, green: 0.32, blue: 0.78))
                .onOpenURL(perform: model.receiveLink)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase != .inactive { model.setForeground(phase == .active) }
                }
        }
    }
}

private struct DeviceList: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.openURL) private var openURL
    @State private var pairing: PairDestination?
    @State private var settingsOpen = false
    @State private var editingMac: TrustedMac?
    @State private var connectAfterDismissal: (() -> Void)?

    private struct PairDestination: Identifiable {
        let service: String?
        var id: String { service ?? "manual" }
    }

    var body: some View {
        NavigationStack {
            List {
                if !model.trusted.isEmpty {
                    Section("Paired Macs") {
                        ForEach(model.trusted) { mac in
                            Button { model.connect(mac) } label: {
                                deviceRow(mac.name, subtitle: subtitle(for: mac))
                            }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Forget", role: .destructive) { model.forget(mac) }
                                Button("Address", systemImage: "network") { editingMac = mac }.tint(.indigo)
                            }
                            .contextMenu {
                                Button("Edit Direct Address", systemImage: "network") { editingMac = mac }
                            }
                        }
                    }
                }
                Section {
                    let unpaired = model.nearby.filter { candidate in !model.trusted.contains { $0.service == candidate.name } }
                    ForEach(unpaired) { mac in
                        Button { pairing = PairDestination(service: mac.name) } label: {
                            deviceRow(mac.name, subtitle: "Discovered on this network")
                        }
                    }
                    if unpaired.isEmpty {
                        if model.searching {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Looking for Macs…").foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No new Macs discovered").font(.headline)
                                Text("Open Relay on your Mac and select Pair a Device. Keep both devices on the same Wi-Fi.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    if let issue = model.discoveryIssue {
                        Text(issue).foregroundStyle(.secondary)
                        Button("Open Settings", systemImage: "gear") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                } header: {
                    Text("Nearby Macs")
                }
                Section {
                    Button("Connect by IP Address", systemImage: "network") { pairing = PairDestination(service: nil) }
                }
            }
            .navigationTitle("Relay")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settingsOpen = true }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a Mac", systemImage: "plus") { pairing = PairDestination(service: nil) }
                        .labelStyle(.iconOnly)
                }
            }
            .sheet(item: $pairing, onDismiss: {
                let connect = connectAfterDismissal
                connectAfterDismissal = nil
                connect?()
            }) { destination in
                PairForm(service: destination.service) { address, pin in
                    connectAfterDismissal = {
                        if let service = destination.service { model.connectService(service, pin: pin) }
                        else { model.connectManual(address, pin: pin) }
                    }
                    pairing = nil
                }
            }
            .sheet(item: $editingMac) { mac in
                RemoteAddressForm(mac: mac) { model.updateAddress(for: mac, to: $0) }
            }
            .sheet(isPresented: $settingsOpen) {
                NavigationStack {
                    Form {
                        Toggle("Show stream statistics", isOn: $model.showStats)
                    }
                    .navigationTitle("Settings")
                    .toolbar { Button("Done") { settingsOpen = false } }
                }
            }
            .alert("Pair with this Mac?", isPresented: Binding(
                get: { model.pendingLink != nil },
                set: { if !$0 { model.pendingLink = nil } }
            ), presenting: model.pendingLink) { link in
                Button("Continue") { model.connectService(link.service, pin: link.pin) }
                Button("Cancel", role: .cancel) { model.pendingLink = nil }
            } message: { link in
                Text("Continue only if you scanned the code in Relay directly from your Mac.\n\(link.service)")
            }
            .fullScreenCover(isPresented: Binding(get: { model.sessionOpen }, set: { if !$0 { model.disconnect() } })) {
                LiveViewer(model: model)
            }
        }
    }

    private func subtitle(for mac: TrustedMac) -> String {
        if model.isNearby(mac) { return "Nearby" }
        if mac.tunnel != nil { return "Internet relay configured" }
        if mac.address != nil { return "Saved network address" }
        return "Last connected \(mac.lastConnected.formatted(.relative(presentation: .named)))"
    }

    private func deviceRow(_ name: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3.weight(.medium))
                .frame(width: 42, height: 42)
                .foregroundStyle(.tint)
                .background(.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct PairForm: View {
    let service: String?
    let connect: (String, IdentityPin) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var fingerprint = ""

    var body: some View {
        NavigationStack {
            Form {
                if let service {
                    Section("Mac") { Label(service, systemImage: "desktopcomputer") }
                } else {
                    Section {
                        TextField("Mac hostname or IP address", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    } footer: {
                        Text("Find the Mac’s IP address in System Settings → Network → Wi-Fi → Details.")
                    }
                }
                Section {
                    TextField("Fingerprint", text: $fingerprint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } footer: {
                    Text("Enter the fingerprint shown under Pair a Device on your Mac. You can also scan the QR code using Camera.")
                }
            }
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let pin = IdentityPin(fingerprint) else { return }
                        connect(host, pin)
                    }
                    .disabled(IdentityPin(fingerprint) == nil || (service == nil && RemoteAddress.validated(host) == nil))
                }
            }
        }
    }
}

private struct RemoteAddressForm: View {
    let mac: TrustedMac
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Hostname or IP address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("Use the Mac’s hostname or IP on the same network if discovery fails.")
                }
            }
            .navigationTitle("Direct Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(address); dismiss() }
                        .disabled(!address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && RemoteAddress.validated(address) == nil)
                }
            }
        }
        .onAppear { address = mac.address ?? "" }
    }
}
