package com.guilhermeramalho.tvplayback;
import java.io.*;
public final class Frames {
    public static final int LIMIT = 16384;
    public static byte[] read(InputStream in) throws IOException {
        int length=0;
        for(int i=0;i<3;i++) {
            int value=in.read(); if(value<0) throw new EOFException();
            length|=(value&127)<<(7*i);
            if((value&128)==0) {
                if(length==0||length>LIMIT) throw new IOException("Invalid frame size");
                byte[] data=new byte[length]; int offset=0;
                while(offset<length) { int n=in.read(data,offset,length-offset); if(n<0)throw new EOFException();offset+=n; }
                return data;
            }
        }
        throw new IOException("Invalid frame prefix");
    }
    public static void write(OutputStream out, byte[] data) throws IOException {
        if(data.length==0||data.length>LIMIT)throw new IOException("Invalid frame size");
        int size=data.length;
        do { int b=size&127;size>>>=7;out.write(size==0?b:b|128); }while(size!=0);
        out.write(data);out.flush();
    }
}
