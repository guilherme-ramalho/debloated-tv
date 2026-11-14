package com.guilhermeramalho.puriotv.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.net.ServerSocket
import java.security.KeyFactory
import java.security.KeyPair
import java.security.Signature
import java.security.interfaces.RSAPrivateCrtKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPublicKeySpec
import kotlin.concurrent.thread

/**
 * Ports of ios/Tests/AdbTests.swift and AdbFramingEdgeTests: vectors from adb_shell 0.4.4 (Python) for a fixed RSA-2048
 * key (its Android public-key encoding and its signature of a 20-byte token), plus a loopback adbd for the client.
 */
class AdbTest {
    companion object {
        fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        const val PRIVATE_DER = "308204a50201000282010100ad601da3a42fc818b0962041961e3e94b2276a611c7caa7f699640b8e0eafa1f5e093e02" +
            "b5ebdaf9f1114b0e3e83ae551370cc08111a40bc1629a73c36ff766ba5785cea92d5cd063d158b2faee0b7c781f054e1" +
            "8877d7207d95868fad9eee3df0793ee9560a732c14fdfa89fb23422c6f993dc3687feee6cc6afe0b1a255692634b2f7b" +
            "6634edbda68a9deb6df14ad955d17a1f2cbf6eb4df3453cfb7a80acb298be687795a266ab68245cec69f26fadacacc54" +
            "d6c629fb5f0941a9045c3fb44d9e29641664b71eba40bcab9995e9d239503909c3d5597689426c89612a389b5602e1fa" +
            "d789b9b3c14bbc7ab22fec15294ab26a2e71240da7a7b7ef1b48004f020301000102820100199b35301d686e8b31a42f" +
            "f0bfdfde54f92dad1e83fb3da097d2f88d805a9ec52739ace39aeed2115188c0fc6ceb3c97957421639cf30855e9dd63" +
            "b517026001176d517bd662a6bca1cf9ec0ff791d163af0bdf899693f12ae0ef97d704d258417123137d1320b3f457d1a" +
            "c06a4bbe2845f5ecbe019f1e2fb99d4bc16403d911d888d771625ae67a8e5e23a4e042b3161c4826ced6950907ddce65" +
            "ddda062759dc36bd8dec91234fcda4a48e2fd477f4d5f5cc91039361e9c23ce8980411d4401ec6ef40350b2e0c28d0f5" +
            "dbab8b144724719211467c6b96d70272b1db7d004eeeafde622dd79744eeef948fd52bed5c7deafb0bc7145045bddbae" +
            "6fb9282ce102818100ec35c9079d2c97b2087f27e84a5c5f00db6e11d34b70c43fbf7c6c5c631d286d0b2594b50a9647" +
            "a6b8b967107b3112aee16ddcce76acdb4d55636d575d2e6031b380629cdd588096b2a2248fec7b2e4093a502b0cbb675" +
            "17efac0063c167feaaa3ae41b59698fb99f40dbaef5503e773dc7a4e951da223e460b47c21cba29a5702818100bbe6a8" +
            "7efcab5b98a24694bc594858476f8e276b6319ac91308ccd66be6c461ca50ebac927ae06fa21be0567f9b9298b4f8823" +
            "4e715520fb8b54e4d0d54f0c550c80be9a1cbaabcd5611fa6cec472710d7eb418e89d7131d3453ec0f3e7ec0f7e640e2" +
            "955e29aeb1b25274735223ffc0a6bbe0426617adf586090963d8ca7ec9028181008ca131009178fd0f87b37ca4f5b0ac" +
            "f72bad0a7bcbcc656ab6ac732f45eb1428679c863e8b0111c396f2fb037af4aa74e7cdaaca59296c9f4c1917fe0d8210" +
            "cf4659475cb10381fb367b065d91a37cd401931a58fbcfb342fef45e7f05a4ce9ff53747f3bea772142493101a717913" +
            "918d505bfcb759d318a2e2918ce559f79d02818100940c605475d6ba3be0184696c4ae28c8585024250b972e0dd3b80d" +
            "1ad80ccd8d424c01c5fe9ab2eaa06d6d2b086ae91dd7d34726464bb1ca20750a38b4e92ca952499a642920b7bef902ff" +
            "52953456c681a9de2465dced3584865f277fb1356fdd9ee0289a61b34055657c5564b1f290238f425a6ec057936d416f" +
            "81994dab6902818100d68eaff588acf18027313beebcfa03a4eab71a315effd5ac5844b6343036e3044545929e166b38" +
            "42097fcbbccb05c65418892796b33bf18d8cc932aecbbd649668ebb4c4b7c444d3db8fc227adc907e673c466342f3b60" +
            "2af656b76def106d51ead7d01635eba7a353babb7360305c8fa972bb6e665659dc3ca814155998053a"
        const val MODULUS = "ad601da3a42fc818b0962041961e3e94b2276a611c7caa7f699640b8e0eafa1f5e093e02b5ebdaf9f1114b0e3e83ae55" +
            "1370cc08111a40bc1629a73c36ff766ba5785cea92d5cd063d158b2faee0b7c781f054e18877d7207d95868fad9eee3d" +
            "f0793ee9560a732c14fdfa89fb23422c6f993dc3687feee6cc6afe0b1a255692634b2f7b6634edbda68a9deb6df14ad9" +
            "55d17a1f2cbf6eb4df3453cfb7a80acb298be687795a266ab68245cec69f26fadacacc54d6c629fb5f0941a9045c3fb4" +
            "4d9e29641664b71eba40bcab9995e9d239503909c3d5597689426c89612a389b5602e1fad789b9b3c14bbc7ab22fec15" +
            "294ab26a2e71240da7a7b7ef1b48004f"
        const val ANDROID = "QAAAAFHpEN9PAEgb77enpw0kcS5qskopFewvsnq8S8GzuYnX+uECVps4KmGJbEKJdlnVwwk5UDnS6ZWZq7xAuh63ZBZkKZ5N" +
            "tD9cBKlBCV/7KcbWVMzK2vomn8bORYK2aiZaeYfmiynLCqi3z1M037RuvywfetFV2Urxbeudiqa97TRmey9LY5JWJRoL/mrM" +
            "5u5/aMM9mW8sQiP7ifr9FCxzClbpPnnwPe6erY+GlX0g13eI4VTwgce34K4vixU9Bs3VkupceKVrdv82PKcpFrxAGhEIzHAT" +
            "Va6DPg5LEfH52uu1Aj4JXh/66uC4QJZpf6p8HGFqJ7KUPh6WQSCWsBjIL6SjHWCtGOgA4UgoH4PsdQelUt6WBljTLFiGLV9c" +
            "PVdFCS7oUbv4cunDuRHSnwMMDcV0Pc03J178fzXpqBst4hZ+fbHW/BB4OMBaTyU4d6TkRPZggmQdtMcLly9gKR9Xgmw0ixU7" +
            "XdgPjyHaPk0gvrG6QUdxXxjXp8UXKbl0b0c7yhGmhbUPIYaaG8CqX1IOqZXfK5Qkt+NiKwioun3ONHsrM91lXjyWBYwoffSE" +
            "iqha0ebeSKrsqGSw3C7QbqMuENP5xRkbNIPCipKBS4To9bVxswDrMzbyWPtwgrseyG6FFCAKmMIeTZDPLFJbGq06jqX/eW1C" +
            "//mwfO37WuxXdvlKwqpOFgEAAQA="
        const val SIGNATURE = "89c90daf7f3add1ca208b8f6306b3b6363e48229f1aa663b3e71df09cc3d518864ca502e2f6ed474b07a72468c9ff3a1" +
            "5fabeead94d1d49ec2d3a678c4b62d70abdc513bfc09741d337b08ac51e8532c243aea88830a5b3a293ebc4facba4504" +
            "5d1e90775d633b9aa77c75352defa45fb93116ab92f0b5fd619366f66b75dc18b8e9d0d33f1c792d362ec4b57c5c4e7f" +
            "7ba1062a32111aa265dbed38a1ae089cec0cc80f86168eb362dd7aeeb11b656baef46556cebefdfdd5065a4077408625" +
            "4aad2f261892fe90b7e1316bb079de6336b980690c060dfb71798e396b1a87b0a3dd18c615a57c530b4e09b25a7e01c1" +
            "7956028bff21be1da26a515a92c852e6"

        /** The PKCS#1 RSAPrivateKey wrapped as PKCS#8, which java.security reads. */
        fun signer(): JcaAdbSigner {
            val pkcs1 = hex(PRIVATE_DER)
            fun len(n: Int) = byteArrayOf(0x82.toByte(), (n shr 8).toByte(), n.toByte())
            val algorithm = hex("300d06092a864886f70d0101010500")
            val octet = byteArrayOf(0x04) + len(pkcs1.size) + pkcs1
            val body = hex("020100") + algorithm + octet
            val pkcs8 = byteArrayOf(0x30) + len(body.size) + body
            val factory = KeyFactory.getInstance("RSA")
            val private = factory.generatePrivate(PKCS8EncodedKeySpec(pkcs8)) as RSAPrivateCrtKey
            val public = factory.generatePublic(RSAPublicKeySpec(private.modulus, private.publicExponent))
            return JcaAdbSigner(KeyPair(public, private))
        }
    }

