package com.gathin.tvhome;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class TvLocationTest {
    @Test
    public void coordinatesAreRoundedToAboutOneKilometre() {
        assertEquals(41.65, TvLocation.round(41.6523), 0.0);
        assertEquals(-4.72, TvLocation.round(-4.7245), 0.0);
        assertEquals("41.65,-4.72", TvLocation.key(41.6523, -4.7245));
    }

    @Test
    public void anUnknownPlaceHasNoKey() {
        assertEquals("", TvLocation.key(Double.NaN, 2.0));
        assertEquals("", TvLocation.key(91.0, 2.0));
    }
}
