package com.gathin.tvhome;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;

/**
 * The on-demand listener behind the phone's TV tab. Plain Java (no Android types) so it can be tested on the JVM.
 *
 * Lifecycle: {@link #start} is called with the one-time key from a tvhome://phone-edit link and replaces any session
 * already running. The socket listens only until one phone proves the key, serves that phone, and stops when the phone
 * disconnects, goes quiet for {@link #IDLE_MS}, or after {@link #MAX_SESSION_MS}. A key is never accepted twice, so
 * nothing keeps listening after the phone leaves the tab, and a new tab visit sends a new link.
 *
 * Handshake: phone sends "TVH2" + 16-byte nonce + 8-byte key ID, TV answers "TVH2" + 16-byte nonce, then every frame
 * is sealed with {@link EditorCrypto.Channel}. The first frame that opens proves the key. A hello for another key (a
 * phone that already sent a newer link) is closed at once and not counted as a failed attempt.
 */
final class EditorServer {
    static final int PORT = 9764;
    static final int LISTEN_MS = 30_000;
    static final int IDLE_MS = 45_000;
    static final long MAX_SESSION_MS = 20 * 60_000L;
    static final int MAX_FAILED_ATTEMPTS = 3;
    static final byte[] MAGIC = "TVH2".getBytes(StandardCharsets.US_ASCII);

    /** Handles one decrypted request (UTF-8 JSON) and returns the reply to seal, or null for none. */
    interface Backend {
        String handle(String request);
    }

    interface Log {
        void line(String message);
    }

    private static final SecureRandom RANDOM = new SecureRandom();
    private static EditorServer current;

    private final byte[] key;
    private final Backend backend;
    private final Log log;
    private final int port;
    private volatile boolean stopped;
    private ServerSocket server;
    private Socket client;
    private final Thread thread;

    private EditorServer(byte[] key, Backend backend, Log log, int port) {
        this.key = key.clone();
        this.backend = backend;
        this.log = log;
        this.port = port;
        thread = new Thread(this::run, "tvhome-editor");
        thread.setDaemon(true);
    }

    /** Starts a session for this key on {@link #PORT}, ending any earlier one. */
    static synchronized EditorServer start(byte[] key, Backend backend, Log log) {
        return start(key, backend, log, PORT);
    }

    static synchronized EditorServer start(byte[] key, Backend backend, Log log, int port) {
        if (key == null || key.length != EditorCrypto.KEY_BYTES) throw new IllegalArgumentException("Editor key");
        if (current != null) current.stop();
        current = new EditorServer(key, backend, log, port);
        current.thread.start();
        return current;
    }

    static synchronized void stopCurrent() {
        if (current != null) current.stop();
        current = null;
    }

    static synchronized boolean running() {
        return current != null && !current.stopped;
    }

    void stop() {
        stopped = true;
        closeQuietly(client);
        closeQuietly(server);
        Arrays.fill(key, (byte) 0);
    }

    /** Waits for the listener thread to end (tests). */
    void join(long ms) throws InterruptedException {
        thread.join(ms);
    }

    private void run() {
        long listenUntil = System.currentTimeMillis() + LISTEN_MS;
        int failures = 0;
        try (ServerSocket s = new ServerSocket()) {
            synchronized (this) {
                if (stopped) return;
                server = s;
            }
            s.setReuseAddress(true);
            s.bind(new InetSocketAddress(port), 1);
            log.line("listening on " + port);
            while (!stopped && failures < MAX_FAILED_ATTEMPTS) {
                int wait = (int) (listenUntil - System.currentTimeMillis());
                if (wait <= 0) {
                    log.line("no phone connected; closing");
                    break;
                }
                s.setSoTimeout(wait);
                Socket c;
                try {
                    c = s.accept();
                } catch (SocketTimeoutException e) {
                    log.line("no phone connected; closing");
                    break;
                }
                synchronized (this) {
                    if (stopped) { closeQuietly(c); break; }
                    client = c;
                }
                Result r = serve(c);
                closeQuietly(c);
                if (r == Result.SERVED) break;   // the key is spent; a new tab visit sends a new link
                if (r == Result.REJECTED) failures++;
            }
        } catch (IOException e) {
            if (!stopped) log.line("listener ended: " + e.getMessage());
        } finally {
            synchronized (EditorServer.class) {
                if (current == this) current = null;
            }
            stopped = true;
            Arrays.fill(key, (byte) 0);
            log.line("closed");
        }
    }

    private enum Result { SERVED, REJECTED, OTHER_SESSION }

    private Result serve(Socket c) {
        boolean authenticated = false;
        try {
            c.setTcpNoDelay(true);
            c.setSoTimeout(IDLE_MS);
            InputStream in = new BufferedInputStream(c.getInputStream());
            OutputStream out = new BufferedOutputStream(c.getOutputStream());
            byte[] hello = EditorWire.read(in, 64);
            int nonceEnd = MAGIC.length + EditorCrypto.HELLO_NONCE_BYTES;
            if (hello == null || hello.length != nonceEnd + EditorCrypto.KEY_ID_BYTES
                    || !Arrays.equals(Arrays.copyOf(hello, MAGIC.length), MAGIC)) {
                log.line("rejected: not an editor hello");
                return Result.REJECTED;
            }
            if (!EditorCrypto.constantTimeEquals(Arrays.copyOfRange(hello, nonceEnd, hello.length), EditorCrypto.keyId(key))) {
                log.line("ignored: hello for another session");
                return Result.OTHER_SESSION;
            }
            byte[] phoneNonce = Arrays.copyOfRange(hello, MAGIC.length, nonceEnd);
            byte[] tvNonce = new byte[EditorCrypto.HELLO_NONCE_BYTES];
            RANDOM.nextBytes(tvNonce);
            EditorWire.write(out, EditorCrypto.concat(MAGIC, tvNonce));
            EditorCrypto.Channel incoming = new EditorCrypto.Channel(key, phoneNonce, tvNonce, EditorCrypto.INFO_PHONE_TO_TV);
            EditorCrypto.Channel outgoing = new EditorCrypto.Channel(key, phoneNonce, tvNonce, EditorCrypto.INFO_TV_TO_PHONE);
            long deadline = System.currentTimeMillis() + MAX_SESSION_MS;
            while (!stopped && System.currentTimeMillis() < deadline) {
                byte[] frame = EditorWire.read(in, EditorWire.MAX_FRAME);
                if (frame == null) break;
                byte[] plain;
                try {
                    plain = incoming.open(frame);
                } catch (GeneralSecurityException e) {
                    log.line(authenticated ? "session ended: bad frame" : "rejected: wrong key");
                    return authenticated ? Result.SERVED : Result.REJECTED;
                }
                if (!authenticated) {
                    authenticated = true;
                    log.line("phone connected");
                }
                String reply = backend.handle(new String(plain, StandardCharsets.UTF_8));
                if (reply != null) EditorWire.write(out, outgoing.seal(reply.getBytes(StandardCharsets.UTF_8)));
            }
        } catch (SocketTimeoutException e) {
            log.line(authenticated ? "phone went quiet; closing" : "rejected: no hello");
        } catch (IOException | GeneralSecurityException | RuntimeException e) {
            if (!stopped) log.line("session ended: " + e.getMessage());
        }
        return authenticated ? Result.SERVED : Result.REJECTED;
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c == null) return;
        try {
            c.close();
        } catch (IOException ignored) {
        }
    }
}
