package com.gathin.tvhome;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.LruCache;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Keep watching on Home (Home 17, keep_watching_row, off unless the phone turns it on): up to four shows from the
 * TV's Continue watching list above the dock, with "See all" for the rest. Read only when Home comes back to the
 * front, on one background thread; posters go through a small memory cache. Nothing runs while Home is hidden.
 */
final class KeepWatchingRow {
    /** A card took focus (Home hides the dock's glass and shelf meanwhile). */
    interface FocusListener { void onCardFocused(); }

    private final Activity activity;
    private final View row;
    private final LinearLayout cards;
    private final FocusListener focusListener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile int generation;
    private List<KeepWatching.Entry> shown = Collections.emptyList();

    KeepWatchingRow(Activity activity, View row, LinearLayout cards, FocusListener focusListener) {
        this.activity = activity;
        this.row = row;
        this.cards = cards;
        this.focusListener = focusListener;
    }

    boolean visible() { return row.getVisibility() == View.VISIBLE; }

    boolean hasFocus() { return cards.hasFocus(); }

    /** Reads the list again (Home came back): a cheap query of the TV's own table, off the main thread. */
    void refresh() {
        if (!KeepWatching.permitted(activity)) { row.setVisibility(View.GONE); return; }
        int token = ++generation;
        worker.execute(() -> {
            List<KeepWatching.Entry> list = KeepWatching.select(KeepWatching.read(activity), System.currentTimeMillis(),
                    KeepWatching.hidden(activity));
            main.post(() -> { if (token == generation && !activity.isDestroyed()) show(list); });
        });
    }

    void shutdown() {
        generation++;
        worker.shutdownNow();
    }

    private void show(List<KeepWatching.Entry> list) {
        if (same(list, shown)) return;   // the same shows: keep the cards and the focus where they are
        boolean hadFocus = cards.hasFocus();
        shown = list;
        cards.removeAllViews();
        if (list.isEmpty()) { row.setVisibility(View.GONE); return; }
        row.setVisibility(View.VISIBLE);
        int n = KeepWatching.rowShows(list.size());
        for (int i = 0; i < n; i++) cards.addView(rowCard(list.get(i)));
        if (KeepWatching.rowSeeAll(list.size())) cards.addView(seeAllCard(list.size()));
        if (hadFocus && cards.getChildCount() > 0) cards.getChildAt(0).requestFocus();
    }

    private static boolean same(List<KeepWatching.Entry> a, List<KeepWatching.Entry> b) {
        if (a.size() != b.size()) return false;
        for (int i = 0; i < a.size(); i++) {
            if (a.get(i).id != b.get(i).id || a.get(i).lastWatched != b.get(i).lastWatched || a.get(i).position != b.get(i).position) return false;
        }
        return true;
    }

    // ---- cards ---------------------------------------------------------------------------------------

    private View rowCard(KeepWatching.Entry e) {
        Context ctx = activity;
        LinearLayout card = cardFrame(ctx, 204, 72, LinearLayout.HORIZONTAL);
        card.setPadding(dp(8), dp(8), dp(10), dp(8));
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.addView(poster(ctx, e, 96, 54), new LinearLayout.LayoutParams(dp(96), dp(54)));
        LinearLayout text = texts(ctx, e, 12);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
        lp.setMarginStart(dp(10));
        card.addView(text, lp);
        wire(card, e);
        return card;
    }

    private View seeAllCard(int total) {
        LinearLayout card = cardFrame(activity, 120, 72, LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER);
        TextView label = text(activity, activity.getString(R.string.watch_see_all), 14, Color.WHITE, true);
        TextView count = text(activity, activity.getString(R.string.watch_count, total), 11, 0xB3FFFFFF, false);
        card.addView(label);
        card.addView(count);
        card.setContentDescription(activity.getString(R.string.watch_see_all) + ", " + activity.getString(R.string.watch_count, total));
        card.setOnClickListener(v -> activity.startActivity(new Intent(activity, KeepWatchingActivity.class)));
        focusLook(card);
        return card;
    }

    private void wire(View card, KeepWatching.Entry e) {
        card.setContentDescription(e.title + ", " + detail(activity, e));
        card.setOnClickListener(v -> resume(activity, e));
        card.setOnLongClickListener(v -> { confirmRemove(activity, e, this::refresh); return true; });
        focusLook(card);
    }

    private void focusLook(View card) {
        card.setOnFocusChangeListener((v, focused) -> {
            v.animate().scaleX(focused ? 1.06f : 1f).scaleY(focused ? 1.06f : 1f).setDuration(140).start();
            v.setBackground(background(v.getContext(), focused));
            if (focused) focusListener.onCardFocused();
        });
    }

