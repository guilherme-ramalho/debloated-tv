package com.gathin.tvhome;

import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Encryption for the phone editor (docs/launcher-editor-contract.md, version 2). Plain Java, no Android types,
 * so the JVM unit tests and the iPhone's CryptoKit code can be checked against the same vectors.
 *
 * The phone puts a fresh random 32-byte key in the tvhome://phone-edit link it sends through the already paired
 * Android TV Remote Service, so only a phone that is paired with this TV can open an editing session. Both sides
 * then exchange 16-byte nonces in the clear (the phone adds an 8-byte key ID, see keyId) and derive one AES-256-GCM key per direction with HKDF-SHA256
 * (salt = phone nonce + TV nonce). Each sealed frame is nonce(12) + ciphertext + tag(16), where the nonce is four
 * zero bytes and a big-endian counter that starts at 0 and must arrive in order: a replayed, reordered or forged
 * frame fails and ends the session.
 */
final class EditorCrypto {
    static final int KEY_BYTES = 32;
    static final int HELLO_NONCE_BYTES = 16;
    static final int GCM_NONCE_BYTES = 12;
    static final int GCM_TAG_BYTES = 16;
    static final String INFO_PHONE_TO_TV = "tvhome-editor v2 phone-to-tv";
    static final String INFO_TV_TO_PHONE = "tvhome-editor v2 tv-to-phone";
    static final String INFO_KEY_ID = "tvhome-editor v2 key-id";
    static final int KEY_ID_BYTES = 8;

    private EditorCrypto() {}

    /** RFC 5869 HKDF-SHA256, one or more output blocks. */
    static byte[] hkdf(byte[] ikm, byte[] salt, byte[] info, int length) throws GeneralSecurityException {
        if (length <= 0 || length > 255 * 32) throw new IllegalArgumentException("length");
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt == null || salt.length == 0 ? new byte[32] : salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);
        mac.init(new SecretKeySpec(prk, "HmacSHA256"));
        byte[] out = new byte[length];
        byte[] t = new byte[0];
        int filled = 0;
        for (int i = 1; filled < length; i++) {
            mac.update(t);
            mac.update(info);
            mac.update((byte) i);
            t = mac.doFinal();
            int n = Math.min(t.length, length - filled);
            System.arraycopy(t, 0, out, filled, n);
            filled += n;
        }
        return out;
    }

    /**
     * Names a key without revealing it. The phone sends it in its hello so a listener started for an older link
     * (the phone retried, or tapped twice) turns the connection away at once instead of failing on the first frame.
     */
    static byte[] keyId(byte[] key) throws GeneralSecurityException {
        return hkdf(key, new byte[0], INFO_KEY_ID.getBytes(java.nio.charset.StandardCharsets.UTF_8), KEY_ID_BYTES);
    }

    static byte[] concat(byte[] a, byte[] b) {
        byte[] r = Arrays.copyOf(a, a.length + b.length);
        System.arraycopy(b, 0, r, a.length, b.length);
        return r;
    }

    static boolean constantTimeEquals(byte[] a, byte[] b) {
        return MessageDigest.isEqual(a, b);
    }

    /** One direction of a session: seals or opens frames with a strictly increasing counter. */
    static final class Channel {
        private final SecretKeySpec key;
        private long counter;

        Channel(byte[] sessionKey, byte[] phoneNonce, byte[] tvNonce, String info) throws GeneralSecurityException {
            if (sessionKey.length != KEY_BYTES || phoneNonce.length != HELLO_NONCE_BYTES
                    || tvNonce.length != HELLO_NONCE_BYTES) {
                throw new IllegalArgumentException("Bad editor key or nonce length");
            }
            byte[] derived = hkdf(sessionKey, concat(phoneNonce, tvNonce),
                    info.getBytes(java.nio.charset.StandardCharsets.UTF_8), KEY_BYTES);
            key = new SecretKeySpec(derived, "AES");
        }

        static byte[] nonce(long counter) {
            return ByteBuffer.allocate(GCM_NONCE_BYTES).putInt(0).putLong(counter).array();
        }

        byte[] seal(byte[] plain) throws GeneralSecurityException {
            byte[] nonce = nonce(counter++);
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_BYTES * 8, nonce));
            return concat(nonce, c.doFinal(plain));
        }

        byte[] open(byte[] frame) throws GeneralSecurityException {
            if (frame.length < GCM_NONCE_BYTES + GCM_TAG_BYTES) throw new GeneralSecurityException("Short frame");
            byte[] nonce = Arrays.copyOf(frame, GCM_NONCE_BYTES);
            if (!constantTimeEquals(nonce, nonce(counter))) throw new GeneralSecurityException("Out-of-order frame");
            Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
            c.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(GCM_TAG_BYTES * 8, nonce));
            byte[] plain = c.doFinal(frame, GCM_NONCE_BYTES, frame.length - GCM_NONCE_BYTES);
            counter++;
            return plain;
        }
    }
}