    @Test fun androidPublicKeyEncodingMatchesAdbShell() {
        assertEquals(ANDROID, java.util.Base64.getEncoder().encodeToString(AdbKeys.androidEncoding(hex(MODULUS), 65537)))
        val line = AdbKeys.publicKeyLine(signer().publicKey, "debloated-tv@iPhone")
        assertArrayEquals(("$ANDROID debloated-tv@iPhone").toByteArray() + byteArrayOf(0), line)
    }

    @Test fun tokenSignatureMatchesAdbShell() {
        assertArrayEquals(hex(SIGNATURE), signer().sign(ByteArray(20) { it.toByte() }))
        assertThrows(RemoteFailure::class.java) { AdbKeys.digestInfo(ByteArray(19)) }
    }

    @Test fun messageFramingMatchesAdbShell() {
        val cnxn = Adb.Message(Adb.CNXN, Adb.VERSION, Adb.MAX_DATA, "host::debloated-tv".toByteArray() + byteArrayOf(0))
        val encoded = Adb.encode(cnxn)
        assertArrayEquals(hex("434e584e010000010000040013000000ed060000bcb1a7b1"), encoded.copyOf(24))
        val decoder = Adb.Decoder()
        val out = mutableListOf<Adb.Message>()
        for (byte in encoded + Adb.encode(Adb.Message(Adb.OKAY, 7, 9))) out += decoder.append(byteArrayOf(byte))
        assertEquals(listOf(cnxn, Adb.Message(Adb.OKAY, 7, 9)), out)
        val corrupt = encoded.copyOf(); corrupt[20] = (corrupt[20].toInt() xor 1).toByte()
        assertThrows(RemoteFailure::class.java) { Adb.Decoder().append(corrupt) }
    }