    private LinearLayout cardFrame(Context ctx, int widthDp, int heightDp, int orientation) {
        LinearLayout card = new LinearLayout(ctx);
        card.setOrientation(orientation);
        card.setFocusable(true);
        card.setClickable(true);
        card.setBackground(background(ctx, false));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(widthDp), dp(heightDp));
        lp.setMarginEnd(dp(12));
        card.setLayoutParams(lp);
        return card;
    }

    // ---- shared with the full list -----------------------------------------------------------------------

    static GradientDrawable background(Context ctx, boolean focused) {
        GradientDrawable d = new GradientDrawable();
        float density = ctx.getResources().getDisplayMetrics().density;
        d.setCornerRadius(12 * density);
        d.setColor(0xA60E1428);
        d.setStroke(Math.round((focused ? 2 : 1) * density), focused ? Color.WHITE : 0x24FFFFFF);
        return d;
    }

    /** The poster with a progress bar along its foot; the art loads in the background (or a plain tile). */
    static View poster(Context ctx, KeepWatching.Entry e, int widthDp, int heightDp) {
        float density = ctx.getResources().getDisplayMetrics().density;
        FrameLayout frame = new FrameLayout(ctx);
        GradientDrawable tile = new GradientDrawable();
        tile.setCornerRadius(8 * density);
        tile.setColor(0xFF2A3554);
        frame.setBackground(tile);
        frame.setClipToOutline(true);
        ImageView art = new ImageView(ctx);
        art.setScaleType(ImageView.ScaleType.CENTER_CROP);
        art.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        frame.addView(art, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        ProgressBar bar = new ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(1000);
        bar.setProgress(KeepWatching.progress(e));
        bar.setProgressTintList(android.content.res.ColorStateList.valueOf(0xFF9AE3EC));
        bar.setProgressBackgroundTintList(android.content.res.ColorStateList.valueOf(0x33FFFFFF));
        FrameLayout.LayoutParams barLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Math.round(3 * density), Gravity.BOTTOM);
        frame.addView(bar, barLp);
        Posters.load(ctx, e.posterUri, Math.round(widthDp * density), art);
        return frame;
    }

    static LinearLayout texts(Context ctx, KeepWatching.Entry e, int titleSp) {
        LinearLayout text = new LinearLayout(ctx);
        text.setOrientation(LinearLayout.VERTICAL);
        text.addView(text(ctx, appName(ctx, e.pkg).toUpperCase(java.util.Locale.getDefault()), 9, 0xB3FFFFFF, true));
        text.addView(text(ctx, e.title, titleSp, Color.WHITE, true));
        text.addView(text(ctx, detail(ctx, e), 10, 0xB8FFFFFF, false));
        return text;
    }

    /** "S2 · E5 · 23 min left", "48 min left", "S2 · E5" or "". */
    static String detail(Context ctx, KeepWatching.Entry e) {
        String episode = KeepWatching.episodeLine(e);
        int left = KeepWatching.minutesLeft(e);
        String time = left > 0 ? ctx.getString(R.string.watch_minutes_left, left) : "";
        if (episode.isEmpty()) return time;
        return time.isEmpty() ? episode : episode + " · " + time;
    }

    static TextView text(Context ctx, String value, int sp, int color, boolean bold) {
        TextView t = new TextView(ctx);
        t.setText(value);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color);
        t.setSingleLine(true);
        t.setEllipsize(TextUtils.TruncateAt.END);
        if (bold) t.setTypeface(t.getTypeface(), android.graphics.Typeface.BOLD);
        return t;
    }

    static String appName(Context ctx, String pkg) {
        try {
            return ctx.getPackageManager().getApplicationLabel(ctx.getPackageManager().getApplicationInfo(pkg, 0)).toString();
        } catch (Exception e) {
            return pkg;
        }
    }

    static void resume(Activity activity, KeepWatching.Entry e) {
        try {
            activity.startActivity(KeepWatching.resumeIntent(e));
        } catch (Exception ex) {
            Toast.makeText(activity, R.string.watch_cant_open, Toast.LENGTH_SHORT).show();
        }
    }

    static void confirmRemove(Activity activity, KeepWatching.Entry e, Runnable after) {
        new AlertDialog.Builder(activity)
                .setTitle(activity.getString(R.string.watch_remove_title, e.title))
                .setMessage(R.string.watch_remove_detail)
                .setPositiveButton(R.string.watch_remove, (d, w) -> {
                    KeepWatching.hide(activity, e, System.currentTimeMillis());
                    after.run();
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    private int dp(int value) {
        return Math.round(value * activity.getResources().getDisplayMetrics().density);
    }

    /**
     * Posters for Home's row and list: decoded small on one thread, kept in memory (6 MB at most, emptied when
     * the TV runs short of memory), so a show's art is fetched from its app's server once per Home process.
     */
    static final class Posters {
        private static final LruCache<String, Bitmap> CACHE = new LruCache<String, Bitmap>(6 * 1024 * 1024) {
            @Override protected int sizeOf(String key, Bitmap value) { return value.getByteCount(); }
        };
        private static final ExecutorService LOADER = Executors.newSingleThreadExecutor();
        private static final Handler MAIN = new Handler(Looper.getMainLooper());

        private Posters() { }

        static void load(Context ctx, String uri, int widthPx, ImageView into) {
            if (uri == null || uri.isEmpty()) return;
            String key = widthPx + "|" + uri;
            into.setTag(key);
            Bitmap cached = CACHE.get(key);
            if (cached != null) { into.setImageBitmap(cached); return; }
            Context app = ctx.getApplicationContext();
            LOADER.execute(() -> {
                Bitmap b = KeepWatching.posterBitmap(app, uri, widthPx);
                if (b == null) return;
                CACHE.put(key, b);
                MAIN.post(() -> { if (key.equals(into.getTag())) into.setImageBitmap(b); });
            });
        }

        static void clear() { CACHE.evictAll(); }
    }

    /** For tests: what the row shows for a list of this size. */
    static List<String> plan(int total) {
        List<String> out = new ArrayList<>();
        for (int i = 0; i < KeepWatching.rowShows(total); i++) out.add("show");
        if (KeepWatching.rowSeeAll(total)) out.add("seeAll");
        return out;
    }
}
