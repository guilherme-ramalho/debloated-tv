package com.guilhermeramalho.tvplayback;
import android.content.*;
public final class SetupReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        if("com.guilhermeramalho.tvplayback.OPEN_PAIRING".equals(i.getAction())) PlaybackRuntime.get(c).openPairing();
    }
}
