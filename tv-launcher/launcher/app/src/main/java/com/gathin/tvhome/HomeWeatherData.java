package com.gathin.tvhome;

import java.util.Locale;

/** Weather values and cache policy, independent of networking and Android views. */
final class HomeWeatherData {
    static final long REFRESH_MS = 30 * 60 * 1000L;
    static final long RETRY_MS = 5 * 60 * 1000L;
    static final long MAX_CACHE_MS = 6 * 60 * 60 * 1000L;
    final double temperature;
    final double feelsLike;
    final long fetchedAt;
    final int weatherCode;
    final boolean isDay;

    HomeWeatherData(double temperature, double feelsLike, long fetchedAt) {
        this(temperature, feelsLike, fetchedAt, -1, true);
    }
    HomeWeatherData(double temperature, double feelsLike, long fetchedAt, int weatherCode, boolean isDay) {
        this.weatherCode = weatherCode;
        this.isDay = isDay;
        if (!Double.isFinite(temperature) || !Double.isFinite(feelsLike)
                || temperature < -100 || temperature > 70 || feelsLike < -120 || feelsLike > 100) {
            throw new IllegalArgumentException("Invalid weather values");
        }
        this.temperature = temperature;
        this.feelsLike = feelsLike;
        this.fetchedAt = fetchedAt;
    }

    String icon() {
        if (weatherCode == 0) return isDay ? "sun" : "moon";
        if (weatherCode == 1 || weatherCode == 2) return isDay ? "partly" : "cloud";
        if (weatherCode == 3) return "cloud";
        if (weatherCode == 45 || weatherCode == 48) return "fog";
        if ((weatherCode >= 51 && weatherCode <= 67) || (weatherCode >= 80 && weatherCode <= 82)) return "rain";
        if ((weatherCode >= 71 && weatherCode <= 77) || weatherCode == 85 || weatherCode == 86) return "snow";
        if (weatherCode == 95 || weatherCode == 96 || weatherCode == 99) return "storm";
        return "";
    }

    boolean usable(long now) { return fetchedAt > 0 && now >= fetchedAt && now - fetchedAt <= MAX_CACHE_MS; }
    boolean fresh(long now) { return usable(now) && now - fetchedAt < REFRESH_MS; }
    /** The clock-side line in the launcher's language: R.string.weather_label, plus R.string.weather_cached when stale. */
    String label(String pattern, String cachedWord, boolean cached, Locale locale) {
        String line = String.format(locale, pattern, Math.round(temperature), Math.round(feelsLike));
        return cached ? line + "  ·  " + cachedWord : line;
    }
    static boolean validLocation(double latitude, double longitude) {
        return Double.isFinite(latitude) && Double.isFinite(longitude)
                && latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
    }
}
