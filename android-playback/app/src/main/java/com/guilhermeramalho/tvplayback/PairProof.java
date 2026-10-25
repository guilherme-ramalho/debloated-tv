package com.guilhermeramalho.tvplayback;
import java.math.BigInteger;
import java.security.*;
import java.security.interfaces.RSAPublicKey;
public final class PairProof {
    private static byte[] unsigned(BigInteger number) {
        byte[] b=number.toByteArray();return b[0]==0?java.util.Arrays.copyOfRange(b,1,b.length):b;
    }
    public static byte[] proof(RSAPublicKey client, RSAPublicKey server, byte[] suffix) throws GeneralSecurityException {
        if(suffix.length!=2)throw new IllegalArgumentException("Expected two random bytes");
        MessageDigest sha=MessageDigest.getInstance("SHA-256");
        sha.update(unsigned(client.getModulus()));sha.update(unsigned(client.getPublicExponent()));
        sha.update(unsigned(server.getModulus()));sha.update(unsigned(server.getPublicExponent()));
        return sha.digest(suffix);
    }
    public static String code(byte[] proof, byte[] suffix) { return String.format(java.util.Locale.ROOT,"%02X%02X%02X",proof[0]&255,suffix[0]&255,suffix[1]&255); }
    public static String fingerprint(java.security.cert.Certificate cert) throws GeneralSecurityException {
        byte[] digest=MessageDigest.getInstance("SHA-256").digest(cert.getEncoded());
        StringBuilder s=new StringBuilder();for(byte b:digest)s.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return s.toString();
    }
}
