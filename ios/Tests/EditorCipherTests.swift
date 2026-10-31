import XCTest
import CryptoKit
@testable import TVRemoteCore

/// The TV launcher's EditorTest checks the same vector (computed independently with Python's cryptography package).
final class EditorCipherTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        var data = Data(); var index = s.startIndex
        while index < s.endIndex { let next = s.index(index, offsetBy: 2); data.append(UInt8(s[index..<next], radix: 16)!); index = next }
        return data
    }
    private func seq(_ start: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8((start + $0) & 255) }) }

    func testKnownAnswerMatchesTheTV() throws {
        let key = seq(0, 32), phone = seq(0xA0, 16), tv = seq(0x10, 16)
        var up = try EditorCipher(sessionKey: key, phoneNonce: phone, tvNonce: tv, info: EditorCipher.phoneToTV)
        let down = try EditorCipher(sessionKey: key, phoneNonce: phone, tvNonce: tv, info: EditorCipher.tvToPhone)
        XCTAssertEqual(up.key.withUnsafeBytes { Data($0) }, hex("808e96a4f5f0966171716166ce7e116430013d94af4bed4d845529c15a0ea928"))
        XCTAssertEqual(down.key.withUnsafeBytes { Data($0) }, hex("95675c6bcf2e89294a67840934b28d17c7f8c0b2c0cec457a6afe1ebba83ce06"))
        _ = try up.seal(Data("{}".utf8))
        XCTAssertEqual(try up.seal(Data("{\"type\":\"ping\"}".utf8)),
                       hex("0000000000000000000000017366b6b673f5a4667f0689292c9b5871f16ac83ed0a5f65738929a7877ab14"))
    }

    func testKeyIdMatchesTheTV() {
        XCTAssertEqual(EditorLink.keyId(seq(0, 32)), hex("c3c8a36d671339dd"))
    }

    func testFramesMustArriveInOrderAndUntouched() throws {
        let key = seq(1, 32), phone = seq(2, 16), tv = seq(3, 16)
        var seal = try EditorCipher(sessionKey: key, phoneNonce: phone, tvNonce: tv, info: EditorCipher.tvToPhone)
        var open = try EditorCipher(sessionKey: key, phoneNonce: phone, tvNonce: tv, info: EditorCipher.tvToPhone)
        let first = try seal.seal(Data([1])), second = try seal.seal(Data([2]))
        XCTAssertThrowsError(try open.open(second))
        XCTAssertEqual(try open.open(first), Data([1]))
        XCTAssertThrowsError(try open.open(first))
        var forged = second; forged[forged.count - 1] ^= 1
        XCTAssertThrowsError(try open.open(forged))
        XCTAssertEqual(try open.open(second), Data([2]))
    }

    func testLinkCarriesA32ByteURLSafeKey() throws {
        let key = try EditorLink.newKey()
        let url = EditorLink.url(key: key)
        XCTAssertTrue(url.hasPrefix("tvhome://phone-edit?k="))
        let k = String(url.dropFirst("tvhome://phone-edit?k=".count))
        XCTAssertEqual(k.count, 43)
        XCTAssertNil(k.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(key, try EditorLink.newKey())
    }
}
