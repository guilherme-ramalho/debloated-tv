package com.gathin.tvhome;

/** One correction per initial physical press; held-key repetition stays with the platform. */
final class VolumeKeyCorrection {
    private long lastPress = Long.MIN_VALUE;
    private int lastDirection;

    int direction(boolean down, int direction, int repeatCount, long press, boolean canceled, boolean physical) {
        if (!physical || !down || canceled || repeatCount != 0 || (direction != 1 && direction != -1)) return 0;
        if (lastPress == press && lastDirection == direction) return 0;
        lastPress = press;
        lastDirection = direction;
        return -direction;
    }
}
