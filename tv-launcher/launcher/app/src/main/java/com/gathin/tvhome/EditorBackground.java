package com.gathin.tvhome;

import android.content.Context;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;

/**
 * The phone's preset wallpapers (Quiet night, Aurora, Dusk) drawn as a gradient behind Home instead of a picture:
 * no file to decode and no bitmap kept in memory, at any screen size. A photo still goes through WallpaperPlayer,
 * whose picture covers this background.
 */
final class EditorBackground {
    private EditorBackground() {}

    /** The chosen preset's gradient, or null when the phone never chose one (Home keeps its theme colour). */
    static Drawable load(Context ctx) {
        String id = EditorBackend.savedWallpaper(ctx);
        if (!EditorLayout.preset(id)) return null;
        int[] rgb = EditorLayout.presetColors(id);
        int[] colors = new int[rgb.length];
        for (int i = 0; i < rgb.length; i++) colors[i] = 0xff000000 | rgb[i];
        GradientDrawable gradient = new GradientDrawable(GradientDrawable.Orientation.TL_BR, colors);
        gradient.setDither(true);   // no banding on the dark, smooth steps
        return gradient;
    }
}
