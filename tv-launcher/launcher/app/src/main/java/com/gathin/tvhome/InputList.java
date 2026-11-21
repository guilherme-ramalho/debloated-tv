package com.gathin.tvhome;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.media.tv.TvInputInfo;
import android.media.tv.TvInputManager;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * The TV's inputs for the phone's Inputs key (Home 18, editor request "inputs"): the same rows as Home's own Inputs
 * menu (MainActivity.showInputs), in the same order and with the same names: HDMI ports first (a CEC device takes
 * its port's row, "Apple TV · HDMI 1"; a port named in the TV's Settings › Inputs reads "PlayStation · HDMI 2"), then
 * AV and the rest, then Live TV when the TV has a tuner and a Live TV app. Inputs hidden in the TV's settings or by
 * the profile's input_sources ("HW8=-") stay out. Switching goes through Home itself ({@link #ACTION_OPEN}), so the
 * vendor routes Home already knows apply.
 */
final class InputList {
    /** Started on MainActivity: switch to the input in {@link #EXTRA_ID}, or Live TV with {@link #LIVE_TV}. */
    static final String ACTION_OPEN = "com.gathin.tvhome.OPEN_INPUT";
    static final String EXTRA_ID = "input_id";
    static final String LIVE_TV = "live-tv";
    /** Only Home's own editor knows it (it changes with each Home process), so no other app can switch inputs this way. */
    static final String TOKEN = java.util.UUID.randomUUID().toString();
    static final String EXTRA_TOKEN = "token";

    private InputList() { }

    /** {"inputs": [{"id", "name", "kind": "hdmi"|"av"|"live", "connected": true|false|null}], at most 40}. */
    static JSONObject toPhone(Context ctx, Config cfg) throws JSONException {
        JSONArray out = new JSONArray();
        TvInputManager tim = (TvInputManager) ctx.getSystemService(Context.TV_INPUT_SERVICE);
        boolean tuner = false;
        if (tim != null) {
            List<TvInputInfo> inputs;
            try { inputs = new ArrayList<>(tim.getTvInputList()); } catch (RuntimeException e) { inputs = new ArrayList<>(); }
            Collections.sort(inputs, (a, b) -> {
                boolean ha = a.getType() == TvInputInfo.TYPE_HDMI, hb = b.getType() == TvInputInfo.TYPE_HDMI;
                if (ha != hb) return ha ? -1 : 1;
                return String.valueOf(a.loadLabel(ctx)).compareToIgnoreCase(String.valueOf(b.loadLabel(ctx)));
            });
            Set<String> ids = new HashSet<>();
            for (TvInputInfo info : inputs) ids.add(info.getId());
            Map<String, List<TvInputInfo>> cec = new HashMap<>();
            for (TvInputInfo info : inputs) {
                String parent = info.getParentId();
                if (parent == null || !ids.contains(parent) || !info.isPassthroughInput() || info.isHidden(ctx)) continue;
                List<TvInputInfo> onPort = cec.get(parent);
                if (onPort == null) cec.put(parent, onPort = new ArrayList<>());
                onPort.add(info);
            }
            int ports = 0, connected = 0;
            for (TvInputInfo info : inputs) {
                if (!info.isPassthroughInput() || info.getType() != TvInputInfo.TYPE_HDMI) continue;
                if (info.getParentId() != null && ids.contains(info.getParentId())) continue;
                ports++;
                if (state(tim, info.getId()) == TvInputManager.INPUT_STATE_CONNECTED) connected++;
            }
            // Some TVs (Sony) report every port as connected: then no state at all, as in Home's menu.
            boolean stateBogus = ports > 1 && connected == ports;
            for (TvInputInfo info : inputs) {
                if (out.length() >= 40) break;
                if (info.getType() == TvInputInfo.TYPE_TUNER && info.getServiceInfo() != null
                        && (info.getServiceInfo().applicationInfo.flags & ApplicationInfo.FLAG_SYSTEM) != 0) tuner = true;
                if (!info.isPassthroughInput() || info.isHidden(ctx)) continue;
                if (Integer.valueOf(-1).equals(InputSources.mapped(cfg.inputSources, info.getId()))) continue;
                if (info.getParentId() != null && ids.contains(info.getParentId())) continue;
                CharSequence l = info.loadLabel(ctx);
                String label = l == null ? info.getId() : l.toString();
                boolean hdmi = info.getType() == TvInputInfo.TYPE_HDMI;
                if (hdmi && !label.toUpperCase(Locale.ROOT).contains("HDMI")) label = "HDMI " + label;
                CharSequence custom = InputNames.tidy(info.loadCustomLabel(ctx));
                boolean named = custom != null && custom.length() > 0 && !custom.toString().equals(label);
                List<TvInputInfo> devices = cec.get(info.getId());
                if (devices != null) {
                    for (TvInputInfo device : devices) {
                        CharSequence name = InputNames.tidy(device.loadCustomLabel(ctx));
                        if (name == null || name.length() == 0) name = named ? custom : device.loadLabel(ctx);
                        String deviceLabel = name == null || name.length() == 0 ? label : name + " · " + label;
                        out.put(row(device.getId(), deviceLabel, "hdmi", stateBogus ? -1 : state(tim, device.getId())));
                    }
                    continue;
                }
                if (named) label = custom + " · " + label;
                // AV jacks have no hotplug detection (and some TVs say "connected" with nothing in): no state.
                out.put(row(info.getId(), label, hdmi ? "hdmi" : "av", !hdmi || stateBogus ? -1 : state(tim, info.getId())));
            }
        }
        if (tuner && !cfg.liveTvPackage.isEmpty() && out.length() < 40) out.put(row(LIVE_TV, ctx.getString(R.string.live_tv), "live", -1));
        return new JSONObject().put("inputs", out);
    }

    private static int state(TvInputManager tim, String id) {
        try { return tim.getInputState(id); } catch (RuntimeException e) { return -1; }
    }

    private static JSONObject row(String id, String name, String kind, int state) throws JSONException {
        JSONObject o = new JSONObject().put("id", trim(id, 512)).put("name", trim(name, 120)).put("kind", kind);
        if (state == TvInputManager.INPUT_STATE_CONNECTED) o.put("connected", true);
        else if (state == TvInputManager.INPUT_STATE_DISCONNECTED) o.put("connected", false);
        return o;
    }

    private static String trim(String s, int max) { return s.length() <= max ? s : s.substring(0, max); }
}
