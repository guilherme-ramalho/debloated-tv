package com.gathin.tvhome;

import android.accessibilityservice.AccessibilityService;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.provider.Settings;

/**
 * The phone's sleep timer (editor request sleepTimer), owned by the TV so it finishes after the phone disconnects.
 * One AlarmManager alarm, nothing polling: when it fires, the bound remote-key helper (HomeKeyService or
 * InputKeyService) performs GLOBAL_ACTION_LOCK_SCREEN, which puts an Android TV in standby (Android 9 and later).
 * Without a bound helper the request is refused rather than accepted and never run.
 *
 * Reboot: alarms don't survive one, so the saved deadline carries the boot count it was set in and counts as no timer
 * after a reboot (the TV was off anyway).
 */
final class SleepTimer {
    static final int MAX_MINUTES = 240;
    private static final String PREFS = "sleep_timer";
    private static final String DEADLINE = "deadline";
    private static final String BOOT = "boot";
    private static final String ACTION = "com.gathin.tvhome.SLEEP_TIMER";

    private SleepTimer() {}

    /** True when a helper is bound that can put the TV in standby. */
    static boolean available() {
        return Build.VERSION.SDK_INT >= 28 && helper() != null;
    }

    private static AccessibilityService helper() {
        AccessibilityService s = HomeKeyService.bound();
        return s != null ? s : InputKeyService.bound();
    }

    /** The confirmed deadline in Unix milliseconds, or 0 when no timer is set in this boot. */
    static long deadline(Context ctx) {
        SharedPreferences p = prefs(ctx);
        long at = p.getLong(DEADLINE, 0);
        return active(at, p.getInt(BOOT, -1), bootCount(ctx), System.currentTimeMillis()) ? at : 0;
    }

    static boolean active(long deadline, int savedBoot, int boot, long now) {
        return deadline > now && savedBoot == boot;
    }

    /** Sets the timer to minutes from now (1–240), or cancels it with 0. Throws if the TV can't honour it. */
    static void set(Context ctx, int minutes) {
        if (minutes < 0 || minutes > MAX_MINUTES) throw new IllegalArgumentException("Choose between 1 and 240 minutes.");
        Context app = ctx.getApplicationContext();
        AlarmManager alarms = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
        PendingIntent pending = pending(app);
        if (minutes == 0) {
            if (alarms != null) alarms.cancel(pending);
            prefs(app).edit().clear().apply();
            return;
        }
        if (alarms == null || !available()) {
            throw new IllegalArgumentException("This TV can't switch off on a timer from Home: its remote-key helper isn't on. Use the TV's own sleep timer.");
        }
        long at = System.currentTimeMillis() + minutes * 60_000L;
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending);
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending);   // within a few minutes
        }
        prefs(app).edit().putLong(DEADLINE, at).putInt(BOOT, bootCount(app)).apply();
    }

    /** The alarm: standby now, and forget the timer. */
    static void fire(Context ctx) {
        prefs(ctx).edit().clear().apply();
        AccessibilityService s = helper();
        if (s != null && Build.VERSION.SDK_INT >= 28) s.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN);
    }

    private static PendingIntent pending(Context ctx) {
        Intent intent = new Intent(ctx, Receiver.class).setAction(ACTION);
        return PendingIntent.getBroadcast(ctx, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static int bootCount(Context ctx) {
        return Settings.Global.getInt(ctx.getContentResolver(), Settings.Global.BOOT_COUNT, -1);
    }

    /** Not exported: only this app's own alarm reaches it. */
    public static final class Receiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (ACTION.equals(intent.getAction())) fire(context);
        }
    }
}
