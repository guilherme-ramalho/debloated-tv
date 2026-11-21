package com.gathin.tvhome;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.tv.TvContract;
import android.net.Uri;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Keep watching for the phone (docs/launcher-editor-contract.md, keepWatching): the shows the TV's apps keep in
 * Android's Continue watching list (Watch Next), read only when the phone asks. Needs READ_TV_LISTINGS, granted by
 * the phone's setup. Nothing runs in the background and nothing is kept but the shows the person removed.
 */
final class KeepWatching {
    static final String PERMISSION = "android.permission.READ_TV_LISTINGS";
    /** The phone's strip shows the newest 10; See all shows the rest. */
    static final int MAX = 50;
    private static final String PREFS = "keep_watching";
    private static final int POSTER_WIDTH = 320;

    /** One row of the list, as the TV's app wrote it. */
    static final class Entry {
        final long id;
        final String pkg, title, episodeTitle, season, episode, posterUri, intentUri;
        final long position, duration, lastWatched;

        Entry(long id, String pkg, String title, String episodeTitle, String season, String episode,
              long position, long duration, long lastWatched, String posterUri, String intentUri) {
            this.id = id; this.pkg = pkg; this.title = title; this.episodeTitle = episodeTitle; this.season = season;
            this.episode = episode; this.position = position; this.duration = duration; this.lastWatched = lastWatched;
            this.posterUri = posterUri; this.intentUri = intentUri;
        }

        /** The same show however many episodes the app lists: package and title. */
        String showKey() { return pkg + "|" + title; }
    }

    private KeepWatching() {}

    static boolean permitted(Context ctx) {
        return ctx.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED;
    }

    /**
     * What the phone shows: one card per show (its latest), newest first, at most [MAX], however old and however
     * far watched (his choice, 17 Nov: finished and older shows stay). Left out: ones with no title or no way to
     * open them, and ones the person removed (until the show is watched again: [hidden] maps a show to when it was
     * removed).
     */
    static List<Entry> select(List<Entry> rows, long now, Map<String, Long> hidden) {
        Map<String, Entry> latest = new LinkedHashMap<>();
        for (Entry e : rows) {
            if (e.title == null || e.title.trim().isEmpty() || e.intentUri == null || e.intentUri.isEmpty()) continue;
            Long removedAt = hidden.get(e.showKey());
            if (removedAt != null && e.lastWatched <= removedAt) continue;
            Entry kept = latest.get(e.showKey());
            if (kept == null || e.lastWatched > kept.lastWatched) latest.put(e.showKey(), e);
        }
        List<Entry> out = new ArrayList<>(latest.values());
        Collections.sort(out, (a, b) -> Long.compare(b.lastWatched, a.lastWatched));
        return out.size() > MAX ? new ArrayList<>(out.subList(0, MAX)) : out;
    }

    /** "S2 · E5", "S2 · E5 · Title", "Title" or "". */
    static String episodeLine(Entry e) {
        StringBuilder s = new StringBuilder();
        if (e.season != null && !e.season.isEmpty()) s.append('S').append(e.season);
        if (e.episode != null && !e.episode.isEmpty()) s.append(s.length() > 0 ? " · " : "").append('E').append(e.episode);
        if (e.episodeTitle != null && !e.episodeTitle.isEmpty()) s.append(s.length() > 0 ? " · " : "").append(e.episodeTitle);
        return s.toString();
    }

    /** The intent an entry opens, only if it targets the app that wrote the entry. */
    static Intent resumeIntent(Entry e) throws java.net.URISyntaxException {
        Intent intent = Intent.parseUri(e.intentUri, Intent.URI_INTENT_SCHEME);
        String target = intent.getPackage() != null ? intent.getPackage()
                : intent.getComponent() != null ? intent.getComponent().getPackageName() : null;
        if (target != null && !target.equals(e.pkg)) throw new IllegalArgumentException("That show opens another app");
        if (target == null) intent.setPackage(e.pkg);
        intent.setSelector(null);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return intent;
    }

