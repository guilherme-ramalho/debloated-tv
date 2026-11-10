package com.gathin.tvhome;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.TextView;
import android.widget.ImageView;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import javax.net.ssl.HttpsURLConnection;

/**
 * Personal launcher fork: weather is fetched only while Home is resumed. No service or alarm.
 * Two modes: a typed city with its coordinates (weather.city, latitude, longitude), or weather.auto, where the TV's own
 * rough location is used (TvLocation) and the row stays hidden until the TV knows where it is.
 */
final class HomeWeather {
    private final TextView view;
    private final View row;
    private final ImageView icon;
    private final SharedPreferences cache;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Context app;
    private final boolean auto;
    private String location;
    private String endpoint;
    private String city;
    private double latitude = Double.NaN;
    private double longitude = Double.NaN;
    private ExecutorService worker;
    private Future<?> request;
    private volatile HttpsURLConnection connection;
    private boolean active;
    private int generation;
    private boolean failed;
    private long retryAt;
    private HomeWeatherData data;
    private final Runnable refresh = this::refresh;

    HomeWeather(Context context, TextView view, View row, ImageView icon, JSONObject settings) {
        String city = settings != null && settings.optBoolean("enabled", false)
                ? settings.optString("city", "").trim() : "";
        double latitude = settings == null ? Double.NaN : settings.optDouble("latitude", Double.NaN);
        double longitude = settings == null ? Double.NaN : settings.optDouble("longitude", Double.NaN);
        this.view = view;
        this.row = row;
        this.icon = icon;
        this.app = context.getApplicationContext();
        this.auto = settings != null && settings.optBoolean("enabled", false) && settings.optBoolean("auto", false);
        this.city = city;
        cache = context.getSharedPreferences("home_weather", Context.MODE_PRIVATE);
        if (auto) {
            double[] here = TvLocation.current(app);
            if (here != null) { latitude = here[0]; longitude = here[1]; }
            this.city = TvLocation.keptPlace(app);
        }
        this.latitude = latitude;
        this.longitude = longitude;
        boolean enabled = (auto || !city.isEmpty()) && HomeWeatherData.validLocation(latitude, longitude);
        row.setVisibility(enabled ? View.VISIBLE : View.GONE);
        point(enabled);
        if (enabled && location.equals(cache.getString("location", ""))) {
            try {
                data = new HomeWeatherData(Double.parseDouble(cache.getString("temperature", "NaN")),
                        Double.parseDouble(cache.getString("feels_like", "NaN")), cache.getLong("fetched_at", 0),
                        cache.getInt("weather_code", -1), cache.getBoolean("is_day", true));
            } catch (IllegalArgumentException invalidCache) { data = null; }
        }
    }

    private void point(boolean enabled) {
        location = enabled ? latitude + "," + longitude : "";
        endpoint = enabled ? "https://api.open-meteo.com/v1/forecast?latitude=" + latitude
                + "&longitude=" + longitude + "&current=temperature_2m,apparent_temperature,weather_code,is_day"
                + "&temperature_unit=celsius&forecast_days=1&timezone=auto" : "";
    }

    /** weather.auto: follow the TV's rough location; a new place drops the old reading. False while unknown. */
    private boolean locate() {
        if (!auto) return !endpoint.isEmpty();
        double[] here = TvLocation.current(app);
        if (here == null) {
            TvLocation.askOnce(app, () -> { if (active) refresh(); });
            row.setVisibility(View.GONE);
            return false;
        }
        if (here[0] != latitude || here[1] != longitude) {
            latitude = here[0];
            longitude = here[1];
            point(true);
            city = TvLocation.keptPlace(app);
            if (!location.equals(cache.getString("location", ""))) data = null;
        }
        row.setVisibility(View.VISIBLE);
        return true;
    }

    void start() {
        if ((!auto && endpoint.isEmpty()) || active) return;
        active = true;
        if (worker == null || worker.isShutdown()) worker = Executors.newSingleThreadExecutor();
        if (!endpoint.isEmpty()) render();
        refresh();
    }

    void stop() {
        active = false;
        generation++;
        handler.removeCallbacks(refresh);
        if (request != null) request.cancel(true);
        request = null;
        HttpsURLConnection current = connection;
        if (current != null) current.disconnect();
        if (worker != null) worker.shutdownNow();
    }

