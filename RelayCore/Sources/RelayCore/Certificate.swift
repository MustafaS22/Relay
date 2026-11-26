import Foundation
import Security

public struct ServerIdentity {
    public let identity: SecIdentity
    public let pin: IdentityPin

    public static func load() throws -> ServerIdentity {
        let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                          kSecAttrKeySizeInBits as String: 256] as [String: Any]
        if let data = try SecureStore.load("mac-tls-key"),
           let certificateData = try SecureStore.load("mac-tls-certificate") {
            guard let key = SecKeyCreateWithData(data as CFData, attributes.merging(
                [kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]) { _, value in value } as CFDictionary, nil),
                  let cert = SecCertificateCreateWithData(nil, certificateData as CFData),
                  let identity = SecIdentityCreate(nil, cert, key) else { throw RelayError.credentials }
            return ServerIdentity(identity: identity, pin: IdentityPin(certificate: cert))
        }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let privateData = SecKeyCopyExternalRepresentation(key, nil),
              let result = try? make(key: key) else { throw RelayError.credentials }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(result.identity, &certificate) == errSecSuccess,
              let certificate else { throw RelayError.credentials }
        try SecureStore.save(privateData as Data, as: "mac-tls-key")
        try SecureStore.save(SecCertificateCopyData(certificate) as Data, as: "mac-tls-certificate")
        return result
    }

    static func make(key: SecKey) throws -> ServerIdentity {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) else { throw RelayError.credentials }
        let signatureOID = DER.tag(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let algorithm = DER.sequence(signatureOID)
        let name = DER.sequence(DER.tag(0x31, DER.sequence(
            DER.tag(0x06, Data([0x55, 0x04, 0x03])), DER.tag(0x0C, Data("Relay Local Identity".utf8))
        )))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let now = Date()
        let validity = DER.sequence(
            DER.tag(0x18, Data(formatter.string(from: now.addingTimeInterval(-86_400)).utf8)),
            DER.tag(0x18, Data(formatter.string(from: now.addingTimeInterval(315_360_000)).utf8))
        )
        let publicAlgorithm = DER.sequence(
            DER.tag(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])),
            DER.tag(0x06, Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]))
        )
        let serial = Data([1]) + Authentication.challenge().prefix(15)
        let tbs = DER.sequence(
            DER.tag(0xA0, DER.tag(0x02, Data([2]))), DER.tag(0x02, serial), algorithm,
            name, validity, name, DER.sequence(publicAlgorithm, DER.tag(0x03, Data([0]) + (publicBytes as Data)))
        )
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil),
              let certificate = SecCertificateCreateWithData(nil, DER.sequence(
                  tbs, algorithm, DER.tag(0x03, Data([0]) + (signature as Data))
              ) as CFData),
              let identity = SecIdentityCreate(nil, certificate, key) else { throw RelayError.credentials }
        return ServerIdentity(identity: identity, pin: IdentityPin(certificate: certificate))
    }
}

private enum DER {
    static func sequence(_ values: Data...) -> Data {
        tag(0x30, values.reduce(into: Data()) { $0.append($1) })
    }

    static func tag(_ type: UInt8, _ payload: Data) -> Data {
        var output = Data([type])
        if payload.count < 128 {
            output.append(UInt8(payload.count))
        } else if payload.count < 256 {
            output.append(contentsOf: [0x81, UInt8(payload.count)])
        } else {
            output.append(contentsOf: [0x82, UInt8(payload.count >> 8), UInt8(truncatingIfNeeded: payload.count)])
        }
        output.append(payload)
        return output
    }
}
