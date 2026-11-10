package com.gathin.tvhome;

import android.Manifest;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.location.Address;
import android.location.Geocoder;
import android.location.Location;
import android.location.LocationManager;
import android.os.Build;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;

import java.util.List;
import java.util.Locale;

/**
 * Where the TV is, roughly, for the weather (config weather.auto). Android TV places itself from nearby Wi-Fi networks
 * (Google's network location), so no city has to be typed in. Coordinates are rounded to 2 decimals (about 1 km)
 * before they are kept or sent anywhere.
 *
 * Cost: reading the last known fix is a local call. Only when the TV has none, and at most once every 6 hours while
 * Home is on screen, it asks for one fix (a Wi-Fi scan and one request by the TV's location service), with no
 * continuous updates. The place name comes from the Geocoder once per new place, on the weather worker thread.
 */
final class TvLocation {
    static final long ASK_EVERY_MS = 6 * 60 * 60 * 1000L;
    private static final long ASK_TIMEOUT_MS = 30_000L;
    private static final String PREFS = "tv_location";

    private TvLocation() {}

    static double round(double value) {
        return Math.round(value * 100.0) / 100.0;
    }

    /** "lat,lon" with rounded coordinates, or "" when the TV doesn't know where it is (or may not say). */
    static String key(double latitude, double longitude) {
        return HomeWeatherData.validLocation(latitude, longitude) ? round(latitude) + "," + round(longitude) : "";
    }

    static boolean permitted(Context ctx) {
        return ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                || ctx.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    /** The newest fix any provider has, rounded; then the last one kept here; else null. Never blocks. */
    static double[] current(Context ctx) {
        Location best = null;
        if (permitted(ctx)) {
            LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
            if (lm != null) {
                try {
                    for (String provider : lm.getProviders(true)) {
                        Location l = lm.getLastKnownLocation(provider);
                        if (l != null && (best == null || l.getTime() > best.getTime())) best = l;
                    }
                } catch (RuntimeException ignored) {
                    // SecurityException or a provider that went away: fall back to the kept fix.
                }
            }
        }
        SharedPreferences p = prefs(ctx);
        if (best != null && HomeWeatherData.validLocation(best.getLatitude(), best.getLongitude())) {
            double lat = round(best.getLatitude()), lon = round(best.getLongitude());
            if (!key(lat, lon).equals(p.getString("key", ""))) {
                p.edit().putString("key", key(lat, lon)).putString("lat", Double.toString(lat))
                        .putString("lon", Double.toString(lon)).remove("place").apply();
            }
            return new double[] {lat, lon};
        }
        try {
            double lat = Double.parseDouble(p.getString("lat", "NaN")), lon = Double.parseDouble(p.getString("lon", "NaN"));
            return HomeWeatherData.validLocation(lat, lon) ? new double[] {lat, lon} : null;
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** Asks the network provider for one fix when allowed and not asked recently. The answer lands in current(). */
    static void askOnce(Context ctx, Runnable then) {
        if (Build.VERSION.SDK_INT < 30 || !permitted(ctx)) return;
        SharedPreferences p = prefs(ctx);
        long now = System.currentTimeMillis();
        if (now - p.getLong("asked_at", 0) < ASK_EVERY_MS) return;
        LocationManager lm = (LocationManager) ctx.getSystemService(Context.LOCATION_SERVICE);
        if (lm == null) return;
        String provider = lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ? LocationManager.NETWORK_PROVIDER : null;
        if (provider == null) return;
        p.edit().putLong("asked_at", now).apply();
        Handler main = new Handler(Looper.getMainLooper());
        CancellationSignal cancel = new CancellationSignal();
        main.postDelayed(cancel::cancel, ASK_TIMEOUT_MS);
        try {
            lm.getCurrentLocation(provider, cancel, ctx.getMainExecutor(), location -> {
                if (location == null) return;
                current(ctx);   // the provider keeps it as its last known fix; this rounds and stores it
                if (then != null) then.run();
            });
        } catch (RuntimeException ignored) {
            // No permission after all, or the provider vanished: weather stays hidden.
        }
    }

    /** The place name for the kept fix, looked up once (blocking: call it off the main thread). "" if unknown. */
    static String place(Context ctx, double latitude, double longitude) {
        SharedPreferences p = prefs(ctx);
        String key = key(latitude, longitude);
        String kept = p.getString("place", null);
        if (kept != null && key.equals(p.getString("place_key", ""))) return kept;
        String name = "";
        try {
            if (Geocoder.isPresent()) {
                List<Address> found = new Geocoder(ctx, Locale.getDefault()).getFromLocation(latitude, longitude, 1);
                if (found != null && !found.isEmpty()) {
                    Address a = found.get(0);
                    name = a.getLocality() != null ? a.getLocality()
                            : a.getSubAdminArea() != null ? a.getSubAdminArea() : a.getAdminArea() != null ? a.getAdminArea() : "";
                }
            }
        } catch (Exception ignored) {
            // No Geocoder backend or no network: the weather still shows, without a place name.
        }
        if (name.length() > 60) name = name.substring(0, 60);
        if (!name.isEmpty()) p.edit().putString("place", name).putString("place_key", key).apply();
        return name;
    }

    /** The kept place name, without looking anything up. */
    static String keptPlace(Context ctx) {
        SharedPreferences p = prefs(ctx);
        return p.getString("place_key", "").equals(p.getString("key", "")) ? p.getString("place", "") : "";
    }

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
