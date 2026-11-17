package com.gathin.tvhome;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Keep watching on the phone (KWT-01..03): which of the TV's Continue watching rows the phone gets. */
public class KeepWatchingTest {
    private static final long NOW = 1_800_000_000_000L;
    private static final long DAY = 24L * 60 * 60 * 1000;

    private static KeepWatching.Entry row(long id, String pkg, String title, String s, String e, long pos, long dur, long watched) {
        return new KeepWatching.Entry(id, pkg, title, null, s, e, pos, dur, watched, null, "intent:#Intent;package=" + pkg + ";end");
    }

    @Test public void newestShowFirstOneCardEachFinishedAndOldOnesKept() {
        List<KeepWatching.Entry> rows = Arrays.asList(
                row(1, "com.netflix.ninja", "Show A", "1", "4", 600_000, 3_000_000, NOW - DAY),
                row(2, "com.netflix.ninja", "Show A", "1", "5", 100_000, 3_000_000, NOW - 1000),   // a later episode of A
                row(3, "com.amazon.amazonvideo.livingroom", "Film B", null, null, 3_000_000, 8_000_000, NOW - 2 * DAY),
                row(4, "com.netflix.ninja", "Almost done", "1", "4", 633_000, 656_000, NOW - 3000),  // 96 % watched
                row(5, "com.wbd.stream", "Old show", "5", "2", 611_000, 1_132_000, NOW - 40 * DAY),
                row(6, "com.netflix.ninja", "", "1", "1", 1, 10, NOW),                               // no title
                row(7, "com.netflix.ninja", "No link", "1", "1", 1, 10, NOW));
        rows = new ArrayList<>(rows);
        rows.set(6, new KeepWatching.Entry(7, "com.netflix.ninja", "No link", null, "1", "1", 1, 10, NOW, null, null));
        List<KeepWatching.Entry> out = KeepWatching.select(rows, NOW, Collections.emptyMap());
        assertEquals(Arrays.asList(2L, 4L, 3L, 5L), ids(out));
    }

    @Test public void atMostTenAndARemovedShowComesBackWhenWatchedAgain() {
        List<KeepWatching.Entry> rows = new ArrayList<>();
        for (int i = 0; i < 14; i++) rows.add(row(i, "app.x", "Show " + i, null, null, 10, 100, NOW - i * 1000L));
        assertEquals(KeepWatching.MAX, KeepWatching.select(rows, NOW, Collections.emptyMap()).size());

        Map<String, Long> hidden = new HashMap<>();
        hidden.put("app.x|Show 0", NOW + 500);   // removed after it was last watched (NOW)
        hidden.put("app.x|Show 1", NOW - 5000);  // removed, then watched again (NOW - 1000)
        List<Long> ids = ids(KeepWatching.select(rows, NOW, hidden));
        assertTrue(!ids.contains(0L));
        assertTrue(ids.contains(1L));
    }

    @Test public void episodeLines() {
        assertEquals("S2 · E5", KeepWatching.episodeLine(row(1, "p", "t", "2", "5", 0, 0, 0)));
        assertEquals("", KeepWatching.episodeLine(row(1, "p", "t", null, null, 0, 0, 0)));
        assertEquals("S1 · E3 · Pilot", KeepWatching.episodeLine(new KeepWatching.Entry(1, "p", "t", "Pilot", "1", "3", 0, 0, 0, null, "x")));
    }

    private static List<Long> ids(List<KeepWatching.Entry> list) {
        List<Long> out = new ArrayList<>();
        for (KeepWatching.Entry e : list) out.add(e.id);
        return out;
    }
}
