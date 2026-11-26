import AVFoundation
import Network
import RelayCore
import SwiftUI

struct NearbyMac: Identifiable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

struct TrustedMac: Identifiable, Codable {
    var name: String
    var service: String?
    var address: String?
    let pin: IdentityPin
    var tunnel: RelayInvite?
    var lastConnected: Date
    var id: IdentityPin { pin }
}

@MainActor
final class PhoneModel: ObservableObject {
    enum Phase: Equatable {
        case connecting, authenticating, code, approval, starting, live, paused, reconnecting, failed
    }

    @Published private(set) var nearby: [NearbyMac] = []
    @Published private(set) var trusted: [TrustedMac] = []
    @Published private(set) var discoveryIssue: String?
    @Published private(set) var searching = false
    @Published private(set) var sessionOpen = false
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var detail = ""
    @Published private(set) var name = "Mac"
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var selected: UInt32?
    @Published private(set) var quality: Quality = .balanced
    @Published private(set) var stats: StreamStats?
    @Published private(set) var decoded = 0
    @Published private(set) var rtt: Double?
    @Published private(set) var latency: Double?
    @Published private(set) var aspect: CGFloat = 16 / 9
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var authorized = false
    @Published private(set) var isPaused = false
    @Published var pendingLink: PairLink?
    @Published var showStats = UserDefaults.standard.bool(forKey: "showStats") {
        didSet { UserDefaults.standard.set(showStats, forKey: "showStats") }
    }

    struct PairLink: Identifiable {
        let service: String
        let pin: IdentityPin
        var id: String { service }
    }

    struct Target {
        var name: String
        var service: String?
        var address: String?
        var tunnel: RelayInvite?
        let pin: IdentityPin
    }

    let layer = AVSampleBufferDisplayLayer()
    private var browser: NWBrowser?
    private var peer: Peer?
    private var target: Target?
    private var decoder: DecodePipeline?
    private var decodeTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var foreground = false
    private var stageDeadline = Date.distantPast
    private var lastImage = Date.distantPast
    private var remotePaused = false
    private var frames = 0
    private var attempts = 0
    private var pendingRoutes: [NWEndpoint] = []
    private var reachedServer = false
    private var attemptedTunnel = false
    private var loopback: NWListener?
    private var tunnel: RelayTunnel?
    private var lastPing: UInt64?
    private var clockOffset: Double?

