import CryptoKit
import Foundation
import Network
import Security
import XCTest
@testable import RelayCore

final class RelayCoreTests: XCTestCase {
    func testControlRoundTrip() throws {
        let bytes = try Wire.encode(.control(.quality(.high)))
        let header = try Wire.header(bytes.prefix(Wire.headerSize))
        XCTAssertEqual(header.length, bytes.count - Wire.headerSize)
        guard case .control(.quality(.high)) = try Wire.decode(kind: header.kind, payload: bytes.dropFirst(Wire.headerSize)) else {
            return XCTFail("Quality changed during serialization")
        }
    }

    func testRemoteAuthorizationKeepsVersionOneCompatible() throws {
        enum LegacyControl: Codable { case authorized(name: String) }
        let oldPayload = try JSONEncoder().encode(LegacyControl.authorized(name: "Mac"))
        guard case .control(.authorized("Mac", nil)) = try Wire.decode(kind: 1, payload: oldPayload) else {
            return XCTFail("Old hosts should decode without a remote address")
        }

        let invite = try XCTUnwrap(RelayInvite(service: URL(string: "https://relay.example.com")!,
                                               room: String(repeating: "a", count: 64)))
        let packet = try Wire.encode(.control(.authorized(name: "Mac", tunnel: invite)))
        let payload = packet.dropFirst(Wire.headerSize)
        guard case .control(.authorized("Mac", let decoded)) = try Wire.decode(kind: 1, payload: payload),
              decoded == invite, case .authorized("Mac") = try JSONDecoder().decode(LegacyControl.self, from: payload) else {
            return XCTFail("The new address must round-trip and be ignored by old viewers")
        }
    }

    func testTrustedViewerPrefersDiscoveryAndFallsBackToSavedAddress() {
        let name = "Mac"
        let nearby = NWEndpoint.service(name: name, type: RelayProtocol.service, domain: "local.", interface: nil)
        let address = NWEndpoint.hostPort(host: "mac.example.local", port: NWEndpoint.Port(rawValue: RelayProtocol.port)!)
        XCTAssertEqual(RemoteAddress.routes(service: name, discovered: nearby, addresses: ["mac.example.local", "MAC.EXAMPLE.LOCAL"]),
                       [nearby, address])
        XCTAssertEqual(RemoteAddress.routes(service: name, discovered: nil, addresses: ["mac.example.local"]), [address])
        XCTAssertEqual(RemoteAddress.routes(service: name, discovered: nil, addresses: [nil]), [nearby])
        XCTAssertEqual(RemoteAddress.validated(" [fd7a:115c:a1e0::1] "), "fd7a:115c:a1e0::1")
        XCTAssertEqual(RemoteAddress.validated("100.64.1.23"), "100.64.1.23")
        for invalid in ["https://mac", "mac:47221", "a..b", "mac/path", "[mac]", " "] {
            XCTAssertNil(RemoteAddress.validated(invalid))
        }
    }

    func testFrameRoundTrip() throws {
        let frame = VideoFrame(sequence: UInt64.max - 1, timestampMicros: 909_988, keyframe: true, bytes: Data([1, 2, 3]))
        let bytes = try Wire.encode(.video(frame))
        let header = try Wire.header(bytes.prefix(Wire.headerSize))
        guard case .video(let received) = try Wire.decode(kind: header.kind, payload: bytes.dropFirst(Wire.headerSize)) else {
            return XCTFail("Expected video")
        }
        XCTAssertEqual(received.sequence, frame.sequence)
        XCTAssertEqual(received.timestampMicros, frame.timestampMicros)
        XCTAssertEqual(received.keyframe, frame.keyframe)
        XCTAssertEqual(received.bytes, frame.bytes)
    }

    func testRejectsOversizeInvalidVersionAndTruncatedVideo() {
        XCTAssertThrowsError(try Wire.header(Data([1, 1, 0, 0, 128, 1])))
        XCTAssertThrowsError(try Wire.header(Data([2, 1, 0, 0, 0, 1])))
        XCTAssertThrowsError(try Wire.header(Data([1, 7, 0, 0, 0, 1])))
        XCTAssertThrowsError(try Wire.decode(kind: 2, payload: Data(count: 17)))
    }