    // ---- reading the TV ----------------------------------------------------------------------------

    static List<Entry> read(Context ctx) {
        List<Entry> rows = new ArrayList<>();
        String[] columns = {
                TvContract.WatchNextPrograms._ID, TvContract.WatchNextPrograms.COLUMN_PACKAGE_NAME,
                TvContract.WatchNextPrograms.COLUMN_TITLE, TvContract.WatchNextPrograms.COLUMN_EPISODE_TITLE,
                TvContract.WatchNextPrograms.COLUMN_SEASON_DISPLAY_NUMBER, TvContract.WatchNextPrograms.COLUMN_EPISODE_DISPLAY_NUMBER,
                TvContract.WatchNextPrograms.COLUMN_LAST_PLAYBACK_POSITION_MILLIS, TvContract.WatchNextPrograms.COLUMN_DURATION_MILLIS,
                TvContract.WatchNextPrograms.COLUMN_LAST_ENGAGEMENT_TIME_UTC_MILLIS, TvContract.WatchNextPrograms.COLUMN_POSTER_ART_URI,
                TvContract.WatchNextPrograms.COLUMN_INTENT_URI};
        try (Cursor c = ctx.getContentResolver().query(TvContract.WatchNextPrograms.CONTENT_URI, columns, null, null, null)) {
            if (c == null) return rows;
            while (c.moveToNext()) {
                rows.add(new Entry(c.getLong(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4), c.getString(5),
                        c.isNull(6) ? 0 : c.getLong(6), c.isNull(7) ? 0 : c.getLong(7), c.isNull(8) ? 0 : c.getLong(8),
                        c.getString(9), c.getString(10)));
            }
        } catch (SecurityException e) {
            return rows;   // permission not granted: the phone shows why
        }
        return rows;
    }

    static Entry find(Context ctx, long id) {
        for (Entry e : read(ctx)) if (e.id == id) return e;
        return null;
    }

    /**
     * The list for the phone: entries with a small JPEG poster each (320 px wide), when the app gave one. Posters
     * are fetched for 6 s at most in all; the rest go without, so a slow network never holds the list up.
     */
    static JSONObject toPhone(Context ctx, long now) throws JSONException {
        long posterDeadline = System.currentTimeMillis() + 6000;
        boolean allowed = permitted(ctx);
        JSONArray items = new JSONArray();
        if (allowed) {
            for (Entry e : select(read(ctx), now, hidden(ctx))) {
                JSONObject o = new JSONObject()
                        .put("id", String.valueOf(e.id)).put("package", e.pkg).put("title", e.title)
                        .put("episode", episodeLine(e))
                        .put("positionMs", e.position).put("durationMs", e.duration)
                        .put("lastWatched", e.lastWatched / 1000);
                String poster = System.currentTimeMillis() < posterDeadline ? poster(ctx, e.posterUri) : null;
                if (poster != null) o.put("posterJPEG", poster);
                items.put(o);
            }
        }
        return new JSONObject().put("allowed", allowed).put("items", items);
    }

    // ---- removed by the person -------------------------------------------------------------------------

    static Map<String, Long> hidden(Context ctx) {
        Map<String, Long> out = new LinkedHashMap<>();
        for (Map.Entry<String, ?> e : ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getAll().entrySet()) {
            if (e.getValue() instanceof Long) out.put(e.getKey(), (Long) e.getValue());
        }
        return out;
    }

    /** Leaves the show out until it is watched again. At most 100 removals are kept (the oldest go first). */
    static void hide(Context ctx, Entry e, long now) {
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Map<String, Long> all = hidden(ctx);
        SharedPreferences.Editor edit = prefs.edit();
        if (all.size() >= 100) {
            String oldest = Collections.min(all.entrySet(), Map.Entry.comparingByValue()).getKey();
            edit.remove(oldest);
        }
        edit.putLong(e.showKey(), Math.max(now, e.lastWatched)).apply();
    }

