package com.guilhermeramalho.tvplayback;

import android.content.*;
import android.media.MediaMetadata;
import android.media.session.*;
import android.media.tv.*;
import android.os.*;
import android.provider.Settings;
import android.security.keystore.*;
import org.json.*;
import javax.net.ssl.*;
import javax.security.auth.x500.X500Principal;
import java.io.*;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.cert.*;
import java.security.interfaces.RSAPublicKey;
import java.util.*;
import java.util.concurrent.*;

/** A read-only media-session bridge. No notification data, command execution or viewing history API. */
final class PlaybackRuntime {
    static final int PORT=9765;
    private static PlaybackRuntime instance;
    static synchronized PlaybackRuntime current(){return instance;}
    static synchronized PlaybackRuntime get(Context c){if(instance==null)instance=new PlaybackRuntime(c.getApplicationContext());return instance;}
    static PlaybackRuntime request(Context c){PlaybackRuntime r=get(c);r.leaseUntil=SystemClock.elapsedRealtime()+20000;android.service.notification.NotificationListenerService.requestRebind(new ComponentName(c,PlaybackListener.class));return r;}
    private final Context context;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final SharedPreferences prefs;
    private final MediaSessionManager sessions;
    private final List<MediaController> controllers=new ArrayList<>();
    private final Set<Client> clients=ConcurrentHashMap.newKeySet();
    private final Semaphore slots=new Semaphore(3);
    private volatile long pairUntil;
    private volatile String pairCode="",candidate="",serverError="";
    private byte[] expectedProof;
    private int attempts;
    private boolean attached;
    private PlaybackListener listener;
    private volatile long leaseUntil=SystemClock.elapsedRealtime()+20000;
    private volatile boolean stopping;
    private boolean setupVisible;
    private SSLServerSocket serverSocket;
    private TvInputManager.TvInputCallback inputCallback;
    void setupVisible(boolean visible){setupVisible=visible;if(!visible)leaseUntil=SystemClock.elapsedRealtime()+3000;}
    private void stopIfIdle(){
        if(stopping||setupVisible||pairingOpen()||SystemClock.elapsedRealtime()<leaseUntil||clients.stream().anyMatch(cl->cl.trusted&&cl.visible))return;
        stopping=true;detach();if(listener!=null)listener.requestUnbind();
        for(Client cl:clients)cl.close();
        try{if(serverSocket!=null)serverSocket.close();}catch(IOException ignored){}
        TvInputManager inputs=(TvInputManager)context.getSystemService(Context.TV_INPUT_SERVICE);if(inputs!=null&&inputCallback!=null)inputs.unregisterCallback(inputCallback);
        main.removeCallbacksAndMessages(null);
        // requestUnbind prevents Android from keeping or restarting the listener.
        // End this dedicated process as well, rather than retaining a cached setup UI.
        main.postDelayed(()->android.os.Process.killProcess(android.os.Process.myPid()),300);
    }
    private java.security.cert.Certificate serverCertificate;
    private final MediaController.Callback callback=new MediaController.Callback(){
        @Override public void onMetadataChanged(MediaMetadata data){publish();}
        @Override public void onPlaybackStateChanged(PlaybackState state){publish();}
        @Override public void onSessionDestroyed(){reload();}
    };
    private final MediaSessionManager.OnActiveSessionsChangedListener sessionsChanged=list->reload();
    private PlaybackRuntime(Context c){
        context=c;prefs=c.getSharedPreferences("paired-clients",Context.MODE_PRIVATE);sessions=(MediaSessionManager)c.getSystemService(Context.MEDIA_SESSION_SERVICE);
        thread("tv-playback-tls",this::listen).start();
        TvInputManager inputs=(TvInputManager)c.getSystemService(Context.TV_INPUT_SERVICE);
        inputCallback=new TvInputManager.TvInputCallback(){
            @Override public void onInputAdded(String id){publish();}
            @Override public void onInputRemoved(String id){publish();}
            @Override public void onInputUpdated(String id){publish();}
            @Override public void onInputStateChanged(String id,int state){publish();}
        };if(inputs!=null)inputs.registerCallback(inputCallback,main);
        main.post(new Runnable(){public void run(){
            // Input selection has no public callback on Android 11. Poll the TCL input property
            // only while an authenticated phone is viewing HDMI information.
            stopIfIdle();if(stopping)return;
            if(clients.stream().anyMatch(cl->cl.visible&&isTv(cl.foreground)))publish();
            main.postDelayed(this,2000);
        }});
    }
    boolean accessEnabled(){String enabled=Settings.Secure.getString(context.getContentResolver(),"enabled_notification_listeners");if(enabled==null)return false;ComponentName ours=new ComponentName(context,PlaybackListener.class);for(String value:enabled.split(":"))if(ours.equals(ComponentName.unflattenFromString(value)))return true;return false;}
    void attach(PlaybackListener service){listener=service;if(!attached){attached=true;try{sessions.addOnActiveSessionsChangedListener(sessionsChanged,new ComponentName(context,PlaybackListener.class),main);}catch(SecurityException e){attached=false;}}reload();}
    void detach(){attached=false;try{sessions.removeOnActiveSessionsChangedListener(sessionsChanged);}catch(Exception ignored){}for(MediaController c:controllers)c.unregisterCallback(callback);controllers.clear();publish();}
    private void reload(){
        for(MediaController c:controllers)c.unregisterCallback(callback);controllers.clear();
        if(attached)try{controllers.addAll(sessions.getActiveSessions(new ComponentName(context,PlaybackListener.class)));for(MediaController c:controllers)c.registerCallback(callback,main);}catch(SecurityException ignored){}
        publish();
    }
    synchronized void openPairing(){pairUntil=SystemClock.elapsedRealtime()+120000;candidate="";pairCode="";expectedProof=null;attempts=0;}
    private boolean pairingOpen(){return SystemClock.elapsedRealtime()<pairUntil;}
    String pairingText(){if(!serverError.isEmpty())return serverError;if(!pairingOpen())return "Open On TV in the iPhone app to connect playback information.";return pairCode.isEmpty()?"Ready for iPhone. Tap Connect playback information on your phone.":"Enter this code on your iPhone:  "+pairCode;}
    private Set<String> allowed(){return new HashSet<>(prefs.getStringSet("clients",Collections.emptySet()));}
    private static Thread thread(String name,Runnable r){Thread t=new Thread(r,name);t.setDaemon(true);return t;}
    private SSLContext tls() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        String alias="tv-playback-server-v2";
        if(store.containsAlias("tv-playback-server-v1"))store.deleteEntry("tv-playback-server-v1");
        if(!store.containsAlias(alias)){
            KeyPairGenerator gen=KeyPairGenerator.getInstance("RSA","AndroidKeyStore");
            gen.initialize(new KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_SIGN|KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(2048).setDigests(KeyProperties.DIGEST_NONE,KeyProperties.DIGEST_SHA256,KeyProperties.DIGEST_SHA384,KeyProperties.DIGEST_SHA512)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1,KeyProperties.ENCRYPTION_PADDING_NONE)
                .setCertificateSubject(new X500Principal("CN=TV Playback"))
                .setCertificateSerialNumber(new BigInteger(96,new SecureRandom()))
                .setCertificateNotBefore(new Date(System.currentTimeMillis()-86400000L))
                .setCertificateNotAfter(new Date(System.currentTimeMillis()+10L*365*86400000L)).build());gen.generateKeyPair();
        }
        serverCertificate=store.getCertificate(alias);
        KeyManagerFactory keys=KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());keys.init(store,null);
        X509TrustManager trust=new X509TrustManager(){
            public X509Certificate[] getAcceptedIssuers(){return new X509Certificate[0];}
            public void checkServerTrusted(X509Certificate[] chain,String auth) throws CertificateException{throw new CertificateException("Not a client");}
            public void checkClientTrusted(X509Certificate[] chain,String auth) throws CertificateException {
                try{if(chain.length==0||!(chain[0].getPublicKey() instanceof RSAPublicKey)||((RSAPublicKey)chain[0].getPublicKey()).getModulus().bitLength()<2048)throw new CertificateException("Invalid client identity");
                    if(!allowed().contains(PairProof.fingerprint(chain[0]))&&!pairingOpen())throw new CertificateException("Pair the phone on the TV first");
                }catch(GeneralSecurityException e){throw new CertificateException(e);}
            }
        };
        SSLContext ssl=SSLContext.getInstance("TLS");ssl.init(keys.getKeyManagers(),new TrustManager[]{trust},new SecureRandom());return ssl;
    }
    private void listen(){
        try(SSLServerSocket server=(SSLServerSocket)tls().getServerSocketFactory().createServerSocket(PORT)){
            serverSocket=server;
            server.setEnabledProtocols(new String[]{"TLSv1.2"});server.setNeedClientAuth(true);
            while(true){SSLSocket socket=(SSLSocket)server.accept();if(!slots.tryAcquire()){socket.close();continue;}
                thread("tv-playback-client",()->{Client client=null;try{socket.setSoTimeout(15000);socket.setTcpNoDelay(true);socket.startHandshake();client=new Client(socket);clients.add(client);client.run();}catch(Exception ignored){}finally{if(client!=null){clients.remove(client);client.close();}else try{socket.close();}catch(IOException ignored){}slots.release();}}).start();
            }
        }catch(Exception e){if(!stopping){serverError="Playback server could not start: "+e.getClass().getSimpleName();android.util.Log.e("TVPlayback","Server startup failed",e);}}
    }
    private synchronized void beginPair(Client cl) throws Exception {
        if(!pairingOpen())throw new IOException("Open Connect iPhone on the TV first");
        if(!candidate.isEmpty()&&!candidate.equals(cl.fingerprint))throw new IOException("Another phone is pairing");
        if(expectedProof==null){byte[] suffix=new byte[2];new SecureRandom().nextBytes(suffix);expectedProof=PairProof.proof((RSAPublicKey)cl.certificate.getPublicKey(),(RSAPublicKey)serverCertificate.getPublicKey(),suffix);candidate=cl.fingerprint;pairCode=PairProof.code(expectedProof,suffix);}
        cl.send(new JSONObject().put("type","code"));
    }
    private synchronized void finishPair(Client cl,String value) throws Exception {
        if(!pairingOpen()||!candidate.equals(cl.fingerprint)||expectedProof==null||attempts>=3)throw new IOException("Pairing expired");
        attempts++;byte[] submitted;try{submitted=java.util.Base64.getDecoder().decode(value);}catch(IllegalArgumentException e){submitted=new byte[0];}
        if(!MessageDigest.isEqual(expectedProof,submitted)){if(attempts>=3)pairUntil=0;throw new IOException("Code did not match");}
        Set<String> keys=allowed();if(keys.size()>=8&&!keys.contains(cl.fingerprint))throw new IOException("Paired phone limit reached");keys.add(cl.fingerprint);prefs.edit().putStringSet("clients",keys).apply();
        cl.trusted=true;cl.socket.setSoTimeout(45000);pairUntil=0;pairCode="";expectedProof=null;cl.send(new JSONObject().put("type","paired"));
    }
    private void publish(){for(Client cl:clients)if(cl.trusted)cl.snapshot();}
    private static boolean isTv(String pkg){return pkg.equals("com.tcl.tv")||pkg.equals("com.tcl.tvinput");}
    private static String clean(CharSequence text){if(text==null)return "";String s=text.toString().replaceAll("[\\p{Cntrl}&&[^\\n]]","").trim();return s.length()>512?s.substring(0,512):s;}
    private String label(String pkg){try{return clean(context.getPackageManager().getApplicationLabel(context.getPackageManager().getApplicationInfo(pkg,0)));}catch(Exception e){return pkg;}}
    private String currentInput(){try{java.lang.Process p=new ProcessBuilder("/system/bin/getprop","persist.sys.curInput").start();try(BufferedReader r=new BufferedReader(new InputStreamReader(p.getInputStream()))){String s=r.readLine();return s==null?"":s.trim();}finally{p.destroy();}}catch(Exception e){return "";}}
    private JSONObject state(String foreground) throws Exception {
        JSONObject result=new JSONObject().put("type","state").put("access",attached&&accessEnabled());
        String pkg=foreground;
        MediaController selected=null;
        for(MediaController c:controllers)if(c.getPackageName().equals(pkg)){selected=c;break;}
        if(pkg.isEmpty())for(MediaController c:controllers){PlaybackState p=c.getPlaybackState();if(p!=null&&(p.getState()==PlaybackState.STATE_PLAYING||p.getState()==PlaybackState.STATE_PAUSED)){selected=c;pkg=c.getPackageName();break;}}
        String title="",playback="unknown",source=label(pkg),kind="app",inputLabel="";
        if(selected!=null){MediaMetadata m=selected.getMetadata();if(m!=null){title=clean(m.getText(MediaMetadata.METADATA_KEY_DISPLAY_TITLE));if(title.isEmpty())title=clean(m.getText(MediaMetadata.METADATA_KEY_TITLE));if(title.equalsIgnoreCase(source))title="";}
            PlaybackState p=selected.getPlaybackState();if(p!=null){if(p.getState()==PlaybackState.STATE_PLAYING)playback="playing";else if(p.getState()==PlaybackState.STATE_PAUSED)playback="paused";else if(p.getState()==PlaybackState.STATE_BUFFERING)playback="buffering";}}
        if(isTv(pkg)){
            kind="hdmi";String current=currentInput();TvInputManager manager=(TvInputManager)context.getSystemService(Context.TV_INPUT_SERVICE);
            TvInputInfo match=null;List<TvInputInfo> inputs=manager==null?Collections.emptyList():manager.getTvInputList();
            for(TvInputInfo info:inputs)if(info.getId().equals(current)){match=info;break;}
            if(match!=null){TvInputInfo device=match;for(TvInputInfo info:inputs)if(match.getId().equals(info.getParentId())){device=info;break;}
                source=clean(device.loadLabel(context));if(source.isEmpty())source=clean(device.loadCustomLabel(context));
                TvInputInfo port=match;for(TvInputInfo info:inputs)if(info.getId().equals(device.getParentId()))port=info;
                inputLabel=clean(port.loadLabel(context));if(device==port){String custom=clean(device.loadCustomLabel(context));if(!custom.isEmpty())source=custom;}
                if(match.getType()!=TvInputInfo.TYPE_HDMI){kind="input";source=clean(match.loadLabel(context));}
            }else source="TV input";
            title="";playback="unknown";
        }else if(pkg.equals("com.gathin.tvhome")||pkg.equals("com.google.android.apps.tv.launcherx")){kind="home";source="Home";title="";playback="unknown";}
        else if(pkg.isEmpty()){kind="none";source="TV";}
        return result.put("kind",kind).put("package",pkg).put("source",source).put("title",title).put("playback",playback).put("input",inputLabel);
    }
    private final class Client {
        final SSLSocket socket;
        final X509Certificate certificate;
        final String fingerprint;
        volatile boolean trusted,visible;
        volatile String foreground="";
        String last="";
        final ExecutorService writes=new ThreadPoolExecutor(1,1,0L,TimeUnit.MILLISECONDS,new ArrayBlockingQueue<>(8),r->thread("tv-playback-write",r),new ThreadPoolExecutor.AbortPolicy());
        Client(SSLSocket s) throws Exception{socket=s;certificate=(X509Certificate)s.getSession().getPeerCertificates()[0];fingerprint=PairProof.fingerprint(certificate);trusted=allowed().contains(fingerprint);}
        void send(JSONObject obj){String text=obj.toString();try{writes.execute(()->{try{Frames.write(socket.getOutputStream(),text.getBytes(StandardCharsets.UTF_8));}catch(IOException e){close();}});}catch(RejectedExecutionException e){close();}}
        void snapshot(){main.post(()->{if(!trusted||socket.isClosed())return;try{JSONObject data=state(foreground);String value=data.toString();if(!last.equals(value)){last=value;send(data);}}catch(Exception ignored){}});}
        void run() throws Exception {
            socket.setSoTimeout(trusted?45000:125000);
            while(!socket.isClosed()){
                JSONObject request=new JSONObject(new String(Frames.read(socket.getInputStream()),StandardCharsets.UTF_8));String type=request.optString("type");
                try{
                    if(type.equals("pair")){beginPair(this);continue;}
                    if(type.equals("proof")){finishPair(this,request.optString("proof"));continue;}
                    if(!trusted)throw new IOException("Pairing required");
                    if(type.equals("watch")){String value=request.optString("package");if(!value.isEmpty()&&!value.matches("[A-Za-z0-9_.]{1,180}"))throw new IOException("Invalid package");foreground=value;visible=request.optBoolean("visible");if(!visible){leaseUntil=SystemClock.elapsedRealtime()+1000;return;}leaseUntil=0;last="";snapshot();}
                    else if(type.equals("ping"))send(new JSONObject().put("type","pong"));
                    else throw new IOException("Unknown request");
                }catch(Exception e){send(new JSONObject().put("type","error").put("message",e.getMessage()==null?"Request failed":e.getMessage()));}
            }
        }
        void close(){try{socket.close();}catch(IOException ignored){}writes.shutdownNow();}
    }
}
