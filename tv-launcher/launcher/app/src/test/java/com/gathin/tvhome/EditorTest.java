package com.gathin.tvhome;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;

/** The phone editor's crypto, framing, session lifecycle and layout rules (iPhone: EditorCipherTests). */
public class EditorTest {
    private static byte[] hex(String s) {
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) out[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return out;
    }

    private static byte[] seq(int start, int n) {
        byte[] b = new byte[n];
        for (int i = 0; i < n; i++) b[i] = (byte) (start + i);
        return b;
    }

    /** The same vector the iPhone test checks, computed independently with Python's cryptography package. */
    @Test public void knownAnswerMatchesThePhone() throws Exception {
        byte[] key = seq(0, 32), phone = seq(0xA0, 16), tv = seq(0x10, 16);
        byte[] salt = EditorCrypto.concat(phone, tv);
        assertArrayEquals(hex("808e96a4f5f0966171716166ce7e116430013d94af4bed4d845529c15a0ea928"),
                EditorCrypto.hkdf(key, salt, EditorCrypto.INFO_PHONE_TO_TV.getBytes(StandardCharsets.UTF_8), 32));
        assertArrayEquals(hex("95675c6bcf2e89294a67840934b28d17c7f8c0b2c0cec457a6afe1ebba83ce06"),
                EditorCrypto.hkdf(key, salt, EditorCrypto.INFO_TV_TO_PHONE.getBytes(StandardCharsets.UTF_8), 32));
        EditorCrypto.Channel up = new EditorCrypto.Channel(key, phone, tv, EditorCrypto.INFO_PHONE_TO_TV);
        up.seal("{}".getBytes(StandardCharsets.UTF_8));
        assertArrayEquals(hex("0000000000000000000000017366b6b673f5a4667f0689292c9b5871f16ac83ed0a5f65738929a7877ab14"),
                up.seal("{\"type\":\"ping\"}".getBytes(StandardCharsets.UTF_8)));
    }

    @Test public void keyIdMatchesThePhone() throws Exception {
        assertArrayEquals(hex("c3c8a36d671339dd"), EditorCrypto.keyId(seq(0, 32)));
    }

    @Test public void helloForAnotherKeyIsTurnedAwayWithoutUsingAnAttempt() throws Exception {
        byte[] key = new byte[32];
        new SecureRandom().nextBytes(key);
        int port = 19500 + new SecureRandom().nextInt(150);
        EditorServer server = EditorServer.start(key, req -> "{}", line -> { }, port);
        for (int i = 0; i < EditorServer.MAX_FAILED_ATTEMPTS + 1; i++) {
            Socket other = connect(port);
            assertNull(roundTrip(other, new byte[32], "{}"));   // an older link's key: closed after the hello
            other.close();
        }
        Socket s = connect(port);
        assertEquals("{}", roundTrip(s, key, "{\"type\":\"ping\"}"));
        s.close();
        server.join(5000);
    }

    @Test public void framesMustArriveInOrderAndUntouched() throws Exception {
        byte[] key = seq(1, 32), phone = seq(2, 16), tv = seq(3, 16);
        EditorCrypto.Channel seal = new EditorCrypto.Channel(key, phone, tv, EditorCrypto.INFO_PHONE_TO_TV);
        EditorCrypto.Channel open = new EditorCrypto.Channel(key, phone, tv, EditorCrypto.INFO_PHONE_TO_TV);
        byte[] first = seal.seal(new byte[] {1}), second = seal.seal(new byte[] {2});
        try { open.open(second); fail("skipped frame accepted"); } catch (GeneralSecurityException expected) { }
        assertArrayEquals(new byte[] {1}, open.open(first));
        try { open.open(first); fail("replayed frame accepted"); } catch (GeneralSecurityException expected) { }
        byte[] forged = second.clone();
        forged[forged.length - 1] ^= 1;
        try { open.open(forged); fail("forged frame accepted"); } catch (GeneralSecurityException expected) { }
        EditorCrypto.Channel wrongDirection = new EditorCrypto.Channel(key, phone, tv, EditorCrypto.INFO_TV_TO_PHONE);
        try { wrongDirection.open(first); fail("other direction's key accepted"); } catch (GeneralSecurityException expected) { }
    }