    init() {
        layer.videoGravity = .resizeAspect
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            loadTrust()
            browse()
            if sessionOpen && phase == .reconnecting && peer == nil { scheduleRetry() }
        } else {
            browser?.cancel()
            browser = nil
            nearby = []
            retry?.cancel()
            timer?.cancel()
            closePeer()
            if sessionOpen {
                authorized = false
                update(.reconnecting, "Relay reconnects when you return.")
            }
        }
    }

    func browse() {
        guard browser == nil else { return }
        discoveryIssue = nil
        searching = true
        let browser = NWBrowser(for: .bonjour(type: RelayProtocol.service, domain: "local."), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                self.nearby = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return NearbyMac(name: name, endpoint: result.endpoint)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                switch state {
                case .ready:
                    self.searching = false
                    self.discoveryIssue = nil
                case .waiting(let error), .failed(let error):
                    self.searching = false
                    if case .dns(-65570) = error {
                        self.discoveryIssue = "Allow Relay in Settings → Privacy & Security → Local Network."
                    } else {
                        self.discoveryIssue = "Discovery unavailable. \(error.localizedDescription)"
                    }
                default: break
                }
            }
        }
        browser.start(queue: .main)
    }

    func connect(_ mac: TrustedMac) {
        open(Target(name: mac.name, service: mac.service, address: mac.address, tunnel: mac.tunnel, pin: mac.pin))
    }

    func connectService(_ service: String, pin: IdentityPin) {
        open(Target(name: service, service: service, address: nil, tunnel: nil, pin: pin))
    }

    func connectManual(_ address: String, pin: IdentityPin) {
        guard let host = RemoteAddress.validated(address) else { return }
        open(Target(name: host, service: nil, address: host, tunnel: nil, pin: pin))
    }

    func updateAddress(for mac: TrustedMac, to input: String) {
        var stored = trusted
        guard let index = stored.firstIndex(where: { $0.id == mac.id }) else { return }
        stored[index].address = RemoteAddress.validated(input)
        do { try saveTrust(stored) }
        catch { discoveryIssue = error.localizedDescription }
    }

    func receiveLink(_ url: URL) {
        guard url.scheme == "relay-screen", url.host == "pair",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let service = parts.queryItems?.first(where: { $0.name == "service" })?.value,
              (1...63).contains(service.utf8.count),
              let pin = parts.queryItems?.first(where: { $0.name == "pin" })?.value.flatMap(IdentityPin.init) else { return }
        pendingLink = PairLink(service: service, pin: pin)
    }

    func submit(_ code: String) {
        guard phase == .code, code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        update(.authenticating, "Checking the pairing code…")
        peer?.control(.pair(code))
    }

    func togglePause() {
        guard authorized else { return }
        if remotePaused && !isPaused {
            stageDeadline = .now.addingTimeInterval(12)
            update(.starting, "Requesting the stream…")
            peer?.control(.start)
            return
        }
        isPaused.toggle()
        if isPaused {
            peer?.control(.stop)
            update(.paused, "Viewing paused.")
        } else {
            stageDeadline = .now.addingTimeInterval(12)
            update(.starting, "Starting the stream…")
            peer?.control(.start)
        }
    }

    func choose(_ display: UInt32) { peer?.control(.display(display)) }
    func choose(_ quality: Quality) { peer?.control(.quality(quality)) }

    func disconnect() {
        retry?.cancel()
        timer?.cancel()
        closePeer()
        target = nil
        pendingRoutes = []
        sessionOpen = false
        authorized = false
        isPaused = false
        displays = []
        stats = nil
    }

    func forget(_ mac: TrustedMac) {
        do {
            try saveTrust(trusted.filter { $0.id != mac.id })
        } catch {
            discoveryIssue = error.localizedDescription
        }
    }

    func isNearby(_ mac: TrustedMac) -> Bool {
        mac.service.map { name in nearby.contains { $0.name == name } } ?? false
    }

    private func open(_ target: Target) {
        disconnect()
        self.target = target
        name = target.name
        attempts = 0
        sessionOpen = true
        establish()
    }

    private func establish() {
        guard let target, foreground else { return }
        authorized = false
        let discovered = target.service.flatMap { service in nearby.first { $0.name == service }?.endpoint }
        attemptedTunnel = false
        let service = target.tunnel == nil || discovered != nil ? target.service : nil
        pendingRoutes = RemoteAddress.routes(service: service, discovered: discovered, addresses: [target.address])
        connectNextRoute()
    }

    private func connectNextRoute() {
        guard let target, foreground else { return }
        if pendingRoutes.isEmpty {
            if let invite = target.tunnel, !attemptedTunnel { connectOverInternet(invite, pin: target.pin) }
            else { fail("No address is saved for this Mac.") }
            return
        }
        let endpoint = pendingRoutes.removeFirst()
        let hasFallback = !pendingRoutes.isEmpty || target.tunnel != nil
        startPeer(to: endpoint, pin: target.pin, timeout: hasFallback ? 4 : 10, internet: false)
    }

    private func connectOverInternet(_ invite: RelayInvite, pin: IdentityPin) {
        attemptedTunnel = true
        do {
            let listener = try RelayLoopback.listener(using: .tcp)
            loopback = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.loopback === listener, self.tunnel == nil else {
                        connection.cancel()
                        return
                    }
                    do {
                        let tunnel = try RelayTunnel(invite: invite, tcp: connection)
                        self.tunnel = tunnel
                        tunnel.onFinish = { [weak self] in
                            self?.interrupted("Internet relay could not reach the Mac. Check that sharing is on.")
                        }
                        tunnel.start()
                    } catch {
                        connection.cancel()
                        self.interrupted(error.localizedDescription)
                    }
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.loopback === listener else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            self.startPeer(to: RelayLoopback.endpoint(port), pin: pin, timeout: 10, internet: true)
                        }
                    case .failed(let error):
                        self.interrupted(error.localizedDescription)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        } catch {
            interrupted(error.localizedDescription)
        }
    }

    private func startPeer(to endpoint: NWEndpoint, pin: IdentityPin, timeout: Double, internet: Bool) {
        reachedServer = false
        let detail = internet ? "Connecting to \(name) over the internet…" : "Connecting securely to \(name)…"
        update(attempts == 0 ? .connecting : .reconnecting, detail)
        stageDeadline = .now.addingTimeInterval(timeout)
        let current = Peer(NWConnection(to: endpoint, using: Transport.client(pin)))
        peer = current
        current.onReady = { [weak self, weak current] in
            guard let self, let current, self.peer === current else { return }
            self.reachedServer = true
            self.pendingRoutes = []
            self.update(.authenticating, "Verifying device identity…")
            self.stageDeadline = .now.addingTimeInterval(10)
            current.control(.hello)
        }
        current.onWaiting = { [weak self] reason in self?.detail = reason }
        current.onClose = { [weak self, weak current] reason in
            guard let self, let current, self.peer === current else { return }
            self.interrupted(reason)
        }
        current.onPacket = { [weak self, weak current] packet in
            guard let self, let current, self.peer === current else { return }
            self.receive(packet, peer: current)
        }
        current.start()
        timer?.cancel()
        timer = Task { [weak self, weak current] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let current, self.peer === current else { return }
                self.tick(current)
            }
        }
    }

    private func receive(_ packet: Packet, peer: Peer) {
        switch packet {
        case .video(let frame):
            guard authorized, let decoder, !isPaused, !remotePaused else {
                peer.control(.receipt(frame.sequence))
                return
            }
            decoder.decode(frame) { [weak peer] in
                Task { @MainActor in peer?.control(.receipt(frame.sequence)) }
            }
        case .control(let control):
            receive(control, peer: peer)
        }
    }

    private func receive(_ control: Control, peer: Peer) {
        switch control {
        case .challenge(let challenge) where phase == .authenticating && !authorized:
            guard challenge.count == 32 else { fail(RelayError.protocolViolation.localizedDescription); return }
            do {
                let key = try Authentication.phoneKey()
                let name = Authentication.deviceName(UIDevice.current.name)
                let signature = try key.signature(for: Authentication.signedMessage(challenge: challenge, name: name))
                peer.control(.identify(key: key.publicKey.x963Representation, signature: signature.rawRepresentation, name: name))
            } catch {
                fail(error.localizedDescription)
            }
        case .codeRequired where !authorized:
            let retrying = detail == "Checking the pairing code…"
            update(.code, retrying ? "Incorrect code. Check Relay on the Mac and try again." : "Enter the six-digit code displayed in Relay on your Mac.")
            if !retrying { stageDeadline = .now.addingTimeInterval(120) }
        case .awaitingApproval where !authorized:
            update(.approval, "Approve this device in Relay on the Mac.")
            stageDeadline = .now.addingTimeInterval(61)
        case .authorized(let remoteName, let advertisedTunnel) where !authorized:
            guard var target else { return }
            do {
                let previous = trusted.first { $0.pin == target.pin }
                target.service = target.service ?? previous?.service
                target.address = target.address ?? previous?.address
                if let advertisedTunnel {
                    target.tunnel = RelayInvite(service: advertisedTunnel.service, room: advertisedTunnel.room)
                } else if !attemptedTunnel {
                    target.tunnel = nil
                }
                self.target = target
                let mac = TrustedMac(name: Authentication.deviceName(remoteName), service: target.service,
                                     address: target.address, pin: target.pin, tunnel: target.tunnel,
                                     lastConnected: .now)
                try saveTrust(trusted.filter { $0.id != mac.id } + [mac])
                name = mac.name
                authorized = true
                peer.allowsVideo = true
                attempts = 0
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if isPaused {
                    update(.paused, "Viewing paused.")
                } else {
                    update(.starting, "Waiting for the first frame…")
                    stageDeadline = .now.addingTimeInterval(15)
                    peer.control(.start)
                }
            } catch {
                fail(error.localizedDescription)
            }
        case .denied(let reason):
            fail(reason)
        case .catalog(let displays, let selected, let quality) where authorized:
            guard displays.count <= 32, displays.allSatisfy({ (1...16384).contains($0.width) && (1...16384).contains($0.height) }) else {
                fail(RelayError.protocolViolation.localizedDescription)
                return
            }
            self.displays = displays
            self.selected = selected
            self.quality = quality
        case .config(let config) where authorized:
            remotePaused = false
            aspect = CGFloat(config.width) / CGFloat(max(1, config.height))
            sourceSize = CGSize(width: config.width, height: config.height)
            if decoder == nil { startDecoder() }
            decoder?.configure(config)
        case .paused(let reason) where authorized:
            remotePaused = true
            update(.paused, reason)
        case .stats(let stats) where authorized:
            self.stats = stats
        case .pong(let sent, let remote) where authorized:
            let now = RelayProtocol.clock
            guard sent == lastPing, now >= sent else { return }
            let roundTrip = Double(now - sent)
            rtt = roundTrip / 1_000
            clockOffset = Double(remote) - (Double(sent) + roundTrip / 2)
        default:
            fail(RelayError.protocolViolation.localizedDescription)
        }
    }

    private func startDecoder() {
        let decoder = DecodePipeline()
        self.decoder = decoder
        decodeTask = Task { [weak self] in
            for await output in decoder.output {
                guard let self, self.decoder === decoder, !Task.isCancelled else { return }
                switch output {
                case .image(let sample, let timestamp):
                    self.show(sample, timestamp: timestamp)
                case .needsKeyframe:
                    self.peer?.control(.keyframe)
                case .failed(let reason):
                    self.fail(reason)
                }
            }
        }
    }

    private func show(_ sample: CMSampleBuffer, timestamp: UInt64) {
        guard authorized, !isPaused, !remotePaused else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sample)
        if phase != .live {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            update(.live, "")
        }
        lastImage = .now
        frames += 1
        if let clockOffset {
            let result = (Double(RelayProtocol.clock) + clockOffset - Double(timestamp)) / 1_000
            latency = max(0, result)
        }
    }

    private func tick(_ current: Peer) {
        if authorized {
            let now = RelayProtocol.clock
            lastPing = now
            current.control(.ping(now))
            decoded = frames
            frames = 0
            if ProcessInfo.processInfo.systemUptime - current.lastReceived > 8 {
                interrupted("The Mac stopped responding.")
            } else if phase == .live && Date.now.timeIntervalSince(lastImage) > 3 {
                stageDeadline = .now.addingTimeInterval(10)
                update(.starting, "Waiting for a fresh frame. The last frame is frozen.")
                current.control(.keyframe)
            } else if phase == .starting && Date.now > stageDeadline {
                interrupted("No fresh video arrived.")
            }
        } else if Date.now > stageDeadline {
            interrupted(detail.contains("Local Network") ? detail : RelayError.timeout.localizedDescription)
        }
    }

    private func interrupted(_ reason: String) {
        let paired = target.map { target in trusted.contains { $0.pin == target.pin } } ?? false
        closePeer()
        authorized = false
        if !reachedServer && foreground && (!pendingRoutes.isEmpty || (!attemptedTunnel && target?.tunnel != nil)) {
            connectNextRoute()
        } else if paired && foreground && attempts < 6 {
            update(.reconnecting, reason)
            scheduleRetry()
        } else {
            if paired && !reachedServer && target?.address == nil && target?.tunnel == nil {
                fail("Could not reach this Mac on Wi-Fi. For internet viewing, set up an internet relay on the Mac, then connect once on the same Wi-Fi.")
            } else {
                fail(reason)
            }
        }
    }

    private func scheduleRetry() {
        guard foreground else { return }
        retry?.cancel()
        let delay = min(16, 1 << attempts)
        attempts += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.establish()
        }
    }

    private func closePeer() {
        let current = peer
        peer = nil
        current?.finish()
        loopback?.cancel()
        loopback = nil
        tunnel?.onFinish = nil
        tunnel?.stop()
        tunnel = nil
        decodeTask?.cancel()
        decodeTask = nil
        decoder?.close()
        decoder = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        decoded = 0
        frames = 0
        remotePaused = false
        rtt = nil
        latency = nil
        clockOffset = nil
    }

    private func fail(_ reason: String) {
        retry?.cancel()
        timer?.cancel()
        closePeer()
        authorized = false
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        update(.failed, reason)
    }

    private func update(_ phase: Phase, _ detail: String) {
        self.phase = phase
        self.detail = detail
    }

    private func loadTrust() {
        do {
            if let data = try SecureStore.load("trusted-macs") {
                trusted = try JSONDecoder().decode([TrustedMac].self, from: data)
            }
        } catch {
            discoveryIssue = error.localizedDescription
        }
    }

    private func saveTrust(_ trusted: [TrustedMac]) throws {
        guard trusted.count <= 64 else { throw RelayError.message("Forget a paired Mac before adding another.") }
        try SecureStore.save(JSONEncoder().encode(trusted), as: "trusted-macs")
        self.trusted = trusted
    }
}
