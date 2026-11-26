import CryptoKit
import Foundation
import Security

public struct IdentityPin: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init?(_ text: String) {
        let value = text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = Self(text) else { throw RelayError.credentials }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public init(certificate: SecCertificate) {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        value = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public var grouped: String {
        stride(from: 0, to: 32, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return String(value[start..<value.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

public enum SecureStore {
    private static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mustafas22.relay",
            kSecAttrAccount as String: account
        ]
        #if os(macOS)
        // A Mac build without a provisioning profile uses the login Keychain's app access controls.
        query[kSecUseDataProtectionKeychain as String] = false
        #else
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public static func load(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw failure(status) }
        return data
    }

    public static func save(_ data: Data, as account: String) throws {
        let query = query(account)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var item = query.merging(values) { _, new in new }
        #if !os(macOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    private static func failure(_ status: OSStatus) -> RelayError {
        #if os(macOS)
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            return .message("Relay could not unlock its Keychain item (\(status)). Unlock your login Keychain and try again.")
        }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error."
        return .message("Relay could not access the Keychain (\(status)). \(reason)")
        #else
        .message("Relay could not access the Keychain (\(status)). Run a signed build and unlock the device.")
        #endif
    }
}

public enum Authentication {
    public static func challenge() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func signedMessage(challenge: Data, name: String) -> Data {
        Data("Relay phone identity v1\u{0}".utf8) + challenge + Data(name.utf8)
    }

    public static func verify(key: Data, signature: Data, name: String, challenge: Data) -> Bool {
        guard challenge.count == 32, (1...96).contains(name.utf8.count),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
              let proof = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return publicKey.isValidSignature(proof, for: signedMessage(challenge: challenge, name: name))
    }

    public static func deviceName(_ name: String) -> String {
        let clean = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let limited = String(String.UnicodeScalarView(clean)).prefix(32)
        var result = ""
        for character in limited {
            guard result.utf8.count + String(character).utf8.count <= 96 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Relay device" : result
    }

    public static func phoneKey() throws -> P256.Signing.PrivateKey {
        if let data = try SecureStore.load("phone-signing-key") {
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = P256.Signing.PrivateKey()
        try SecureStore.save(key.rawRepresentation, as: "phone-signing-key")
        return key
    }
}

public struct PairingCode {
    public enum Result: Equatable { case accepted, incorrect, expired, exhausted }
    public let value: String
    public let expires: Date
    public private(set) var remaining = 3

    public init(now: Date = .now) {
        value = String(format: "%06d", Int.random(in: 0...999_999))
        expires = now.addingTimeInterval(120)
    }

    public mutating func validate(_ candidate: String, now: Date = .now) -> Result {
        guard now < expires else { return .expired }
        guard remaining > 0 else { return .exhausted }
        remaining -= 1
        guard candidate == value else { return remaining > 0 ? .incorrect : .exhausted }
        remaining = 0
        return .accepted
    }
}