    func testChallengeRejectsReplayWrongNameAndWrongSigner() throws {
        let key = P256.Signing.PrivateKey()
        let challenge = Authentication.challenge()
        let name = "iPhone"
        let proof = try key.signature(for: Authentication.signedMessage(challenge: challenge, name: name)).rawRepresentation
        XCTAssertTrue(Authentication.verify(key: key.publicKey.x963Representation, signature: proof, name: name, challenge: challenge))
        XCTAssertFalse(Authentication.verify(key: key.publicKey.x963Representation, signature: proof, name: name, challenge: Authentication.challenge()))
        XCTAssertFalse(Authentication.verify(key: key.publicKey.x963Representation, signature: proof, name: "Other phone", challenge: challenge))
        XCTAssertFalse(Authentication.verify(key: P256.Signing.PrivateKey().publicKey.x963Representation, signature: proof, name: name, challenge: challenge))
    }

    func testPairingCodeExpiresAndIsSingleUse() {
        let now = Date()
        var token = PairingCode(now: now)
        XCTAssertEqual(token.value.count, 6)
        XCTAssertEqual(token.validate(token.value, now: now), .accepted)
        XCTAssertEqual(token.validate(token.value, now: now), .exhausted)
        token = PairingCode(now: now)
        XCTAssertEqual(token.validate(token.value, now: now.addingTimeInterval(120)), .expired)
    }

    func testPairingAttemptsAreBounded() {
        let now = Date()
        var token = PairingCode(now: now)
        XCTAssertEqual(token.validate("wrong", now: now), .incorrect)
        XCTAssertEqual(token.validate("wrong", now: now), .incorrect)
        XCTAssertEqual(token.validate("wrong", now: now), .exhausted)
        XCTAssertEqual(token.validate(token.value, now: now), .exhausted)
    }

    func testQualityPreservesAspectForPortraitAndUltrawide() {
        let portrait = Quality.balanced.dimensions(width: 1920, height: 2560)
        XCTAssertEqual(portrait.width, 720)
        XCTAssertEqual(portrait.height, 960)
        let ultra = Quality.native.dimensions(width: 6400, height: 1600)
        XCTAssertEqual(ultra.width, 4096)
        XCTAssertEqual(ultra.height, 1024)
        XCTAssertEqual(Quality.high.dimensions(width: 1001, height: 811).width % 2, 0)
    }

    func testPinParsingAndCertificateCreation() throws {
        let identity = try makeIdentity()
        XCTAssertEqual(IdentityPin(identity.pin.grouped), identity.pin)
        XCTAssertNil(IdentityPin("123456"))
        XCTAssertNil(IdentityPin(String(repeating: "z", count: 32)))
    }

    @MainActor
    func testPinnedTLSAndFraming() async throws {
        let identity = try makeIdentity()
        let listener = try RelayLoopback.listener(using: Transport.server(identity))
        let ready = expectation(description: "TLS listener")
        let received = expectation(description: "framed packet over pinned TLS")
        var inbound: Peer?
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                let peer = Peer(connection)
                inbound = peer
                peer.onPacket = { packet in
                    if case .control(.hello) = packet { peer.control(.ping(123)) }
                }
                peer.start()
            }
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .main)
        defer {
            inbound?.finish()
            listener.cancel()
        }
        await fulfillment(of: [ready], timeout: 4)
        guard let port = listener.port else { return XCTFail("Listener has no port") }
        let client = Peer(NWConnection(host: "127.0.0.1", port: port, using: Transport.client(identity.pin)))
        defer { client.finish() }
        client.onReady = { [weak client] in client?.control(.hello) }
        client.onPacket = { packet in
            if case .control(.ping(123)) = packet { received.fulfill() }
        }
        client.onClose = { reason in
            if reason != RelayError.disconnected.localizedDescription { XCTFail(reason) }
        }
        client.start()
        await fulfillment(of: [received], timeout: 5)

        let wrong = try makeIdentity()
        let rejected = expectation(description: "incorrect pin rejected")
        let impostor = Peer(NWConnection(host: "127.0.0.1", port: port, using: Transport.client(wrong.pin)))
        impostor.onReady = { XCTFail("Accepted a mismatched certificate") }
        impostor.onClose = { _ in rejected.fulfill() }
        impostor.start()
        await fulfillment(of: [rejected], timeout: 5)
        impostor.finish()
    }

    private func makeIdentity() throws -> ServerIdentity {
        let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                          kSecAttrKeySizeInBits as String: 256] as [String: Any]
        return try ServerIdentity.make(key: XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil)))
    }
}
