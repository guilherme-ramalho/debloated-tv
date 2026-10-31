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

/** Personal launcher fork: weather is fetched only while Home is resumed. No service or alarm. */
final class HomeWeather {
    private final TextView view;
    private final View row;
    private final ImageView icon;
    private final SharedPreferences cache;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final String location;
    private final String endpoint;
    private final String city;
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
        this.city = city;
        cache = context.getSharedPreferences("home_weather", Context.MODE_PRIVATE);
        boolean enabled = !city.isEmpty() && HomeWeatherData.validLocation(latitude, longitude);
        row.setVisibility(enabled ? View.VISIBLE : View.GONE);
        location = enabled ? latitude + "," + longitude : "";
        endpoint = enabled ? "https://api.open-meteo.com/v1/forecast?latitude=" + latitude
                + "&longitude=" + longitude + "&current=temperature_2m,apparent_temperature,weather_code,is_day"
                + "&temperature_unit=celsius&forecast_days=1&timezone=auto" : "";
        if (enabled && location.equals(cache.getString("location", ""))) {
            try {
                data = new HomeWeatherData(Double.parseDouble(cache.getString("temperature", "NaN")),
                        Double.parseDouble(cache.getString("feels_like", "NaN")), cache.getLong("fetched_at", 0),
                        cache.getInt("weather_code", -1), cache.getBoolean("is_day", true));
            } catch (IllegalArgumentException invalidCache) { data = null; }
        }
    }

    void start() {
        if (endpoint.isEmpty() || active) return;
        active = true;
        if (worker == null || worker.isShutdown()) worker = Executors.newSingleThreadExecutor();
        render();
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
        request = worker.submit(() -> {
            HomeWeatherData result = null;
            try { result = fetch(); } catch (Exception unavailable) { /* Cached values or the unavailable label. */ }
            final HomeWeatherData fetched = result;
            handler.post(() -> {
                if (!active || token != generation) return;
                request = null;
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

    private HomeWeatherData fetch() throws Exception {
        HttpsURLConnection current = (HttpsURLConnection) new URL(endpoint).openConnection();
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
            view.setContentDescription(city + ": " + line);
        } else {
            icon.setVisibility(View.GONE);
            view.setText(failed ? R.string.weather_unavailable : R.string.weather_loading);
        }
    }
}
