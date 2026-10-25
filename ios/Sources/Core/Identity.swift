import Foundation
import Security
import CryptoKit

enum DER {
    static func item(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 { length.append(UInt8(content.count)) }
        else {
            var count = content.count, encoded = [UInt8]()
            while count > 0 { encoded.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(UInt8(128 + encoded.count)); length.append(contentsOf: encoded)
        }
        return Data([tag]) + length + content
    }
    static func sequence(_ data: Data) -> Data { item(0x30, data) }
    static func integer(_ data: Data) -> Data {
        var bytes = data
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 128 != 0 { bytes.insert(0, at: 0) }
        return item(2, bytes)
    }
    static let rsa = sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]))
    static let sha256RSA = sequence(Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00]))
    static func read(_ bytes: [UInt8], _ offset: inout Int) throws -> (UInt8, Data) {
        guard offset + 2 <= bytes.count else { throw RemoteFailure.message("Invalid certificate") }
        let tag = bytes[offset]; offset += 1
        var length = Int(bytes[offset]); offset += 1
        if length & 128 != 0 {
            let count = length & 127
            guard count > 0 && count <= 4 && offset + count <= bytes.count else { throw RemoteFailure.message("Invalid certificate length") }
            length = 0
            for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
        }
        guard length <= bytes.count - offset else { throw RemoteFailure.message("Truncated certificate") }
        defer { offset += length }
        return (tag, Data(bytes[offset..<offset + length]))
    }
}

public struct ClientIdentity {
    public let identity: SecIdentity
    public let publicKey: SecKey
    private static let label = "PersonalTVRemote.Client.v1"
    private static let tag = Data("com.guilhermeramalho.TVRemote.client.v1".utf8)

    public static func loadOrCreate() throws -> ClientIdentity {
        var existing: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess, let existing {
            return try material(existing as! SecIdentity)
        }
        var foundKey: CFTypeRef?
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true]
        let key: SecKey
        if SecItemCopyMatching(keyQuery as CFDictionary, &foundKey) == errSecSuccess, let foundKey {
            key = foundKey as! SecKey
        } else {
            var error: Unmanaged<CFError>?
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048,
                kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: tag, kSecAttrLabel as String: label,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]]
            guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw error?.takeRetainedValue() as Error? ?? RemoteFailure.message("Could not create pairing identity")
            }
            key = generated
        }
        let encoded = try certificate(privateKey: key)
        guard let certificate = SecCertificateCreateWithData(nil, encoded as CFData) else {
            throw RemoteFailure.message("Could not create client certificate")
        }
        let add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate,
            kSecAttrLabel as String: label]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw RemoteFailure.message("Could not save pairing certificate (\(status))") }
        existing = nil
        guard SecItemCopyMatching(query as CFDictionary, &existing) == errSecSuccess, let existing else {
            throw RemoteFailure.message("Could not load saved pairing identity")
        }
        return try material(existing as! SecIdentity)
    }

    public static func material(_ identity: SecIdentity) throws -> ClientIdentity {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate, let publicKey = SecCertificateCopyKey(certificate) else {
            throw RemoteFailure.message("Invalid client identity")
        }
        return ClientIdentity(identity: identity, publicKey: publicKey)
    }

    public static func certificate(privateKey key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw RemoteFailure.message("Could not export public key")
        }
        let name = DER.sequence(DER.item(0x31, DER.sequence(Data([0x06,0x03,0x55,0x04,0x03])
            + DER.item(0x0c, Data("Personal TV Remote".utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let now = Date()
        let validity = DER.sequence(DER.item(0x18, Data(formatter.string(from: now.addingTimeInterval(-86400)).utf8))
            + DER.item(0x18, Data(formatter.string(from: now.addingTimeInterval(10 * 365 * 86400)).utf8)))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw RemoteFailure.message("Could not create certificate serial")
        }
        let body = DER.sequence(DER.item(0xa0, DER.integer(Data([2]))) + DER.integer(Data(serial))
            + DER.sha256RSA + name + validity + name
            + DER.sequence(DER.rsa + DER.item(3, Data([0]) + publicData)))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, body as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() as Error? ?? RemoteFailure.message("Could not sign client certificate")
        }
        return DER.sequence(body + DER.sha256RSA + DER.item(3, Data([0]) + signature))
    }

    public static func components(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw RemoteFailure.message("Invalid RSA public key") }
        var offset = 0
        let sequence = try DER.read(Array(raw), &offset)
        guard sequence.0 == 0x30 else { throw RemoteFailure.message("Pairing requires RSA keys") }
        var position = 0, result = Data()
        for _ in 0..<2 {
            let value = try DER.read(Array(sequence.1), &position)
            guard value.0 == 2 else { throw RemoteFailure.message("Invalid RSA component") }
            var unsigned = value.1
            while unsigned.count > 1 && unsigned.first == 0 { unsigned.removeFirst() }
            result.append(unsigned)
        }
        return result
    }

    public static func secret(code: String, client: SecKey, server: SecKey) throws -> Data {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6 else { throw RemoteFailure.message("Enter the six-character code shown on the TV") }
        var bytes = [UInt8]()
        let characters = Array(code)
        for i in stride(from: 0, to: 6, by: 2) {
            guard let byte = UInt8(String(characters[i...i + 1]), radix: 16) else { throw RemoteFailure.message("The code uses 0–9 and A–F") }
            bytes.append(byte)
        }
        let digest = Data(SHA256.hash(data: try components(client) + components(server) + Data(bytes.suffix(2))))
        guard digest.first == bytes.first else { throw RemoteFailure.message("That code does not match this TV. Check the code and try again.") }
        return digest
    }
}
