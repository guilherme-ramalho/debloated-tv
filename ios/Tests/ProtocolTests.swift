import XCTest
import Security
import CryptoKit
@testable import TVRemoteCore

final class ProtocolTests: XCTestCase {
    func testWakeIntentExpiresAndCannotReplay() {
        var request = WakeRequest()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(request.consume(powerIsOn: false, now: start))
        request.begin(now: start)
        XCTAssertEqual(request.consume(powerIsOn: false, now: start.addingTimeInterval(29)), .power)
        XCTAssertNil(request.consume(powerIsOn: false, now: start.addingTimeInterval(29)))
        request.begin(now: start)
        XCTAssertNil(request.consume(powerIsOn: false, now: start.addingTimeInterval(30)))
        request.begin(now: start)
        request.cancel()
        XCTAssertNil(request.consume(powerIsOn: false, now: start))
        request.begin(now: start)
        XCTAssertNil(request.consume(powerIsOn: true, now: start))
        XCTAssertNil(request.consume(powerIsOn: false, now: start))
        XCTAssertEqual(TVKey.power.rawValue, 26)
    }
    func testVarintsIncludingMaximum() throws {
        for value: UInt64 in [0, 127, 128, 16384, UInt64.max] {
            var offset = 0
            XCTAssertEqual(try Wire.readVarint(Array(Wire.varint(value)), &offset), value)
        }
        var offset = 0
        XCTAssertThrowsError(try Wire.readVarint([UInt8](repeating: 255, count: 10), &offset))
    }
    func testSplitPrefixAndCoalescedFrames() throws {
        let payload = Data(repeating: 42, count: 300)
        let packet = Wire.varint(UInt64(payload.count)) + payload
        var decoder = FrameDecoder()
        XCTAssertTrue(try decoder.append(packet.prefix(1)).isEmpty)
        XCTAssertTrue(try decoder.append(packet.dropFirst().prefix(15)).isEmpty)
        XCTAssertEqual(try decoder.append(packet.dropFirst(16) + packet), [payload, payload])
    }
    func testEveryFragmentBoundary() throws {
        let packet = Wire.bytes(10, Wire.int(1, TVKey.up.rawValue) + Wire.int(2, 3))
        let frame = Wire.varint(UInt64(packet.count)) + packet
        for offset in 0...frame.count {
            var decoder = FrameDecoder()
            let a = try decoder.append(frame.prefix(offset))
            let b = try decoder.append(frame.dropFirst(offset))
            XCTAssertEqual(a + b, [packet])
        }
    }
    func testFrameSizeAndTruncationChecks() throws {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Wire.varint(65537)))
        XCTAssertThrowsError(try Wire.fields(Data([0x0a, 0x05, 0x01])))
        XCTAssertThrowsError(try Wire.fields(Data([0])))
    }
    func testNestedProtocolFields() throws {
        let data = Wire.bytes(10, Wire.int(1, 24) + Wire.int(2, 3)) + Wire.int(2, 200)
        let fields = try Wire.fields(data)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(try Wire.number(1, in: fields[0].bytes!), 24)
        XCTAssertEqual(try Wire.number(2, in: data), 200)
    }
    private func key() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let options: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        guard let key = SecKeyCreateRandomKey(options as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }
    func testGeneratedCertificateMatchesItsPrivateKey() throws {
        let privateKey = try key()
        let data = try ClientIdentity.certificate(privateKey: privateKey)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        let certificateKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        XCTAssertEqual(try ClientIdentity.components(certificateKey), try ClientIdentity.components(SecKeyCopyPublicKey(privateKey)!))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Personal TV Remote")
    }
    func testPairingSecretBindsCodeToBothKeys() throws {
        let client = SecKeyCopyPublicKey(try key())!
        let server = SecKeyCopyPublicKey(try key())!
        let expected = Data(SHA256.hash(data: try ClientIdentity.components(client) + ClientIdentity.components(server) + Data([0x12, 0x34])))
        let code = String(format: "%02X1234", expected.first!)
        XCTAssertEqual(try ClientIdentity.secret(code: code, client: client, server: server), expected)
        let wrong = String(format: "%02X1234", expected.first! ^ 255)
        XCTAssertThrowsError(try ClientIdentity.secret(code: wrong, client: client, server: server))
        XCTAssertThrowsError(try ClientIdentity.secret(code: "ZZ0000", client: client, server: server))
    }
}
