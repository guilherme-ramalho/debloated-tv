package com.guilhermeramalho.tvplayback;

import android.app.Activity;
import android.os.Bundle;

/** A no-display entry point opened through the already paired Android TV remote. */
public final class WatchActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        PlaybackRuntime.request(this);
        finishAndRemoveTask();
    }
}
