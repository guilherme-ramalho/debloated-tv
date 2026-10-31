package com.gathin.tvhome;

import org.junit.Test;
import static org.junit.Assert.*;

public class VolumeKeyCorrectionTest {
    @Test public void onlyInitialDownIsCorrectedInBothDirections() {
        for (int direction : new int[] {1, -1}) {
            VolumeKeyCorrection c = new VolumeKeyCorrection();
            assertEquals(-direction, c.direction(true, direction, 0, 10, false, true));
            assertEquals(0, c.direction(true, direction, 0, 10, false, true));
            assertEquals(0, c.direction(true, direction, 1, 10, false, true));
            assertEquals(0, c.direction(true, direction, 20, 10, false, true));
            assertEquals(0, c.direction(false, direction, 0, 10, false, true));
            assertEquals(-direction, c.direction(true, direction, 0, 20, false, true));
        }
    }
    @Test public void cancellationAndInvalidDirectionsAreIgnored() {
        VolumeKeyCorrection c = new VolumeKeyCorrection();
        assertEquals(0, c.direction(true, 1, 0, 10, true, true));
        assertEquals(0, c.direction(true, 0, 0, 10, false, true));
        assertEquals(0, c.direction(true, 2, 0, 10, false, true));
    }
    @Test public void initialNetStepIsOneIncludingVolumeLimits() {
        for (int start : new int[] {0, 1, 19, 99, 100}) {
            for (int direction : new int[] {1, -1}) {
                VolumeKeyCorrection c = new VolumeKeyCorrection();
                int firstNative = step(start, direction);
                int corrected = step(firstNative, c.direction(true, direction, 0, 10, false, true));
                int secondNative = step(corrected, direction);
                assertEquals(step(start, direction), secondNative);
            }
        }
    }
    @Test public void injectedKeysAreNotCorrected() {
        VolumeKeyCorrection c = new VolumeKeyCorrection();
        assertEquals(0, c.direction(true, 1, 0, 10, false, false));
        assertEquals(-1, c.direction(true, 1, 0, 10, false, true));
    }
    private static int step(int volume, int direction) { return Math.max(0, Math.min(100, volume + direction)); }
}
