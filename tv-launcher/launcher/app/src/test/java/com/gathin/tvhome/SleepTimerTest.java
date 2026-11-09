package com.gathin.tvhome;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class SleepTimerTest {
    @Test
    public void aFutureDeadlineInThisBootIsActive() {
        assertTrue(SleepTimer.active(2_000, 7, 7, 1_000));
    }

    @Test
    public void aPassedDeadlineIsNoTimer() {
        assertFalse(SleepTimer.active(1_000, 7, 7, 1_000));
        assertFalse(SleepTimer.active(0, 7, 7, 1_000));
    }

    @Test
    public void aRebootDropsTheTimer() {
        assertFalse(SleepTimer.active(2_000, 6, 7, 1_000));
    }
}
