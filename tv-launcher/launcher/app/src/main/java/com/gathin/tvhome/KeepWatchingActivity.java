package com.gathin.tvhome;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Keep watching, every show (up to 50), opened from the row's "See all" on Home. OK resumes a show in its app;
 * holding OK offers to remove it. Read when the screen opens or comes back; nothing runs once it's gone.
 */
public class KeepWatchingActivity extends Activity {
    private static final int COLUMNS = 4;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final List<KeepWatching.Entry> shows = new ArrayList<>();
    private RecyclerView grid;
    private TextView empty;
    private int generation;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        float d = getResources().getDisplayMetrics().density;
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(0xFF0A1022);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(Math.round(56 * d), Math.round(32 * d), Math.round(56 * d), Math.round(16 * d));
        column.setClipChildren(false);
        column.setClipToPadding(false);
        TextView title = KeepWatchingRow.text(this, getString(R.string.watch_title), 28, Color.WHITE, true);
        column.addView(title);
        TextView subtitle = KeepWatchingRow.text(this, getString(R.string.watch_list_subtitle), 13, 0xB8FFFFFF, false);
        LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        subLp.topMargin = Math.round(4 * d);
        column.addView(subtitle, subLp);

        grid = new RecyclerView(this);
        grid.setLayoutManager(new GridLayoutManager(this, COLUMNS));
        grid.setClipChildren(false);
        grid.setClipToPadding(false);
        grid.setPadding(0, Math.round(16 * d), 0, Math.round(56 * d));
        grid.setAdapter(new Cards());
        column.addView(grid, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        root.addView(column, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        empty = KeepWatchingRow.text(this, getString(R.string.watch_empty), 15, 0xB8FFFFFF, false);
        empty.setVisibility(View.GONE);
        root.addView(empty, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        TextView hint = KeepWatchingRow.text(this, getString(R.string.watch_hint), 13, 0xD9FFFFFF, false);
        hint.setPadding(Math.round(20 * d), Math.round(10 * d), Math.round(20 * d), Math.round(10 * d));
        hint.setBackground(KeepWatchingRow.background(this, false));
        FrameLayout.LayoutParams hintLp = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        hintLp.bottomMargin = Math.round(18 * d);
        root.addView(hint, hintLp);
        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override
    protected void onDestroy() {
        generation++;
        worker.shutdownNow();
        super.onDestroy();
    }

    private void refresh() {
        int token = ++generation;
        worker.execute(() -> {
            List<KeepWatching.Entry> list = KeepWatching.permitted(this)
                    ? KeepWatching.select(KeepWatching.read(this), System.currentTimeMillis(), KeepWatching.hidden(this))
                    : new ArrayList<>();
            main.post(() -> {
                if (token != generation || isDestroyed()) return;
                boolean first = shows.isEmpty();
                shows.clear();
                shows.addAll(list);
                grid.getAdapter().notifyDataSetChanged();
                empty.setVisibility(list.isEmpty() ? View.VISIBLE : View.GONE);
                if (first && !list.isEmpty()) grid.post(() -> {
                    RecyclerView.ViewHolder vh = grid.findViewHolderForAdapterPosition(0);
                    if (vh != null) vh.itemView.requestFocus();
                });
            });
        });
    }

    private final class Cards extends RecyclerView.Adapter<RecyclerView.ViewHolder> {
        @Override
        public RecyclerView.ViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            float d = getResources().getDisplayMetrics().density;
            LinearLayout card = new LinearLayout(KeepWatchingActivity.this);
            card.setOrientation(LinearLayout.VERTICAL);
            card.setFocusable(true);
            card.setClickable(true);
            card.setPadding(Math.round(8 * d), Math.round(8 * d), Math.round(8 * d), Math.round(10 * d));
            card.setBackground(KeepWatchingRow.background(KeepWatchingActivity.this, false));
            RecyclerView.LayoutParams lp = new RecyclerView.LayoutParams(Math.round(196 * d), ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, 0, Math.round(16 * d), Math.round(18 * d));
            card.setLayoutParams(lp);
            card.setOnFocusChangeListener((v, focused) -> {
                v.animate().scaleX(focused ? 1.05f : 1f).scaleY(focused ? 1.05f : 1f).setDuration(140).start();
                v.setBackground(KeepWatchingRow.background(v.getContext(), focused));
            });
            return new RecyclerView.ViewHolder(card) { };
        }

        @Override
        public void onBindViewHolder(RecyclerView.ViewHolder holder, int position) {
            float d = getResources().getDisplayMetrics().density;
            KeepWatching.Entry e = shows.get(position);
            LinearLayout card = (LinearLayout) holder.itemView;
            card.removeAllViews();
            card.addView(KeepWatchingRow.poster(KeepWatchingActivity.this, e, 180, 101),
                    new LinearLayout.LayoutParams(Math.round(180 * d), Math.round(101 * d)));
            LinearLayout texts = KeepWatchingRow.texts(KeepWatchingActivity.this, e, 13);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = Math.round(8 * d);
            card.addView(texts, lp);
            card.setContentDescription(e.title + ", " + KeepWatchingRow.detail(KeepWatchingActivity.this, e));
            card.setOnClickListener(v -> KeepWatchingRow.resume(KeepWatchingActivity.this, e));
            card.setOnLongClickListener(v -> { KeepWatchingRow.confirmRemove(KeepWatchingActivity.this, e, KeepWatchingActivity.this::refresh); return true; });
        }

        @Override
        public int getItemCount() { return shows.size(); }
    }
}
