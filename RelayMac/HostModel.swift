import AppKit
import AVFoundation
import CoreGraphics
import Network
import RelayCore
import ServiceManagement

private enum HostPhase {
    case hello, proof(Data), code(PairingCode), approval, authorized, closing
}

@MainActor
private final class Viewer {
    let peer: Peer
    var phase = HostPhase.hello
    var name = ""
    var key = Data()
    var viewing = false
    var expires = Date.now.addingTimeInterval(12)
    var lastFrame: UInt64?
    var framesInFlight: [UInt64] = []
    var generation: UUID?
    var needsKeyframe = true
    var accessGranted = false
    var canPair = true

    init(_ peer: Peer) { self.peer = peer }
}

struct TrustedPhone: Identifiable, Codable {
    let key: Data
    let name: String
    var id: Data { key }
}

@MainActor
final class HostModel: NSObject, ObservableObject {
    @Published private(set) var sharing = false
    @Published private(set) var paused = false
    @Published private(set) var pairing = false
    @Published private(set) var listening = false
    @Published private(set) var permission = CGPreflightScreenCaptureAccess()
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var selected: UInt32?
    @Published private(set) var quality: Quality = .balanced
    @Published private(set) var effective: Quality = .balanced
    @Published private(set) var phones: [TrustedPhone] = []
    @Published private(set) var viewerName: String?
    @Published private(set) var code: String?
    @Published private(set) var codeExpires: Date?
    @Published private(set) var approval: String?
    @Published private(set) var accessRequest: String?
    @Published private(set) var pin: IdentityPin?
    @Published private(set) var previewing = false
    @Published private(set) var streaming = false
    @Published private(set) var stats: StreamStats?
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
    @Published var autoAllow = UserDefaults.standard.object(forKey: "autoAllow") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoAllow, forKey: "autoAllow") }
    }

    @Published private(set) var relayService = UserDefaults.standard.string(forKey: "relayService")
        ?? (Bundle.main.object(forInfoDictionaryKey: "RelayServiceURL") as? String ?? "")
    private var relayInvite: RelayInvite?
    private var relayListener: NWListener?
    private var relayTunnel: RelayTunnel?
    private var relayRetry: Task<Void, Never>?

    let preview = AVSampleBufferDisplayLayer()
    let name = Authentication.deviceName(Host.current().localizedName ?? "Mac")
    private var previewSamples = VideoSamples()
    private var listener: NWListener?
    private var viewer: Viewer?
    private var identity: ServerIdentity?
    private var capture: DisplayCapture?
    private var captureLifecycle: Task<Void, Never>?
    private var captureFrames: Task<Void, Never>?
    private var observationTokens: [NSObjectProtocol] = []
    private var heartbeat: Task<Void, Never>?
    private var revision = UUID()
    private var captureSignature: CaptureSignature?
    private var lastDropCount = 0
    private var congestedIntervals = 0
    private var healthyIntervals = 0
    private var lastPairAttempt = Date.distantPast
    private var shareAfterUnlock = false

    private struct CaptureSignature: Equatable {
        let display: DisplayInfo
        let quality: Quality
    }

    override init() {
        super.init()
        preview.videoGravity = .resizeAspect
        if let stored = UserDefaults.standard.string(forKey: "quality"), let preset = Quality(rawValue: stored) {
            quality = preset
            effective = preset
        }
        observeSystemChanges()
    }

    private func updateHeartbeat() {
        guard listener != nil || previewing else {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    private func observeSystemChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
            observationTokens.append(workspace.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendSharing() }
            })
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked),
                                                             name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked),
                                                             name: .init("com.apple.screenIsUnlocked"), object: nil)
        for event in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observationTokens.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDisplays() }
            })
        }
    }

    @objc nonisolated private func screenLocked() {
        Task { @MainActor [weak self] in self?.suspendSharing() }
    }

    @objc nonisolated private func screenUnlocked() {
        Task { @MainActor [weak self] in
            guard let self, self.shareAfterUnlock else { return }
            self.shareAfterUnlock = false
            self.startSharing()
        }
    }

    private func suspendSharing() {
        let armed = sharing || shareAfterUnlock
        stopEverything()
        shareAfterUnlock = armed
    }

    var serviceName: String {
        guard let pin else { return name }
        let label = String(decoding: name.utf8.prefix(48), as: UTF8.self)
        return label + " · " + pin.value.prefix(8)
    }

    var pairURL: URL? {
        guard let pin, pairing else { return nil }
        var components = URLComponents()
        components.scheme = "relay-screen"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "service", value: serviceName), URLQueryItem(name: "pin", value: pin.value)]
        return components.url
    }

    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        checkPermission()
    }

    func checkPermission() {
        let allowed = CGPreflightScreenCaptureAccess()
        if permission && !allowed { stopEverything() }
        permission = allowed
    }

    func refreshDisplays() {
        checkPermission()
        displays = CaptureDevice.catalog()
        if !displays.contains(where: { $0.id == selected }) {
            selected = displays.first(where: { $0.id == CGMainDisplayID() })?.id ?? displays.first?.id
        }
        catalog()
        reconcileCapture()
    }

    func setRelayService(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || RelayInvite.serviceURL(text) != nil else {
            error = "Enter an HTTPS relay server URL."
            return
        }
        relayService = RelayInvite.serviceURL(text)?.absoluteString ?? ""
        UserDefaults.standard.set(relayService, forKey: "relayService")
        error = nil
        stopInternetRelay()
        startInternetRelay()
    }

    private func startInternetRelay() {
        guard sharing, listening, relayListener == nil, let identity,
              let service = RelayInvite.serviceURL(relayService) else { return }
        do {
            let (invite, secret) = try RelayInvite.makeHost(service: service)
            let local = try RelayLoopback.listener(using: Transport.server(identity))
            relayInvite = invite
            relayListener = local
            local.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    if let self { self.accept(connection, canPair: false) }
                    else { connection.cancel() }
                }
            }
            local.stateUpdateHandler = { [weak self, weak local] state in
                MainActor.assumeIsolated {
                    guard let self, let local, self.relayListener === local else { return }
                    switch state {
                    case .ready:
                        if let port = local.port { self.openInternetTunnel(invite, secret: secret, port: port) }
                    case .failed(let issue):
                        self.stopInternetRelay()
                        self.error = "Internet relay: \(issue.localizedDescription)"
                    default: break
                    }
                }
            }
            local.start(queue: .main)
        } catch {
            self.error = "Internet relay: \(error.localizedDescription)"
        }
    }

    private func openInternetTunnel(_ invite: RelayInvite, secret: String, port: NWEndpoint.Port) {
        do {
            let tunnel = try RelayTunnel(invite: invite, hostSecret: secret,
                                         tcp: NWConnection(to: RelayLoopback.endpoint(port), using: .tcp))
            relayTunnel = tunnel
            tunnel.onFinish = { [weak self] in
                guard let self, self.sharing, self.relayListener?.port == port else { return }
                self.relayTunnel = nil
                self.relayRetry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, self.relayListener?.port == port else { return }
                    self.openInternetTunnel(invite, secret: secret, port: port)
                }
            }
            tunnel.start()
        } catch {
            self.error = "Internet relay: \(error.localizedDescription)"
        }
    }

    private func stopInternetRelay() {
        relayRetry?.cancel()
        relayRetry = nil
        relayListener?.cancel()
        relayListener = nil
        relayInvite = nil
        relayTunnel?.stop()
        relayTunnel = nil
    }

    func startSharing() {
        checkPermission()
        guard permission else {
            error = "Allow Relay in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Relay."
            return
        }
        error = nil
        shareAfterUnlock = false
        sharing = true
        paused = false
        startListener()
        if listener == nil { sharing = false }
        startInternetRelay()
        refreshDisplays()
    }

    func stopEverything() {
        shareAfterUnlock = false
        sharing = false
        stopInternetRelay()
        pairing = false
        previewing = false
        paused = false
        listener?.cancel()
        listener = nil
        listening = false
        updateHeartbeat()
        viewer?.peer.finish()
        reconcileCapture()
    }

    func setPairing(_ enabled: Bool) {
        pairing = enabled
        if enabled {
            startListener()
            if listener == nil { pairing = false }
        } else {
            if let viewer {
                switch viewer.phase {
                case .authorized: break
                default: viewer.peer.finish()
                }
            }
            if !sharing && viewer == nil { stopEverything() }
        }
    }

    func togglePause() {
        guard sharing else { return }
        paused.toggle()
        if let viewer {
            viewer.generation = nil
            viewer.needsKeyframe = true
            if paused { viewer.peer.control(.paused("The Mac paused sharing.")) }
            else if viewer.viewing { capture?.keyframe() }
        }
        reconcileCapture()
    }

    func togglePreview() {
        checkPermission()
        guard permission else { requestPermission(); return }
        previewing.toggle()
        updateHeartbeat()
        reconcileCapture()
        if previewing { refreshDisplays() }
    }

    func choose(_ display: UInt32) {
        guard displays.contains(where: { $0.id == display }) else {
            viewer?.peer.control(.paused("That display is unavailable."))
            return
        }
        selected = display
        catalog()
        reconcileCapture()
    }

    func setQuality(_ quality: Quality) {
        self.quality = quality
        effective = quality
        UserDefaults.standard.set(quality.rawValue, forKey: "quality")
        catalog()
        reconcileCapture()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func approvePairing(_ allowed: Bool) {
        guard let viewer, case .approval = viewer.phase else { return }
        approval = nil
        guard allowed, pairing, Date.now < viewer.expires else {
            deny(viewer, "Pairing declined or expired.")
            return
        }
        do {
            let updated = phones.filter { $0.key != viewer.key } + [TrustedPhone(key: viewer.key, name: viewer.name)]
            guard updated.count <= 64 else { throw RelayError.message("Remove a trusted device before pairing another.") }
            try persist(updated)
            viewer.accessGranted = true
            authorize(viewer)
            setPairing(false)
        } catch {
            self.error = error.localizedDescription
            deny(viewer, "The Mac could not save device trust.")
        }
    }

    func approveViewing(_ allowed: Bool) {
        guard let viewer, accessRequest != nil else { return }
        accessRequest = nil
        if allowed && sharing {
            viewer.accessGranted = true
            viewer.viewing = true
            reconcileCapture()
        } else {
            deny(viewer, "The Mac declined the viewing request.")
        }
    }

    func revoke(_ phone: TrustedPhone) {
        do {
            try persist(phones.filter { $0.id != phone.id })
            if let viewer, viewer.key == phone.key { viewer.peer.finish("This Mac revoked access.") }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func persist(_ phones: [TrustedPhone]) throws {
        try SecureStore.save(JSONEncoder().encode(phones), as: "trusted-phones")
        self.phones = phones
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let loaded = try identity ?? ServerIdentity.load()
            if let data = try SecureStore.load("trusted-phones") {
                phones = try JSONDecoder().decode([TrustedPhone].self, from: data)
            }
            identity = loaded
            pin = loaded.pin
            let server = try NWListener(using: Transport.server(loaded), on: NWEndpoint.Port(rawValue: RelayProtocol.port)!)
            server.service = NWListener.Service(name: serviceName, type: RelayProtocol.service)
            listener = server
            updateHeartbeat()
            server.newConnectionHandler = { [weak self, weak server] connection in
                MainActor.assumeIsolated {
                    guard let self, let server, self.listener === server else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                MainActor.assumeIsolated {
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready:
                        self.listening = true
                        self.startInternetRelay()
                    case .waiting(let issue): self.error = issue.localizedDescription
                    case .failed(let issue):
                        self.error = "Relay could not listen on port \(RelayProtocol.port). \(issue.localizedDescription)"
                        self.stopEverything()
                    default: break
                    }
                }
            }
            server.start(queue: .main)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func accept(_ connection: NWConnection, canPair: Bool = true) {
        guard viewer == nil, sharing || pairing else { connection.cancel(); return }
        let client = Viewer(Peer(connection))
        client.canPair = canPair
        viewer = client
        client.peer.onPacket = { [weak self, weak client] packet in
            guard let self, let client, self.viewer === client, case .control(let control) = packet else { return }
            self.receive(control, from: client)
        }
        client.peer.onClose = { [weak self, weak client] _ in
            guard let self, let client, self.viewer === client else { return }
            self.viewer = nil
            self.viewerName = nil
            self.code = nil
            self.codeExpires = nil
            self.approval = nil
            self.accessRequest = nil
            self.streaming = false
            if !self.sharing && !self.pairing {
                self.listener?.cancel()
                self.listener = nil
                self.listening = false
                self.updateHeartbeat()
            }
            self.reconcileCapture()
        }
        client.peer.start()
    }

    private func receive(_ control: Control, from client: Viewer) {
        switch (client.phase, control) {
        case (.hello, .hello):
            let challenge = Authentication.challenge()
            client.phase = .proof(challenge)
            client.peer.control(.challenge(challenge))
        case (.proof(let challenge), .identify(let key, let signature, let name)):
            guard Authentication.verify(key: key, signature: signature, name: name, challenge: challenge),
                  Authentication.deviceName(name) == name else {
                deny(client, "The Mac could not verify the device’s identity.")
                return
            }
            client.name = name
            client.key = key
            if phones.contains(where: { $0.key == key }) {
                authorize(client)
            } else if client.canPair && pairing && Date.now.timeIntervalSince(lastPairAttempt) >= 5 {
                lastPairAttempt = .now
                let token = PairingCode()
                client.phase = .code(token)
                client.expires = token.expires
                code = token.value
                codeExpires = token.expires
                client.peer.control(.codeRequired)
            } else {
                let reason = client.canPair ? "Enable pairing on the Mac, wait five seconds, then try again."
                    : "Pair with this Mac on the same Wi-Fi before connecting over the internet."
                deny(client, reason)
            }
        case (.code(var token), .pair(let candidate)):
            switch token.validate(candidate) {
            case .accepted:
                code = nil
                codeExpires = nil
                approval = client.name
                client.phase = .approval
                client.expires = Date.now.addingTimeInterval(60)
                client.peer.control(.awaitingApproval)
            case .incorrect:
                client.phase = .code(token)
                client.peer.control(.codeRequired)
            case .expired:
                deny(client, "The pairing code expired.")
            case .exhausted:
                deny(client, "Too many incorrect pairing codes. Reconnect to try again.")
            }
        case (.authorized, .start):
            guard sharing else {
                client.peer.control(.paused("Turn on sharing in Relay on the Mac."))
                return
            }
            if client.accessGranted || autoAllow {
                client.accessGranted = true
                client.viewing = true
                client.generation = nil
                client.needsKeyframe = true
                if !paused { capture?.keyframe() }
                if paused { client.peer.control(.paused("The Mac paused sharing.")) }
                reconcileCapture()
            } else {
                accessRequest = client.name
                client.peer.control(.paused("Approve viewing on the Mac."))
            }
        case (.authorized, .stop):
            client.viewing = false
            client.needsKeyframe = true
            accessRequest = nil
            reconcileCapture()
        case (.authorized, .quality(let value)) where client.accessGranted:
            setQuality(value)
        case (.authorized, .display(let id)) where client.accessGranted:
            choose(id)
        case (.authorized, .keyframe):
            client.needsKeyframe = true
            if client.viewing { capture?.keyframe() }
        case (.authorized, .receipt(let sequence)):
            if let index = client.framesInFlight.firstIndex(of: sequence) { client.framesInFlight.remove(at: index) }
        case (.authorized, .ping(let tick)):
            client.peer.control(.pong(sent: tick, remote: RelayProtocol.clock))
        case (.closing, _):
            return
        default:
            deny(client, RelayError.protocolViolation.localizedDescription)
        }
    }

    private func deny(_ client: Viewer, _ reason: String) {
        client.phase = .closing
        client.viewing = false
        client.expires = Date.now.addingTimeInterval(2)
        reconcileCapture()
        if !client.peer.send(.control(.denied(reason)), completion: { [weak client] in client?.peer.finish(reason) }) {
            client.peer.finish(reason)
        }
    }

    private func authorize(_ client: Viewer) {
        client.phase = .authorized
        viewerName = client.name
        client.peer.control(.authorized(name: name, tunnel: relayInvite))
        catalog()
    }

    private func catalog() {
        if let viewer, case .authorized = viewer.phase {
            viewer.peer.control(.catalog(displays: displays, selected: selected, quality: effective))
        }
    }

    private func reconcileCapture() {
        let sending = sharing && !paused && viewer?.viewing == true
        if !sending { streaming = false }
        if !previewing {
            preview.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            previewSamples = VideoSamples()
        }
        let device = displays.first { $0.id == selected }
        let desired = permission && (previewing || sending) ? device : nil
        let signature = desired.map { CaptureSignature(display: $0, quality: effective) }
        guard captureSignature != signature else { return }
        captureSignature = signature
        let token = UUID()
        revision = token
        captureFrames?.cancel()
        captureFrames = nil
        let priorLifecycle = captureLifecycle
        let prior = capture
        capture = nil
        stats = nil
        lastDropCount = 0
        congestedIntervals = 0
        healthyIntervals = 0
        viewer?.needsKeyframe = true
        viewer?.lastFrame = nil
        viewer?.generation = nil
        captureLifecycle = Task { [weak self] in
            await priorLifecycle?.value
            await prior?.stop()
            guard let self, self.revision == token, let desired else { return }
            let (frames, output) = AsyncStream.makeStream(of: EncodedVideo.self, bufferingPolicy: .bufferingNewest(1))
            do {
                let device = try await CaptureDevice.open(desired)
                guard self.revision == token else { return }
                let engine = try DisplayCapture(device: device, quality: self.effective, delivery: output) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.revision == token else { return }
                        self.captureFailed(message)
                    }
                }
                self.capture = engine
                try await engine.start()
                guard self.revision == token else { return }
                self.captureFrames = Task { [weak self] in
                    for await video in frames {
                        guard let self, self.revision == token, !Task.isCancelled else { return }
                        self.deliver(video)
                    }
                }
            } catch {
                guard self.revision == token else { return }
                self.captureFailed(error.localizedDescription)
            }
        }
    }

    private func captureFailed(_ reason: String) {
        error = reason
        previewing = false
        updateHeartbeat()
        checkPermission()
        if let viewer {
            viewer.viewing = false
            viewer.peer.control(.paused(reason))
        }
        reconcileCapture()
    }

    private func deliver(_ video: EncodedVideo) {
        if previewing {
            let renderer = preview.sampleBufferRenderer
            if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
                renderer.flush()
                previewSamples.resetSequence()
            }
            do {
                if let config = video.config {
                    if previewSamples.config?.generation != config.generation { renderer.flush() }
                    try previewSamples.configure(config)
                }
                if renderer.isReadyForMoreMediaData, let sample = try previewSamples.make(video.frame) { renderer.enqueue(sample) }
            } catch {
                previewSamples.resetSequence()
            }
        }

        guard sharing, !paused, let viewer, viewer.viewing else { return }
        let frame = video.frame
        let now = RelayProtocol.clock
        if now > frame.timestampMicros, now - frame.timestampMicros > 180_000 {
            lastDropCount += 1
            viewer.needsKeyframe = true
            capture?.keyframe()
            return
        }
        let continuous = viewer.lastFrame.map { $0 &+ 1 == frame.sequence } == true
        if viewer.peer.videoPending || viewer.framesInFlight.count >= 3 {
            lastDropCount += 1
            viewer.needsKeyframe = true
            return
        }
        if viewer.needsKeyframe || !continuous {
            guard frame.keyframe, let config = video.config else {
                viewer.needsKeyframe = true
                capture?.keyframe()
                return
            }
            if viewer.generation != config.generation {
                guard viewer.peer.send(.control(.config(config))) else { return }
                viewer.generation = config.generation
            }
        }
        guard viewer.peer.send(.video(frame)) else {
            viewer.needsKeyframe = true
            return
        }
        viewer.lastFrame = frame.sequence
        viewer.framesInFlight.append(frame.sequence)
        streaming = true
    }

    private func tick() async {
        if sharing || previewing { checkPermission() }
        if let viewer {
            if case .authorized = viewer.phase {
                if ProcessInfo.processInfo.systemUptime - viewer.peer.lastReceived > 9 { viewer.peer.finish("The viewer stopped responding.") }
            } else if Date.now >= viewer.expires {
                if case .closing = viewer.phase { viewer.peer.finish() }
                else { deny(viewer, "The pairing or authentication session expired.") }
            }
        }
        guard let capture else { return }
        let reading = await capture.stats()
        guard self.capture === capture else { return }
        let stats = StreamStats(captured: reading.captured, encoded: reading.encoded,
                                dropped: reading.dropped + lastDropCount, bitrate: reading.bitrate)
        self.stats = stats
        if let viewer, viewer.viewing {
            viewer.peer.control(.stats(stats))
            if lastDropCount > max(3, reading.encoded / 5) {
                congestedIntervals += 1
                healthyIntervals = 0
                if congestedIntervals == 1 { capture.bitrate(effective.bitrate * 2 / 3) }
                if congestedIntervals >= 3, let lower = effective.lower {
                    effective = lower
                    catalog()
                    reconcileCapture()
                }
            } else {
                congestedIntervals = 0
                healthyIntervals += 1
                if healthyIntervals == 8 { capture.bitrate(effective.bitrate) }
                if healthyIntervals >= 25, effective != quality,
                   let index = Quality.allCases.firstIndex(of: effective),
                   Quality.allCases.indices.contains(index + 1) {
                    effective = Quality.allCases[index + 1]
                    catalog()
                    reconcileCapture()
                }
            }
        }
        lastDropCount = 0
    }
}
