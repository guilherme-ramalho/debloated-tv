package com.gathin.tvhome;

import org.junit.Test;
import static org.junit.Assert.*;

public class HomeWeatherDataTest {
    @Test public void cacheMustBeRecentAndCannotComeFromTheFuture() {
        long now = 100_000_000;
        HomeWeatherData d = new HomeWeatherData(18, 17, now);
        assertTrue(d.fresh(now));
        assertFalse(d.usable(now - 1));
        assertFalse(d.fresh(now + HomeWeatherData.REFRESH_MS));
        assertTrue(d.usable(now + HomeWeatherData.MAX_CACHE_MS));
        assertFalse(d.usable(now + HomeWeatherData.MAX_CACHE_MS + 1));
    }
    @Test public void cachedValuesAreClearlyMarkedAndRounded() {
        HomeWeatherData d = new HomeWeatherData(18.2, 16.8, 1);
        assertEquals("18°C  ·  Feels like 17°C", d.label("%1$d°C  ·  Feels like %2$d°C", "cached", false, java.util.Locale.ROOT));
        assertEquals("18°C  ·  Sensación térmica 17°C", d.label("%1$d°C  ·  Sensación térmica %2$d°C", "en caché", false, new java.util.Locale("es")));
        assertTrue(d.label("%1$d°C  ·  Feels like %2$d°C", "cached", true, java.util.Locale.ROOT).endsWith("cached"));
    }
    @Test public void badWeatherValuesAreRejected() {
        for (double bad : new double[] {Double.NaN, Double.POSITIVE_INFINITY, -101, 71}) {
            try {
                new HomeWeatherData(bad, 10, 1);
                fail("Invalid data must not reach the weather label");
            } catch (IllegalArgumentException expected) { }
        }
    }
    @Test public void coordinatesMustBeFiniteAndInRange() {
        assertTrue(HomeWeatherData.validLocation(41.65541, -4.72353));
        assertFalse(HomeWeatherData.validLocation(Double.NaN, -4.7));
        assertFalse(HomeWeatherData.validLocation(91, 0));
        assertFalse(HomeWeatherData.validLocation(0, 181));
        assertFalse(HomeWeatherData.validLocation(0, Double.NEGATIVE_INFINITY));
    }
    @Test public void conditionIconsFollowWeatherAndTimeOfDay() {
        assertEquals("sun", new HomeWeatherData(18, 17, 1, 0, true).icon());
        assertEquals("moon", new HomeWeatherData(18, 17, 1, 0, false).icon());
        assertEquals("partly", new HomeWeatherData(18, 17, 1, 2, true).icon());
        assertEquals("cloud", new HomeWeatherData(18, 17, 1, 3, true).icon());
        assertEquals("rain", new HomeWeatherData(18, 17, 1, 63, true).icon());
        assertEquals("snow", new HomeWeatherData(0, -2, 1, 85, true).icon());
        assertEquals("storm", new HomeWeatherData(18, 17, 1, 95, true).icon());
        assertEquals("fog", new HomeWeatherData(10, 9, 1, 45, true).icon());
        assertEquals("", new HomeWeatherData(18, 17, 1, -1, true).icon());
    }
}
