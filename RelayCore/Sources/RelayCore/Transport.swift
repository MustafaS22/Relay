import Foundation
import Network
import Security

public enum Transport {
    public static func server(_ identity: ServerIdentity) -> NWParameters {
        let tls = options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
        return parameters(tls)
    }

    public static func client(_ pin: IdentityPin) -> NWParameters {
        let tls = options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first else {
                complete(false)
                return
            }
            complete(IdentityPin(certificate: certificate) == pin)
        }, DispatchQueue(label: "relay.tls.verify"))
        return parameters(tls)
    }

    private static func options() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "relay/1")
        return tls
    }

    private static func parameters(_ tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

@MainActor
public final class Peer {
    public let connection: NWConnection
    public var onReady: (() -> Void)?
    public var onPacket: ((Packet) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onWaiting: ((String) -> Void)?
    public var allowsVideo = false
    public private(set) var videoPending = false
    public private(set) var lastReceived = ProcessInfo.processInfo.systemUptime
    public private(set) var closed = false
    private var pending = 0

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.readHeader()
                case .failed(let error):
                    self.finish(Self.describe(error))
                case .waiting(let error):
                    if case .tls = error {
                        self.finish(Self.describe(error))
                        return
                    }
                    let denied = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                    self.onWaiting?(denied ? "Allow Relay in Settings → Privacy & Security → Local Network." : error.localizedDescription)
                case .cancelled:
                    self.finish(RelayError.disconnected.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    @discardableResult
    public func send(_ packet: Packet, completion: (() -> Void)? = nil) -> Bool {
        guard !closed, pending < 24 else { return false }
        let isVideo: Bool
        if case .video = packet { isVideo = true } else { isVideo = false }
        guard !isVideo || !videoPending, let bytes = try? Wire.encode(packet) else { return false }
        pending += 1
        if isVideo { videoPending = true }
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.pending -= 1
                if isVideo { self.videoPending = false }
                if let error { self.finish(error.localizedDescription) } else { completion?() }
            }
        })
        return true
    }

    public func control(_ control: Control) { _ = send(.control(control)) }

    public func finish(_ reason: String = RelayError.disconnected.localizedDescription) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onPacket = nil
        onClose = nil
        onReady = nil
        onWaiting = nil
    }

    private static func describe(_ error: NWError) -> String {
        if case .tls = error {
            return "Secure connection failed. Verify the Mac’s fingerprint and pair again."
        }
        return error.localizedDescription
    }

    private func readHeader() {
        read(count: Wire.headerSize) { [weak self] data in
            guard let self else { return }
            do {
                let header = try Wire.header(data)
                guard header.kind != 2 || self.allowsVideo else { throw RelayError.protocolViolation }
                self.read(count: header.length) { [weak self] payload in
                    guard let self else { return }
                    do {
                        let packet = try Wire.decode(kind: header.kind, payload: payload)
                        self.lastReceived = ProcessInfo.processInfo.systemUptime
                        self.onPacket?(packet)
                        self.readHeader()
                    } catch {
                        self.finish(RelayError.protocolViolation.localizedDescription)
                    }
                }
            } catch {
                self.finish(RelayError.protocolViolation.localizedDescription)
            }
        }
    }

    private func read(count: Int, completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard let data, data.count == count, error == nil else {
                    self.finish(error?.localizedDescription ?? RelayError.disconnected.localizedDescription)
                    return
                }
                completion(data)
            }
        }
    }
}
