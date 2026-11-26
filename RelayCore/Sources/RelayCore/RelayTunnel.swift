import CryptoKit
import Foundation
import Network

public struct RelayInvite: Codable, Equatable, Sendable {
    public let service: URL
    public let room: String

    public init?(service: URL, room: String) {
        guard let url = Self.serviceURL(service.absoluteString), Self.isSecret(room) else { return nil }
        self.service = url
        self.room = room
    }

    public static func serviceURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "wss"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        parts.scheme = "wss"
        parts.path = ""
        return parts.url
    }

    private static func isSecret(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func makeHost(service: URL) throws -> (RelayInvite, String) {
        let secret: String
        if let data = try SecureStore.load("internet-relay-secret") {
            guard let stored = String(data: data, encoding: .utf8), isSecret(stored) else { throw RelayError.credentials }
            secret = stored
        } else {
            secret = Authentication.challenge().map { String(format: "%02x", $0) }.joined()
            try SecureStore.save(Data(secret.utf8), as: "internet-relay-secret")
        }
        let room = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let invite = Self(service: service, room: room) else { throw RelayError.credentials }
        return (invite, secret)
    }

    func request(hostSecret: String?) throws -> URLRequest {
        guard let url = Self(service: service, room: room)?.service else { throw RelayError.credentials }
        let role = hostSecret == nil ? "viewer" : "host"
        var request = URLRequest(url: url.appendingPathComponent("v1").appendingPathComponent(role).appendingPathComponent(room))
        if let hostSecret { request.setValue("Bearer " + hostSecret, forHTTPHeaderField: "Authorization") }
        return request
    }
}

/// Bridges raw TLS records between a loopback TCP socket and an outbound WebSocket.
@MainActor
public final class RelayTunnel {
    private static let chunkSize = 64 * 1024
    private let socket: URLSessionWebSocketTask
    private let tcp: NWConnection
    private var readTask: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var closed = false
    public var onFinish: (() -> Void)?

    public init(invite: RelayInvite, hostSecret: String? = nil, tcp: NWConnection) throws {
        socket = URLSession.shared.webSocketTask(with: try invite.request(hostSecret: hostSecret))
        socket.maximumMessageSize = Self.chunkSize
        self.tcp = tcp
    }

    public func start() {
        socket.resume()
        readTask = Task { [weak self, socket] in
            do {
                guard case .string("ready") = try await socket.receive(), let self, !self.closed else {
                    self?.stop()
                    return
                }
                self.startTCP()
                while !Task.isCancelled {
                    guard case .data(let bytes) = try await socket.receive(), !bytes.isEmpty else { break }
                    try await self.sendTCP(bytes)
                }
            } catch {}
            self?.stop()
        }
        keepAlive = Task { [weak self, socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        socket.sendPing { error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                } catch {
                    self?.stop()
                    return
                }
            }
        }
    }

    private func startTCP() {
        tcp.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.receiveTCP()
                case .failed, .cancelled: self?.stop()
                default: break
                }
            }
        }
        tcp.start(queue: .main)
    }

    private func sendTCP(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcp.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receiveTCP() {
        guard !closed else { return }
        tcp.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self, socket] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                do {
                    if let bytes, !bytes.isEmpty { try await socket.send(.data(bytes)) }
                    if complete || error != nil { self.stop() }
                    else { self.receiveTCP() }
                } catch { self.stop() }
            }
        }
    }

    public func stop() {
        guard !closed else { return }
        closed = true
        readTask?.cancel()
        keepAlive?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        tcp.stateUpdateHandler = nil
        tcp.cancel()
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

public enum RelayLoopback {
    public static func listener(using parameters: NWParameters) throws -> NWListener {
        parameters.requiredLocalEndpoint = endpoint(.any)
        parameters.acceptLocalOnly = true
        return try NWListener(using: parameters, on: .any)
    }

    public static func endpoint(_ port: NWEndpoint.Port) -> NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: port)
    }
}