    @Test public void wireRoundTripsAndRejectsOversizedFrames() throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] big = new byte[300];
        EditorWire.write(out, big);
        assertArrayEquals(new byte[] {(byte) 0xac, 0x02}, Arrays.copyOf(out.toByteArray(), 2));
        InputStream in = new ByteArrayInputStream(out.toByteArray());
        assertEquals(300, EditorWire.read(in, 1000).length);
        assertNull(EditorWire.read(in, 1000));
        try {
            EditorWire.read(new ByteArrayInputStream(out.toByteArray()), 100);
            fail("oversized frame accepted");
        } catch (java.io.IOException expected) { }
    }

    @Test public void serverServesOnePhoneThenStops() throws Exception {
        byte[] key = new byte[32];
        new SecureRandom().nextBytes(key);
        int port = 19700 + new SecureRandom().nextInt(200);
        EditorServer server = EditorServer.start(key, req -> "{\"echo\":" + req + "}", line -> { }, port);
        Socket wrong = connect(port);
        assertNull(roundTrip(wrong, new byte[32], "{}"));   // wrong key: the TV hangs up
        Socket s = connect(port);
        assertEquals("{\"echo\":{\"type\":\"ping\"}}", roundTrip(s, key, "{\"type\":\"ping\"}"));
        s.close();
        server.join(5000);
        assertFalse(EditorServer.running());
        try {
            new Socket("127.0.0.1", port).close();
            fail("still listening after the session");
        } catch (java.io.IOException expected) { }
    }

    private static Socket connect(int port) throws Exception {
        for (int i = 0; i < 50; i++) {
            try {
                return new Socket("127.0.0.1", port);
            } catch (java.io.IOException e) {
                Thread.sleep(50);
            }
        }
        throw new AssertionError("server did not start");
    }

    /** One request as the phone sends it; null when the TV closed the connection instead of answering. */
    private static String roundTrip(Socket s, byte[] key, String request) throws Exception {
        s.setSoTimeout(5000);
        OutputStream out = s.getOutputStream();
        InputStream in = s.getInputStream();
        byte[] phone = new byte[16];
        new SecureRandom().nextBytes(phone);
        EditorWire.write(out, EditorCrypto.concat(EditorCrypto.concat(EditorServer.MAGIC, phone), EditorCrypto.keyId(key)));
        byte[] hello;
        try {
            hello = EditorWire.read(in, 64);
        } catch (java.io.IOException closed) {
            return null;
        }
        if (hello == null) return null;
        byte[] tv = Arrays.copyOfRange(hello, 4, 20);
        EditorCrypto.Channel up = new EditorCrypto.Channel(key, phone, tv, EditorCrypto.INFO_PHONE_TO_TV);
        EditorCrypto.Channel down = new EditorCrypto.Channel(key, phone, tv, EditorCrypto.INFO_TV_TO_PHONE);
        EditorWire.write(out, up.seal(request.getBytes(StandardCharsets.UTF_8)));
        byte[] reply = EditorWire.read(in, EditorWire.MAX_FRAME);
        return reply == null ? null : new String(down.open(reply), StandardCharsets.UTF_8);
    }

    @Test public void layoutRules() {
        List<String> order = Arrays.asList("com.netflix.ninja", "com.missing.app", "com.tcl.tv", "com.google.android.youtube.tv",
                "com.wbd.stream");
        EditorLayout.Layout l = new EditorLayout.Layout(2, order, Collections.singletonList("com.tcl.tv"), "aurora");
        EditorLayout.validate(l);
        HashSet<String> installed = new HashSet<>(Arrays.asList("com.netflix.ninja", "com.tcl.tv",
                "com.google.android.youtube.tv", "com.wbd.stream", "com.spotify.tv.android"));
        assertEquals(Arrays.asList("com.netflix.ninja", "com.google.android.youtube.tv"), EditorLayout.dock(l, installed));
        assertEquals(Arrays.asList("com.netflix.ninja", "com.google.android.youtube.tv", "com.wbd.stream", "com.spotify.tv.android"),
                EditorLayout.gridOrder(l, Arrays.asList("com.spotify.tv.android", "com.wbd.stream", "com.netflix.ninja",
                        "com.google.android.youtube.tv", "com.tcl.tv")));
        assertTrue(EditorLayout.photo("photo-123e4567-e89b-12d3-a456-426614174000"));
        assertFalse(EditorLayout.photo("photo-../../etc"));
        for (EditorLayout.Layout bad : Arrays.asList(
                new EditorLayout.Layout(0, order, Collections.emptyList(), "dusk"),
                new EditorLayout.Layout(8, order, Collections.emptyList(), "dusk"),
                new EditorLayout.Layout(5, Arrays.asList("a.b", "a.b"), Collections.emptyList(), "dusk"),
                new EditorLayout.Layout(5, Collections.singletonList("not a package"), Collections.emptyList(), "dusk"),
                new EditorLayout.Layout(5, order, Collections.emptyList(), "../wallpaper"))) {
            try { EditorLayout.validate(bad); fail("accepted an invalid layout"); } catch (IllegalArgumentException expected) { }
        }
    }

    @Test public void reportedOrderPutsDockFirstAndHiddenLast() {
        assertEquals(Arrays.asList("b.b", "c.c", "a.a", "h.h"),
                EditorLayout.reportedOrder(Arrays.asList("b.b", "gone.app"), Collections.singletonList("c.c"),
                        Arrays.asList("a.a", "b.b", "c.c", "h.h"), Collections.singletonList("h.h")));
    }
}
