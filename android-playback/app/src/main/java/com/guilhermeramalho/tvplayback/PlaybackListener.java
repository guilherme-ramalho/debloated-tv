package com.guilhermeramalho.tvplayback;
import android.service.notification.NotificationListenerService;
public final class PlaybackListener extends NotificationListenerService {
    @Override public void onListenerConnected() { PlaybackRuntime.get(this).attach(); }
    @Override public void onListenerDisconnected() { PlaybackRuntime.get(this).detach(); }
    // Notification contents are intentionally never inspected, transmitted or stored.
}
