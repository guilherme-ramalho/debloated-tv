package com.gathin.tvhome;

import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Frames for the phone editor: an unsigned LEB128 length, then that many bytes (the iPhone's Wire.varint). */
final class EditorWire {
    /** Room for a 1,000,000-byte wallpaper JPEG in base64 inside JSON, plus the GCM overhead. */
    static final int MAX_FRAME = 4 * 1024 * 1024;

    private EditorWire() {}

    static byte[] varint(long value) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(10);
        do {
            int b = (int) (value & 0x7f);
            value >>>= 7;
            if (value != 0) b |= 0x80;
            out.write(b);
        } while (value != 0);
        return out.toByteArray();
    }

    static void write(OutputStream out, byte[] payload) throws IOException {
        if (payload.length == 0 || payload.length > MAX_FRAME) throw new IOException("Frame size " + payload.length);
        out.write(varint(payload.length));
        out.write(payload);
        out.flush();
    }

    /** The next frame, or null at a clean end of stream before a frame starts. */
    static byte[] read(InputStream in, int max) throws IOException {
        long size = 0;
        for (int shift = 0; ; shift += 7) {
            int b = in.read();
            if (b < 0) {
                if (shift == 0) return null;
                throw new EOFException("Truncated frame length");
            }
            if (shift >= 35) throw new IOException("Frame length too long");
            size |= (long) (b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
        }
        if (size <= 0 || size > max) throw new IOException("Frame size " + size);
        byte[] frame = new byte[(int) size];
        int off = 0;
        while (off < frame.length) {
            int n = in.read(frame, off, frame.length - off);
            if (n < 0) throw new EOFException("Truncated frame");
            off += n;
        }
        return frame;
    }
}
