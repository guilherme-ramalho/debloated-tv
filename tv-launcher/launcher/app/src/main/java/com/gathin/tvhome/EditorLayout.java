package com.gathin.tvhome;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/** The phone editor's layout rules, kept free of Android types so they run in JVM unit tests. */
final class EditorLayout {
    static final String QUIET_NIGHT = "quiet-night";
    static final String AURORA = "aurora";
    static final String DUSK = "dusk";
    static final int MAX_APPS = 200;
    static final int MAX_JPEG = 1_000_000;
    private static final Pattern PACKAGE = Pattern.compile("[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+");

    private EditorLayout() {}

    static final class Layout {
        final int dockCount;
        final List<String> order;
        final List<String> hidden;
        final String wallpaper;

        Layout(int dockCount, List<String> order, List<String> hidden, String wallpaper) {
            this.dockCount = dockCount;
            this.order = order;
            this.hidden = hidden;
            this.wallpaper = wallpaper;
        }
    }

    static boolean validPackage(String p) {
        return p != null && !p.isEmpty() && p.getBytes(StandardCharsets.UTF_8).length <= 180 && PACKAGE.matcher(p).matches();
    }

    static boolean preset(String id) {
        return QUIET_NIGHT.equals(id) || AURORA.equals(id) || DUSK.equals(id);
    }

    static boolean photo(String id) {
        if (id == null || !id.startsWith("photo-") || id.length() != 6 + 36) return false;
        try {
            return UUID.fromString(id.substring(6)).toString().equalsIgnoreCase(id.substring(6));
        } catch (IllegalArgumentException e) {
            return false;
        }
    }

    /** Throws with a message the phone can show when the layout breaks a rule. */
    static void validate(Layout l) {
        if (l.dockCount < 1 || l.dockCount > 7) throw new IllegalArgumentException("Dock icons must be between 1 and 7");
        if (l.order.size() > MAX_APPS || l.hidden.size() > MAX_APPS) throw new IllegalArgumentException("Too many apps in the layout");
        if (new LinkedHashSet<>(l.order).size() != l.order.size() || new LinkedHashSet<>(l.hidden).size() != l.hidden.size()) {
            throw new IllegalArgumentException("An app appears twice in the layout");
        }
        for (String p : l.order) if (!validPackage(p)) throw new IllegalArgumentException("Invalid app ID in the layout");
        for (String p : l.hidden) if (!validPackage(p)) throw new IllegalArgumentException("Invalid app ID in the layout");
        if (!preset(l.wallpaper) && !photo(l.wallpaper)) throw new IllegalArgumentException("Unsupported wallpaper");
    }

    /** The dock the TV will show: the first dockCount apps in order that are visible and installed here. */
    static List<String> dock(Layout l, Set<String> installed) {
        List<String> dock = new ArrayList<>();
        for (String p : l.order) {
            if (dock.size() >= l.dockCount) break;
            if (!l.hidden.contains(p) && installed.contains(p)) dock.add(p);
        }
        return dock;
    }

    /** Visible installed apps in the phone's order, then any installed app the phone did not mention. */
    static List<String> gridOrder(Layout l, List<String> installedByLabel) {
        Set<String> installed = new LinkedHashSet<>(installedByLabel);
        List<String> out = new ArrayList<>();
        for (String p : l.order) if (installed.contains(p) && !l.hidden.contains(p)) out.add(p);
        for (String p : installedByLabel) if (!out.contains(p) && !l.hidden.contains(p)) out.add(p);
        return out;
    }

    /**
     * The order reported to the phone: the dock first, then the TV's saved order, then everything else by label,
     * with hidden apps last so the phone can still list and unhide them.
     */
    static List<String> reportedOrder(List<String> dockApps, List<String> saved, List<String> installedByLabel, Collection<String> hidden) {
        Set<String> installed = new LinkedHashSet<>(installedByLabel);
        LinkedHashSet<String> out = new LinkedHashSet<>();
        for (String p : dockApps) if (installed.contains(p) && !hidden.contains(p)) out.add(p);
        for (String p : saved) if (installed.contains(p) && !hidden.contains(p)) out.add(p);
        for (String p : installedByLabel) if (!hidden.contains(p)) out.add(p);
        for (String p : hidden) if (validPackage(p)) out.add(p);
        List<String> list = new ArrayList<>(out);
        return list.size() > MAX_APPS ? new ArrayList<>(list.subList(0, MAX_APPS)) : list;
    }

    static String revision(String... parts) {
        try {
            MessageDigest d = MessageDigest.getInstance("SHA-256");
            for (String p : parts) {
                d.update(String.valueOf(p).getBytes(StandardCharsets.UTF_8));
                d.update((byte) 0);
            }
            StringBuilder sb = new StringBuilder();
            byte[] h = d.digest();
            for (int i = 0; i < 12; i++) sb.append(String.format("%02x", h[i]));
            return sb.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** The three gradient stops the phone's preview draws for a preset, as 0xRRGGBB (top-left to bottom-right). */
    static int[] presetColors(String id) {
        switch (id) {
            case AURORA: return new int[] {rgb(0.03, 0.17, 0.24), rgb(0.15, 0.48, 0.47), rgb(0.65, 0.62, 0.48)};
            case DUSK: return new int[] {rgb(0.15, 0.19, 0.33), rgb(0.53, 0.35, 0.47), rgb(0.83, 0.61, 0.5)};
            default: return new int[] {rgb(0.04, 0.09, 0.2), rgb(0.14, 0.27, 0.42), rgb(0.32, 0.39, 0.55)};
        }
    }

    private static int rgb(double r, double g, double b) {
        return ((int) Math.round(r * 255) << 16) | ((int) Math.round(g * 255) << 8) | (int) Math.round(b * 255);
    }
}
