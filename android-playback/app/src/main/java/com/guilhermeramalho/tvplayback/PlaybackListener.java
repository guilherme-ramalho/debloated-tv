package com.guilhermeramalho.tvplayback;
import android.service.notification.NotificationListenerService;
public final class PlaybackListener extends NotificationListenerService {
    @Override public void onListenerConnected() {
        PlaybackRuntime runtime=PlaybackRuntime.current();
        if(runtime==null){requestUnbind();new android.os.Handler(getMainLooper()).postDelayed(()->{
            if(PlaybackRuntime.current()==null)android.os.Process.killProcess(android.os.Process.myPid());
        },1000);return;}
        runtime.attach(this);
    }
    @Override public void onListenerDisconnected() { PlaybackRuntime runtime=PlaybackRuntime.current();if(runtime!=null)runtime.detach(); }
    // Notification contents are intentionally never inspected, transmitted or stored.
}
