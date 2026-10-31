import XCTest
import Security
@testable import TVRemoteCore

/// Vectors from adb_shell 0.4.4 (Python) for a fixed RSA-2048 key: its Android public-key encoding and its signature
/// of a 20-byte token, which matched adb_shell's own signer.
final class AdbTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        var data = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return data
    }
    private static let privateDER = [
            "308204a50201000282010100ad601da3a42fc818b0962041961e3e94b2276a611c7caa7f699640b8e0eafa1f5e093e02",
            "b5ebdaf9f1114b0e3e83ae551370cc08111a40bc1629a73c36ff766ba5785cea92d5cd063d158b2faee0b7c781f054e1",
            "8877d7207d95868fad9eee3df0793ee9560a732c14fdfa89fb23422c6f993dc3687feee6cc6afe0b1a255692634b2f7b",
            "6634edbda68a9deb6df14ad955d17a1f2cbf6eb4df3453cfb7a80acb298be687795a266ab68245cec69f26fadacacc54",
            "d6c629fb5f0941a9045c3fb44d9e29641664b71eba40bcab9995e9d239503909c3d5597689426c89612a389b5602e1fa",
            "d789b9b3c14bbc7ab22fec15294ab26a2e71240da7a7b7ef1b48004f020301000102820100199b35301d686e8b31a42f",
            "f0bfdfde54f92dad1e83fb3da097d2f88d805a9ec52739ace39aeed2115188c0fc6ceb3c97957421639cf30855e9dd63",
            "b517026001176d517bd662a6bca1cf9ec0ff791d163af0bdf899693f12ae0ef97d704d258417123137d1320b3f457d1a",
            "c06a4bbe2845f5ecbe019f1e2fb99d4bc16403d911d888d771625ae67a8e5e23a4e042b3161c4826ced6950907ddce65",
            "ddda062759dc36bd8dec91234fcda4a48e2fd477f4d5f5cc91039361e9c23ce8980411d4401ec6ef40350b2e0c28d0f5",
            "dbab8b144724719211467c6b96d70272b1db7d004eeeafde622dd79744eeef948fd52bed5c7deafb0bc7145045bddbae",
            "6fb9282ce102818100ec35c9079d2c97b2087f27e84a5c5f00db6e11d34b70c43fbf7c6c5c631d286d0b2594b50a9647",
            "a6b8b967107b3112aee16ddcce76acdb4d55636d575d2e6031b380629cdd588096b2a2248fec7b2e4093a502b0cbb675",
            "17efac0063c167feaaa3ae41b59698fb99f40dbaef5503e773dc7a4e951da223e460b47c21cba29a5702818100bbe6a8",
            "7efcab5b98a24694bc594858476f8e276b6319ac91308ccd66be6c461ca50ebac927ae06fa21be0567f9b9298b4f8823",
            "4e715520fb8b54e4d0d54f0c550c80be9a1cbaabcd5611fa6cec472710d7eb418e89d7131d3453ec0f3e7ec0f7e640e2",
            "955e29aeb1b25274735223ffc0a6bbe0426617adf586090963d8ca7ec9028181008ca131009178fd0f87b37ca4f5b0ac",
            "f72bad0a7bcbcc656ab6ac732f45eb1428679c863e8b0111c396f2fb037af4aa74e7cdaaca59296c9f4c1917fe0d8210",
            "cf4659475cb10381fb367b065d91a37cd401931a58fbcfb342fef45e7f05a4ce9ff53747f3bea772142493101a717913",
            "918d505bfcb759d318a2e2918ce559f79d02818100940c605475d6ba3be0184696c4ae28c8585024250b972e0dd3b80d",
            "1ad80ccd8d424c01c5fe9ab2eaa06d6d2b086ae91dd7d34726464bb1ca20750a38b4e92ca952499a642920b7bef902ff",
            "52953456c681a9de2465dced3584865f277fb1356fdd9ee0289a61b34055657c5564b1f290238f425a6ec057936d416f",
            "81994dab6902818100d68eaff588acf18027313beebcfa03a4eab71a315effd5ac5844b6343036e3044545929e166b38",
            "42097fcbbccb05c65418892796b33bf18d8cc932aecbbd649668ebb4c4b7c444d3db8fc227adc907e673c466342f3b60",
            "2af656b76def106d51ead7d01635eba7a353babb7360305c8fa972bb6e665659dc3ca814155998053a"
    ].joined()
    private static let modulus = [
            "ad601da3a42fc818b0962041961e3e94b2276a611c7caa7f699640b8e0eafa1f5e093e02b5ebdaf9f1114b0e3e83ae55",
            "1370cc08111a40bc1629a73c36ff766ba5785cea92d5cd063d158b2faee0b7c781f054e18877d7207d95868fad9eee3d",
            "f0793ee9560a732c14fdfa89fb23422c6f993dc3687feee6cc6afe0b1a255692634b2f7b6634edbda68a9deb6df14ad9",
            "55d17a1f2cbf6eb4df3453cfb7a80acb298be687795a266ab68245cec69f26fadacacc54d6c629fb5f0941a9045c3fb4",
            "4d9e29641664b71eba40bcab9995e9d239503909c3d5597689426c89612a389b5602e1fad789b9b3c14bbc7ab22fec15",
            "294ab26a2e71240da7a7b7ef1b48004f"
    ].joined()
    private static let android = [
            "QAAAAFHpEN9PAEgb77enpw0kcS5qskopFewvsnq8S8GzuYnX+uECVps4KmGJbEKJdlnVwwk5UDnS6ZWZq7xAuh63ZBZkKZ5N",
            "tD9cBKlBCV/7KcbWVMzK2vomn8bORYK2aiZaeYfmiynLCqi3z1M037RuvywfetFV2Urxbeudiqa97TRmey9LY5JWJRoL/mrM",
            "5u5/aMM9mW8sQiP7ifr9FCxzClbpPnnwPe6erY+GlX0g13eI4VTwgce34K4vixU9Bs3VkupceKVrdv82PKcpFrxAGhEIzHAT",
            "Va6DPg5LEfH52uu1Aj4JXh/66uC4QJZpf6p8HGFqJ7KUPh6WQSCWsBjIL6SjHWCtGOgA4UgoH4PsdQelUt6WBljTLFiGLV9c",
            "PVdFCS7oUbv4cunDuRHSnwMMDcV0Pc03J178fzXpqBst4hZ+fbHW/BB4OMBaTyU4d6TkRPZggmQdtMcLly9gKR9Xgmw0ixU7",
            "XdgPjyHaPk0gvrG6QUdxXxjXp8UXKbl0b0c7yhGmhbUPIYaaG8CqX1IOqZXfK5Qkt+NiKwioun3ONHsrM91lXjyWBYwoffSE",
            "iqha0ebeSKrsqGSw3C7QbqMuENP5xRkbNIPCipKBS4To9bVxswDrMzbyWPtwgrseyG6FFCAKmMIeTZDPLFJbGq06jqX/eW1C",
            "//mwfO37WuxXdvlKwqpOFgEAAQA="
    ].joined()
    private static let signature = [
            "89c90daf7f3add1ca208b8f6306b3b6363e48229f1aa663b3e71df09cc3d518864ca502e2f6ed474b07a72468c9ff3a1",
            "5fabeead94d1d49ec2d3a678c4b62d70abdc513bfc09741d337b08ac51e8532c243aea88830a5b3a293ebc4facba4504",
            "5d1e90775d633b9aa77c75352defa45fb93116ab92f0b5fd619366f66b75dc18b8e9d0d33f1c792d362ec4b57c5c4e7f",
            "7ba1062a32111aa265dbed38a1ae089cec0cc80f86168eb362dd7aeeb11b656baef46556cebefdfdd5065a4077408625",
            "4aad2f261892fe90b7e1316bb079de6336b980690c060dfb71798e396b1a87b0a3dd18c615a57c530b4e09b25a7e01c1",
            "7956028bff21be1da26a515a92c852e6"
    ].joined()

    private func key() throws -> AdbKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(hex(Self.privateDER) as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return AdbKey(privateKey: key)
    }

    func testAndroidPublicKeyEncodingMatchesAdbShell() throws {
        XCTAssertEqual(try AdbKey.androidEncoding(modulus: hex(Self.modulus), exponent: 65537).base64EncodedString(), Self.android)
        let line = try key().publicKeyLine(name: "debloated-tv@iPhone")
        XCTAssertEqual(line, Data((Self.android + " debloated-tv@iPhone").utf8) + Data([0]))
    }

    func testTokenSignatureMatchesAdbShell() throws {
        XCTAssertEqual(try key().sign(token: Data(0..<20)), hex(Self.signature))
        XCTAssertThrowsError(try key().sign(token: Data(0..<19)))
    }

    func testMessageFramingMatchesAdbShell() throws {
        let cnxn = Adb.Message(Adb.cnxn, Adb.version, Adb.maxData, Data("host::debloated-tv".utf8) + Data([0]))
        let encoded = Adb.encode(cnxn)
        XCTAssertEqual(encoded.prefix(24), hex("434e584e010000010000040013000000ed060000bcb1a7b1"))
        var decoder = Adb.Decoder()
        var out = [Adb.Message]()
        for byte in encoded + Adb.encode(Adb.Message(Adb.okay, 7, 9)) { out += try decoder.append(Data([byte])) }
        XCTAssertEqual(out, [cnxn, Adb.Message(Adb.okay, 7, 9)])
        var bad = Adb.Decoder()
        var corrupt = encoded; corrupt[20] ^= 1
        XCTAssertThrowsError(try bad.append(corrupt))
    }

    func testBannerProperties() {
        let banner = Data("device::ro.product.name=BeyondTV4;ro.product.model=Smart TV Pro;ro.product.device=BeyondTV4;features=cmd,shell_v2".utf8) + Data([0])
        let props = Adb.bannerProperties(banner)
        XCTAssertEqual(props["ro.product.model"], "Smart TV Pro")
        XCTAssertEqual(props["ro.product.device"], "BeyondTV4")
    }

    /// Against a real TV or the emulator: ADB_TEST_HOST=127.0.0.1 (ADB_TEST_PORT, default 5555) swift test --filter AdbTests
    func testLiveTVWhenConfigured() async throws {
        guard let host = ProcessInfo.processInfo.environment["ADB_TEST_HOST"] else { throw XCTSkip("Set ADB_TEST_HOST to run against a TV or emulator") }
        let port = UInt16(ProcessInfo.processInfo.environment["ADB_TEST_PORT"] ?? "5555") ?? 5555
        let client = AdbClient(host: host, port: port, key: try key())
        await client.setLog { print("adb:", $0) }
        let props = try await client.connect(approvalTimeout: 120) { print("Accept 'Allow USB debugging?' on the TV or emulator…") }
        print("Connected:", props["ro.product.model"] ?? "?")
        let sdk = try await client.shell("getprop ro.build.version.sdk")
        XCTAssertEqual(sdk.status, 0)
        XCTAssertNotNil(Int(sdk.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let failed = try await client.shell("exit 3")
        XCTAssertNotEqual(failed.status, 0)
        var blob = Data(count: 300_000)
        for i in 0..<blob.count { blob[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let path = "/data/local/tmp/debloated-tv-test.bin"
        try await client.push(blob, to: path)
        let size = try await client.shell("stat -c %s " + path)
        XCTAssertEqual(size.output.trimmingCharacters(in: .whitespacesAndNewlines), String(blob.count))
        _ = try await client.shell("rm -f " + path)
        await client.close()
    }
}