    @Test fun bannerProperties() {
        val banner = "device::ro.product.name=BeyondTV4;ro.product.model=Smart TV Pro;ro.product.device=BeyondTV4;features=cmd,shell_v2".toByteArray() + byteArrayOf(0)
        val props = Adb.bannerProperties(banner)
        assertEquals("Smart TV Pro", props["ro.product.model"])
        assertEquals("BeyondTV4", props["ro.product.device"])
        assertEquals(emptyMap<String, String>(), Adb.bannerProperties("device::".toByteArray()))
        assertEquals(emptyMap<String, String>(), Adb.bannerProperties(ByteArray(0)))
    }

    @Test fun messagesSurviveAnySplitAndCoalescing() {
        val stream = Adb.encode(Adb.Message(Adb.OKAY, 1, 2)) + Adb.encode(Adb.Message(Adb.WRTE, 1, 2, "hello".toByteArray()))
        for (cut in 1 until stream.size) {
            val decoder = Adb.Decoder()
            val out = decoder.append(stream.copyOfRange(0, cut)) + decoder.append(stream.copyOfRange(cut, stream.size))
            assertEquals("cut at $cut", listOf(Adb.OKAY, Adb.WRTE), out.map { it.command })
            assertArrayEquals("hello".toByteArray(), out.last().payload)
        }
    }

