package com.guilhermeramalho.tvplayback;
import org.junit.Test;
import static org.junit.Assert.*;
import java.io.*;
import java.security.*;
import java.security.interfaces.RSAPublicKey;
public class ProtocolTest {
    @Test public void framedStreamHandlesFragmentationAndSeveralMessages() throws Exception {
        ByteArrayOutputStream bytes=new ByteArrayOutputStream();byte[] large=new byte[300];Frames.write(bytes,large);Frames.write(bytes,new byte[]{42});
        InputStream split=new FilterInputStream(new ByteArrayInputStream(bytes.toByteArray())){@Override public int read(byte[] b,int o,int n)throws IOException{return super.read(b,o,Math.min(1,n));}};
        assertArrayEquals(large,Frames.read(split));assertArrayEquals(new byte[]{42},Frames.read(split));
    }
    @Test public void rejectsOversizedAndTruncatedFrames() throws Exception {
        for(byte[] invalid:new byte[][]{{0},{(byte)0xff,(byte)0xff,0x7f},{5,1},{(byte)0x80,(byte)0x80,(byte)0x80}}){try{Frames.read(new ByteArrayInputStream(invalid));fail();}catch(IOException expected){}}
    }
    @Test public void pairingProofBindsBothRsaIdentitiesAndRandomCode() throws Exception {
        KeyPairGenerator gen=KeyPairGenerator.getInstance("RSA");gen.initialize(2048);RSAPublicKey a=(RSAPublicKey)gen.generateKeyPair().getPublic(),b=(RSAPublicKey)gen.generateKeyPair().getPublic();
        byte[] suffix={0x12,0x34},proof=PairProof.proof(a,b,suffix);
        assertEquals(32,proof.length);assertTrue(PairProof.code(proof,suffix).endsWith("1234"));assertFalse(MessageDigest.isEqual(proof,PairProof.proof(b,a,suffix)));assertFalse(MessageDigest.isEqual(proof,PairProof.proof(a,b,new byte[]{0x12,0x35})));
    }
}
