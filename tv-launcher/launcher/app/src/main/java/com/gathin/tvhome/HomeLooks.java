package com.gathin.tvhome;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The phone's Look picker (homeSettings look). A look is a preset of switches Home already has, written into
 * config.json; nothing new is drawn or runs in the background. The values a look replaces are kept in look_saved,
 * so the next look (or Cinema) starts from the theme's own values, not from the previous look's.
 */
final class HomeLooks {
    static final String CINEMA = "cinema", CALM = "calm", GLASS = "glass", GALLERY = "gallery";
    static final List<String> NAMES = Collections.unmodifiableList(Arrays.asList(CINEMA, CALM, GLASS, GALLERY));
    static final String KEY = "look";
    static final String SAVED = "look_saved";

    private HomeLooks() {}

    /** The switches each look sets. */
    static Map<String, Object> preset(String look) {
        Map<String, Object> m = new LinkedHashMap<>();
        switch (look) {
            case CINEMA:   // today's Home: the focused app's artwork fills the top in its colour
                m.put("cinematic_home", true);
                break;
            case CALM:     // one quiet row of named apps; the big clock after a minute untouched
                m.put("cinematic_home", false);
                m.put("dock_row", true);
                m.put("single_row", true);
                m.put("dock_band", false);
                m.put("always_show_names", true);
                m.put("uniform_tiles", true);
                m.put("icon_only_buttons", true);
                m.put("home_idle_clock_minutes", 1);
                break;
            case GLASS:    // the wallpaper behind a frosted glass dock, soft halo focus
                m.put("cinematic_home", false);
                m.put("single_row", false);
                m.put("dock_band", true);
                m.put("dock_glass", true);
                m.put("glass_style", "halo");
                break;
            case GALLERY:  // the photo first: one row with no band, true colour, the idle clock over the photo
                m.put("cinematic_home", false);
                m.put("dock_row", true);
                m.put("single_row", true);
                m.put("dock_band", false);
                m.put("wallpaper_true_color", true);
                m.put("clock_wallpaper", true);
                m.put("home_idle_clock_minutes", 5);
                break;
            default:
                throw new IllegalArgumentException("Unknown look");
        }
        return m;
    }

    /** Every switch any look touches: what look_saved keeps. */
    static Set<String> keys() {
        Set<String> all = new LinkedHashSet<>();
        for (String look : NAMES) all.addAll(preset(look).keySet());
        return all;
    }

    static String current(JSONObject config) {
        String look = config == null ? CINEMA : config.optString(KEY, CINEMA);
        return NAMES.contains(look) ? look : CINEMA;
    }

    /** Puts the theme's own values back, then sets the look's switches over them. */
    static void apply(JSONObject config, String look) throws JSONException {
        if (!NAMES.contains(look)) throw new IllegalArgumentException("Unknown look");
        Set<String> keys = keys();
        JSONObject saved = config.optJSONObject(SAVED);
        if (saved != null) {
            for (String k : keys) {
                if (saved.has(k)) config.put(k, saved.get(k));
                else config.remove(k);
            }
        }
        JSONObject original = new JSONObject();
        for (String k : keys) if (config.has(k)) original.put(k, config.get(k));
        config.put(SAVED, original);
        for (Map.Entry<String, Object> e : preset(look).entrySet()) config.put(e.getKey(), e.getValue());
        config.put(KEY, look);
    }
}