    @Test fun corruptOrOversizedHeadersAreRejected() {
        val bad = Adb.encode(Adb.Message(Adb.OKAY, 0, 0)); bad[20] = (bad[20].toInt() xor 0xff).toByte()
        assertThrows(RemoteFailure::class.java) { Adb.Decoder().append(bad) }
        val huge = Adb.encode(Adb.Message(Adb.WRTE, 0, 0))
        Adb.le(Adb.MAX_DATA * 4 + 1).copyInto(huge, 12)
        assertThrows(RemoteFailure::class.java) { Adb.Decoder().append(huge) }
    }

    /** A minimal adbd on loopback: asks for a signature, checks it, then serves one shell and one push. */
    @Test fun clientConnectsRunsAShellAndPushesAFile() = runBlocking {
        val signer = signer()
        val server = ServerSocket(0)
        val received = ByteArrayOutputStream()
        var signatureValid = false
        val token = ByteArray(20) { (it * 7).toByte() }
        val tv = thread {
            server.accept().use { socket ->
                val input = DataInputStream(socket.getInputStream()); val output = socket.getOutputStream()
                fun read(): Adb.Message {
                    val head = ByteArray(24); input.readFully(head)
                    val body = ByteArray(Adb.readLE(head, 12)); input.readFully(body)
                    return Adb.Message(Adb.readLE(head, 0), Adb.readLE(head, 4), Adb.readLE(head, 8), body)
                }
                fun send(m: Adb.Message) { output.write(Adb.encode(m)); output.flush() }
                check(read().command == Adb.CNXN)
                send(Adb.Message(Adb.AUTH, Adb.AUTH_TOKEN, 0, token))
                val signature = read()
                signatureValid = Signature.getInstance("NONEwithRSA").run {
                    initVerify(signer.publicKey); update(AdbKeys.digestInfo(token)); verify(signature.payload)
                }
                send(Adb.Message(Adb.CNXN, Adb.VERSION, 4096, "device::ro.product.model=Fake TV;features=cmd".toByteArray() + byteArrayOf(0)))
                // shell
                val open = read(); check(String(open.payload).startsWith("shell:getprop ro.build.version.sdk; echo __DTV_EXIT__"))
                send(Adb.Message(Adb.OKAY, 100, open.arg0))
                send(Adb.Message(Adb.WRTE, 100, open.arg0, "30\r\n__DTV_EXIT__0\r\n".toByteArray()))
                check(read().command == Adb.OKAY)
                send(Adb.Message(Adb.CLSE, 100, open.arg0))
                check(read().command == Adb.CLSE)
                // push: every sync packet arrives in its own WRTE
                val sync = read(); check(String(sync.payload).startsWith("sync:"))
                send(Adb.Message(Adb.OKAY, 101, sync.arg0))
                while (true) {
                    val m = read()
                    if (m.command != Adb.WRTE) continue
                    send(Adb.Message(Adb.OKAY, 101, sync.arg0))
                    val id = String(m.payload, 0, 4)
                    if (id == "DATA") received.write(m.payload, 8, m.payload.size - 8)
                    if (id == "DONE") break
                }
                send(Adb.Message(Adb.WRTE, 101, sync.arg0, "OKAY".toByteArray() + Adb.le(0)))
                read()   // the client's OKAY for that
                send(Adb.Message(Adb.CLSE, 101, sync.arg0))
                read()   // the client's CLSE
            }
        }
        val client = AdbClient("127.0.0.1", server.localPort, signer)
        val props = client.connect(approvalTimeoutMs = 5_000)
        assertEquals("Fake TV", props["ro.product.model"])
        assertTrue("the TV checks the signature the way adbd does", signatureValid)
        val sdk = client.shell("getprop ro.build.version.sdk", 5_000)
        assertEquals(AdbClient.ShellResult("30\n", 0), sdk)
        val blob = ByteArray(10_000) { (it * 31 + 7).toByte() }
        val progress = mutableListOf<Double>()
        client.push(blob, "/data/local/tmp/x.bin", 420) { progress += it }
        assertArrayEquals(blob, received.toByteArray())
        assertTrue("4096-byte messages: the file goes in several pieces", progress.size > 1 && progress.last() == 1.0)
        client.close()
        tv.join(5_000)
        server.close()
    }

    @Test fun unreachablePortIsExplained() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }   // closed again: nothing listens there
        val e = failure { AdbClient("127.0.0.1", port, signer()).connect() }
        assertEquals(SetupIssue.ADB_UNREACHABLE, e.issue)
    }
}
