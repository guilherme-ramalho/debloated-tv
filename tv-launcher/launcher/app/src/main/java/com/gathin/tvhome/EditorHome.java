package com.gathin.tvhome;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;

import java.lang.ref.WeakReference;

/**
 * Lets a layout applied from the phone show at once. Home bumps nothing itself: the editor raises the Launcher
 * settings change count, which a Home in the background picks up in onResume; a Home on screen is rebuilt here.
 */
final class EditorHome {
    private static WeakReference<Activity> resumed = new WeakReference<>(null);

    private EditorHome() {}

    static void resumed(Activity home) {
        resumed = new WeakReference<>(home);
    }

    static void paused(Activity home) {
        if (resumed.get() == home) resumed = new WeakReference<>(null);
    }

    static void rebuild() {
        new Handler(Looper.getMainLooper()).post(() -> {
            Activity home = resumed.get();
            if (home != null && !home.isFinishing() && !home.isDestroyed()) home.recreate();
        });
    }
}