    private void refresh() {
        if (!active) return;
        handler.removeCallbacks(refresh);
        if (!locate()) {   // weather.auto and the TV doesn't know where it is yet: look again later, quietly
            handler.postDelayed(refresh, HomeWeatherData.RETRY_MS);
            return;
        }
        long now = System.currentTimeMillis();
        if (now < retryAt) {
            render();
            handler.postDelayed(refresh, retryAt - now);
            return;
        }
        if (data != null && data.weatherCode >= 0 && data.fresh(now)) {
            render();
            handler.postDelayed(refresh, Math.max(1000L, data.fetchedAt + HomeWeatherData.REFRESH_MS - now));
            return;
        }
        int token = generation;
        final String url = endpoint, here = location;
        final double lat = latitude, lon = longitude;
        final boolean named = !auto || !city.isEmpty();
        request = worker.submit(() -> {
            HomeWeatherData result = null;
            try { result = fetch(url); } catch (Exception unavailable) { /* Cached values or the unavailable label. */ }
            final HomeWeatherData fetched = result;
            final String place = named ? null : TvLocation.place(app, lat, lon);
            handler.post(() -> {
                if (!active || token != generation || !here.equals(location)) return;
                request = null;
                if (place != null && !place.isEmpty()) city = place;
                failed = fetched == null;
                if (fetched != null) {
                    data = fetched;
                    retryAt = 0;
                    cache.edit().putString("location", location)
                            .putString("temperature", Double.toString(data.temperature))
                            .putString("feels_like", Double.toString(data.feelsLike))
                            .putLong("fetched_at", data.fetchedAt).putInt("weather_code", data.weatherCode)
                            .putBoolean("is_day", data.isDay).apply();
                } else {
                    retryAt = System.currentTimeMillis() + HomeWeatherData.RETRY_MS;
                }
                render();
                handler.postDelayed(refresh, failed ? HomeWeatherData.RETRY_MS : HomeWeatherData.REFRESH_MS);
            });
        });
    }

    /** The place shown and reported to the phone ("" when the TV hasn't named it). */
    String place() {
        return city;
    }

    private HomeWeatherData fetch(String url) throws Exception {
        HttpsURLConnection current = (HttpsURLConnection) new URL(url).openConnection();
        connection = current;
        current.setConnectTimeout(5000);
        current.setReadTimeout(5000);
        current.setInstanceFollowRedirects(false);
        current.setRequestProperty("User-Agent", "PersonalTVHome/1.0");
        try {
            if (current.getResponseCode() != 200) throw new java.io.IOException("Weather HTTP error");
            try (InputStream input = current.getInputStream(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[1024];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    if (Thread.currentThread().isInterrupted() || output.size() + count > 16384) {
                        throw new java.io.IOException("Weather request canceled or oversized");
                    }
                    output.write(buffer, 0, count);
                }
                JSONObject root = new JSONObject(output.toString(StandardCharsets.UTF_8.name()));
                JSONObject values = root.getJSONObject("current");
                return new HomeWeatherData(values.getDouble("temperature_2m"),
                        values.getDouble("apparent_temperature"), System.currentTimeMillis(),
                        values.getInt("weather_code"), values.getInt("is_day") == 1);
            }
        } finally {
            current.disconnect();
            if (connection == current) connection = null;
        }
    }

    private int iconResource(String kind) {
        switch (kind) {
            case "sun": return R.drawable.weather_sun;
            case "moon": return R.drawable.weather_moon;
            case "partly": return R.drawable.weather_partly;
            case "cloud": return R.drawable.weather_cloud;
            case "rain": return R.drawable.weather_rain;
            case "snow": return R.drawable.weather_snow;
            case "storm": return R.drawable.weather_storm;
            case "fog": return R.drawable.weather_fog;
            default: return 0;
        }
    }

    private void render() {
        long now = System.currentTimeMillis();
        if (data != null && data.usable(now)) {
            boolean cached = failed || !data.fresh(now);
            // The view's own resources follow the launcher's language (the TV's, or config locale), not the JVM default.
            android.content.res.Resources res = view.getResources();
            String line = data.label(res.getString(R.string.weather_label), res.getString(R.string.weather_cached), cached,
                    res.getConfiguration().getLocales().get(0));
            view.setText(line);
            int image = iconResource(data.icon());
            icon.setVisibility(image == 0 ? View.GONE : View.VISIBLE);
            if (image != 0) icon.setImageResource(image);
            view.setContentDescription(city.isEmpty() ? line : city + ": " + line);
        } else {
            icon.setVisibility(View.GONE);
            view.setText(failed ? R.string.weather_unavailable : R.string.weather_loading);
        }
    }
}
