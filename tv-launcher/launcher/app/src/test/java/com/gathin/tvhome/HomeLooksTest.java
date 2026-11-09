package com.gathin.tvhome;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.Map;

public class HomeLooksTest {
    @Test
    public void everyLookIsASetOfExistingSwitches() {
        for (String look : HomeLooks.NAMES) assertFalse(look, HomeLooks.preset(look).isEmpty());
        assertEquals(Boolean.TRUE, HomeLooks.preset(HomeLooks.CINEMA).get("cinematic_home"));
    }

    @Test
    public void onlyCinemaKeepsTheCinematicShelf() {
        for (String look : HomeLooks.NAMES) {
            Map<String, Object> m = HomeLooks.preset(look);
            assertEquals(look, HomeLooks.CINEMA.equals(look), m.get("cinematic_home"));
        }
    }

    @Test
    public void savedKeysCoverEveryLook() {
        for (String look : HomeLooks.NAMES) assertTrue(HomeLooks.keys().containsAll(HomeLooks.preset(look).keySet()));
    }

    @Test(expected = IllegalArgumentException.class)
    public void anUnknownLookIsRefused() {
        HomeLooks.preset("neon");
    }
}