    // ---- posters -------------------------------------------------------------------------------------------

    private static String poster(Context ctx, String uri) {
        Bitmap small = posterBitmap(ctx, uri, POSTER_WIDTH);
        if (small == null) return null;
        ByteArrayOutputStream jpeg = new ByteArrayOutputStream();
        small.compress(Bitmap.CompressFormat.JPEG, 72, jpeg);
        small.recycle();
        return Base64.encodeToString(jpeg.toByteArray(), Base64.NO_WRAP);
    }

    /**
     * The poster at most [width] px wide (RGB_565), from the app's own artwork link: a content or resource URI, or
     * https. Null when there is none or it can't be read. Network and decoding: never on the main thread.
     */
    static Bitmap posterBitmap(Context ctx, String uri, int width) {
        if (uri == null || uri.isEmpty()) return null;
        try (InputStream in = open(ctx, uri)) {
            if (in == null) return null;
            byte[] bytes = readAll(in, 4 * 1024 * 1024);
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, bounds);
            if (bounds.outWidth <= 0) return null;
            BitmapFactory.Options options = new BitmapFactory.Options();
            options.inSampleSize = Math.max(1, Integer.highestOneBit(bounds.outWidth / width));
            options.inPreferredConfig = Bitmap.Config.RGB_565;
            Bitmap decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.length, options);
            if (decoded == null) return null;
            if (decoded.getWidth() <= width) return decoded;
            int h = Math.max(1, Math.round(decoded.getHeight() * (width / (float) decoded.getWidth())));
            Bitmap small = Bitmap.createScaledBitmap(decoded, width, h, true);
            if (small != decoded) decoded.recycle();
            return small;
        } catch (Exception | OutOfMemoryError e) {
            return null;
        }
    }

    // ---- the row on Home (Home 17, keep_watching_row) -------------------------------------------------

    /** Cards the row on Home shows: up to 4 shows; with more, the 4th place is "See all". */
    static final int ROW_CARDS = 4;

    static int rowShows(int total) {
        return total <= ROW_CARDS ? total : ROW_CARDS - 1;
    }

    static boolean rowSeeAll(int total) {
        return total > ROW_CARDS;
    }

    /** Minutes left in the show, or -1 when the app gave no position or length (or it's finished). */
    static int minutesLeft(Entry e) {
        if (e.duration <= 0 || e.position <= 0 || e.position >= e.duration) return -1;
        return (int) Math.max(1, Math.round((e.duration - e.position) / 60000.0));
    }

    /** 0 to 1000, for the progress bar; 0 when the app gave no position. */
    static int progress(Entry e) {
        if (e.duration <= 0 || e.position <= 0) return 0;
        return (int) Math.min(1000, e.position * 1000 / e.duration);
    }

    private static InputStream open(Context ctx, String uri) throws java.io.IOException {
        Uri parsed = Uri.parse(uri);
        String scheme = parsed.getScheme();
        if (ContentResolver.SCHEME_CONTENT.equals(scheme) || ContentResolver.SCHEME_ANDROID_RESOURCE.equals(scheme)) {
            return ctx.getContentResolver().openInputStream(parsed);
        }
        if ("https".equals(scheme) || "http".equals(scheme)) {
            HttpURLConnection c = (HttpURLConnection) new URL(uri).openConnection();
            c.setConnectTimeout(4000); c.setReadTimeout(4000);
            return c.getResponseCode() == 200 ? c.getInputStream() : null;
        }
        return null;
    }

    private static byte[] readAll(InputStream in, int max) throws java.io.IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[16384];
        int n;
        while ((n = in.read(buffer)) > 0) {
            out.write(buffer, 0, n);
            if (out.size() > max) throw new java.io.IOException("poster too large");
        }
        return out.toByteArray();
    }
}
