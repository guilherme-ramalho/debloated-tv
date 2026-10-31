package com.gathin.tvhome;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.BitmapFactory;
import android.media.tv.TvContract;
import android.media.tv.TvInputInfo;
import android.media.tv.TvInputManager;
import android.net.Uri;
import android.util.AtomicFile;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * Answers the phone editor's requests (docs/launcher-editor-contract.md): snapshot, applyLayout, uninstall and
 * sleepTimer. A layout is written the same way a theme push is: dock_apps, hidden_apps and columns in config.json,
 * wallpaper.jpg next to it, and the grid order in order.txt. Home then rebuilds (EditorHome) and reads it all back
 * through Config, so nothing here keeps running after the session.
 */
final class EditorBackend implements EditorServer.Backend {
    static final String STATE_FILE = "phone_editor.json";
    private static final String GLOW_MARKER = "phone_editor_glow_off";

    private final Context ctx;

    EditorBackend(Context ctx) {
        this.ctx = ctx.getApplicationContext();
    }

    @Override
    public String handle(String request) {
        String id = null;
        try {
            JSONObject message = new JSONObject(request);
            String type = message.optString("type");
            if ("ping".equals(type)) return new JSONObject().put("type", "pong").toString();
            if (!"request".equals(type)) return error(null, "Unsupported message");
            id = message.getString("id");
            JSONObject payload = message.optJSONObject("payload");
            if (payload == null) payload = new JSONObject();
            Object result;
            switch (message.optString("operation")) {
                case "snapshot": result = snapshot(); break;
                case "applyLayout": result = applyLayout(payload); break;
                case "uninstall": result = uninstall(payload); break;
                case "sleepTimer":
                    return error(id, "This TV doesn't let Home switch it off on a timer yet. Use the TV's own sleep timer for now.");
                default: return error(id, "Unsupported request");
            }
            return new JSONObject().put("type", "response").put("id", id).put("ok", true).put("result", result).toString();
        } catch (IllegalArgumentException e) {
            return error(id, e.getMessage());
        } catch (JSONException e) {
            return error(id, "The TV could not read that request");
        } catch (IOException e) {
            return error(id, "The TV could not save the change: " + e.getMessage());
        } catch (RuntimeException e) {
            return error(id, "The TV could not complete that request");
        }
    }

    private static String error(String id, String message) {
        try {
            JSONObject o = new JSONObject().put("type", "response").put("ok", false).put("error", message);
            if (id != null) o.put("id", id);
            else o.put("type", "error").put("message", message);
            return o.toString();
        } catch (JSONException e) {
            return "{\"type\":\"error\",\"message\":\"TV editor error\"}";
        }
    }

    // ---- snapshot ------------------------------------------------------------------------------------

    private static final class App {
        final String pkg, label, component;
        final boolean system;

        App(String pkg, String label, String component, boolean system) {
            this.pkg = pkg;
            this.label = label;
            this.component = component;
            this.system = system;
        }
    }

    /** Installed TV apps by package, sorted by label, without this launcher. */
    private Map<String, App> apps() {
        PackageManager pm = ctx.getPackageManager();
        List<ResolveInfo> list = pm.queryIntentActivities(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER), 0);
        List<App> found = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (ResolveInfo ri : list) {
            if (ri.activityInfo == null) continue;
            String pkg = ri.activityInfo.packageName;
            if (pkg.equals(ctx.getPackageName()) || !EditorLayout.validPackage(pkg) || !seen.add(pkg)) continue;
            ApplicationInfo ai = ri.activityInfo.applicationInfo;
            boolean system = ai != null && (ai.flags & (ApplicationInfo.FLAG_SYSTEM | ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0;
            String label = String.valueOf(ri.loadLabel(pm));
            found.add(new App(pkg, label, new ComponentName(pkg, ri.activityInfo.name).flattenToShortString(), system));
        }
        Collections.sort(found, (a, b) -> a.label.toLowerCase(Locale.ROOT).compareTo(b.label.toLowerCase(Locale.ROOT)));
        Map<String, App> out = new LinkedHashMap<>();
        for (App a : found) out.put(a.pkg, a);
        return out;
    }

    private static String launchUrl(String pkg) {
        return "intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LEANBACK_LAUNCHER;package="
                + pkg + ";end";
    }

    private File themeDir() throws IOException {
        File dir = Config.dir(ctx);
        if (dir == null) throw new IOException("TV storage is unavailable");
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("TV storage is unavailable");
        return dir;
    }

    private static String stamp(File f) {
        return f != null && f.isFile() ? f.length() + "@" + f.lastModified() : "absent";
    }

    /** The wallpaper last chosen on the phone ("" when none); EditorBackground draws the presets from it. */
    static String savedWallpaper(Context ctx) {
        return readJson(new File(ctx.getFilesDir(), STATE_FILE)).optString("wallpaper", "");
    }

    private String wallpaperId(File wallpaper) {
        String id = savedWallpaper(ctx);
        if (!wallpaper.isFile()) return EditorLayout.preset(id) ? id : EditorLayout.QUIET_NIGHT;
        if (EditorLayout.photo(id)) return id;
        // A wallpaper pushed by a theme: give it a photo ID so the phone can keep it.
        id = "photo-" + UUID.randomUUID();
        saveState(id);
        return id;
    }

    private String revision(Map<String, App> apps) throws IOException {
        File dir = themeDir();
        return EditorLayout.revision(stamp(new File(dir, Config.FILE_NAME)), stamp(new File(dir, Config.WALLPAPER_NAME)),
                stamp(Order.file(ctx)), stamp(new File(ctx.getFilesDir(), STATE_FILE)), String.join(",", apps.keySet()));
    }

    JSONObject snapshot() throws IOException, JSONException {
        Config cfg = Config.load(ctx);
        Map<String, App> apps = apps();
        List<String> byLabel = new ArrayList<>(apps.keySet());
        List<String> hidden = new ArrayList<>();
        for (String p : cfg.hiddenApps) if (EditorLayout.validPackage(p) && !hidden.contains(p)) hidden.add(p);
        List<String> saved = new ArrayList<>();
        Order order = Order.load(Order.file(ctx));
        if (order != null && order.dock.equals(Order.dockKey(cfg.dockApps))) {
            for (String key : order.keys) {
                ComponentName cn = ComponentName.unflattenFromString(key);
                if (cn != null && !saved.contains(cn.getPackageName())) saved.add(cn.getPackageName());
            }
        }
        List<String> reported = EditorLayout.reportedOrder(cfg.dockApps, saved, byLabel, hidden);
        File wallpaper = new File(themeDir(), Config.WALLPAPER_NAME);
        String wallpaperId = wallpaperId(wallpaper);

        JSONObject layout = new JSONObject()
                .put("dockCount", Math.max(1, Math.min(7, cfg.columns)))
                .put("order", new JSONArray(reported))
                .put("hidden", new JSONArray(hidden.subList(0, Math.min(hidden.size(), EditorLayout.MAX_APPS))))
                .put("wallpaper", wallpaperId);
        JSONArray appList = new JSONArray();
        for (App a : apps.values()) {
            appList.put(new JSONObject().put("id", a.pkg).put("name", trim(a.label, 120)).put("launchURL", launchUrl(a.pkg))
                    .put("installed", true).put("system", a.system));
        }
        PackageManager pm = ctx.getPackageManager();
        for (String p : hidden) {   // hidden apps without a TV tile (Live TV) still need a name on the phone
            if (apps.containsKey(p) || appList.length() >= EditorLayout.MAX_APPS) continue;
            try {
                ApplicationInfo ai = pm.getApplicationInfo(p, 0);
                appList.put(new JSONObject().put("id", p).put("name", trim(String.valueOf(pm.getApplicationLabel(ai)), 120))
                        .put("launchURL", launchUrl(p)).put("installed", true)
                        .put("system", (ai.flags & ApplicationInfo.FLAG_SYSTEM) != 0));
            } catch (PackageManager.NameNotFoundException ignored) {
                // not installed or not visible to this app: the phone keeps it as a hidden ID only
            }
        }
        JSONObject snap = new JSONObject().put("revision", revision(apps)).put("layout", layout)
                .put("apps", appList).put("inputs", inputs());
        if (EditorLayout.photo(wallpaperId) && wallpaper.isFile() && wallpaper.length() <= EditorLayout.MAX_JPEG) {
            snap.put("wallpaperJPEG", Base64.encodeToString(new AtomicFile(wallpaper).readFully(), Base64.NO_WRAP));
        }
        return snap;
    }

    private JSONArray inputs() {
        JSONArray out = new JSONArray();
        try {
            TvInputManager tim = (TvInputManager) ctx.getSystemService(Context.TV_INPUT_SERVICE);
            if (tim == null) return out;
            for (TvInputInfo info : tim.getTvInputList()) {
                if (out.length() >= 40) break;
                if (!info.isPassthroughInput() || info.isHidden(ctx)) continue;
                CharSequence custom = info.loadCustomLabel(ctx);
                String name = String.valueOf(custom != null && custom.length() > 0 ? custom : info.loadLabel(ctx));
                String url = new Intent(Intent.ACTION_VIEW, TvContract.buildChannelUriForPassthroughInput(info.getId()))
                        .toUri(Intent.URI_INTENT_SCHEME);
                if (info.getId().length() > 512 || url.length() > 2048) continue;
                out.put(new JSONObject().put("id", info.getId()).put("name", trim(name, 120)).put("launchURL", url));
            }
        } catch (RuntimeException | JSONException ignored) {
            // Inputs are optional; the layout still works without them.
        }
        return out;
    }

    // ---- applyLayout ---------------------------------------------------------------------------------

    JSONObject applyLayout(JSONObject payload) throws IOException, JSONException {
        Map<String, App> apps = apps();
        if (!revision(apps).equals(payload.optString("expectedRevision"))) {
            throw new IllegalArgumentException("The TV layout changed since the phone last loaded it. Refresh and try again.");
        }
        JSONObject l = payload.getJSONObject("layout");
        EditorLayout.Layout layout = new EditorLayout.Layout(l.getInt("dockCount"), strings(l.optJSONArray("order")),
                strings(l.optJSONArray("hidden")), l.getString("wallpaper"));
        EditorLayout.validate(layout);
        byte[] jpeg = null;
        if (payload.has("wallpaperJPEG") && !payload.isNull("wallpaperJPEG")) {
            try {
                jpeg = Base64.decode(payload.getString("wallpaperJPEG"), Base64.DEFAULT);
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException("The wallpaper image is damaged");
            }
            checkJpeg(jpeg);
        }
        File dir = themeDir();
        File wallpaperFile = new File(dir, Config.WALLPAPER_NAME);
        String currentId = wallpaperId(wallpaperFile);
        if (EditorLayout.photo(layout.wallpaper) && jpeg == null
                && !(layout.wallpaper.equals(currentId) && wallpaperFile.isFile())) {
            throw new IllegalArgumentException("Include the photo to use it as the TV wallpaper");
        }

        List<String> byLabel = new ArrayList<>(apps.keySet());
        List<String> dock = EditorLayout.dock(layout, new HashSet<>(byLabel));
        List<String> grid = EditorLayout.gridOrder(layout, byLabel);

        // Wallpaper first: a failure here leaves the old layout untouched. The presets are drawn as a gradient behind
        // Home (EditorBackground), with no picture to decode or keep in memory; only a photo is stored as a file.
        if (EditorLayout.preset(layout.wallpaper)) {
            if (wallpaperFile.isFile() && !wallpaperFile.delete()) throw new IOException("could not remove the wallpaper");
        } else if (jpeg != null) {
            writeAtomic(wallpaperFile, jpeg);
        }
        File configFile = new File(dir, Config.FILE_NAME);
        JSONObject config = readJson(configFile);
        config.put("dock_apps", new JSONArray(dock));
        config.put("hidden_apps", new JSONArray(layout.hidden));
        config.put("columns", layout.dockCount);
        if (EditorLayout.photo(layout.wallpaper)) {
            config.put("wallpaper", true);
            // The focused app's colour glow (ambient_glow) tints a photo red with Netflix or YouTube in focus; a photo
            // is shown as taken. The marker lets a preset bring the theme's glow back.
            config.put("ambient_glow", false);
            config.put(GLOW_MARKER, true);
        } else if (config.optBoolean(GLOW_MARKER, false)) {
            config.remove("ambient_glow");
            config.remove(GLOW_MARKER);
        }
        config.remove("wallpaper_rotation_minutes");   // a single chosen picture, not a rotating collection
        writeAtomic(configFile, config.toString(2).getBytes(StandardCharsets.UTF_8));
        List<String> keys = new ArrayList<>();
        for (String p : grid) {
            App a = apps.get(p);
            if (a != null) keys.add(a.component);
        }
        if (!Order.save(Order.file(ctx), new Order(Order.dockKey(dock), keys))) {
            throw new IOException("could not save the app order");
        }
        saveState(layout.wallpaper);

        SharedPreferences choices = ctx.getSharedPreferences(Config.SETTINGS_NAME, Context.MODE_PRIVATE);
        choices.edit().remove(Config.WALLPAPER_CHOICE_KEY).remove("columns")
                .putLong(Config.SETTINGS_REVISION_KEY, choices.getLong(Config.SETTINGS_REVISION_KEY, 0) + 1).commit();
        EditorHome.rebuild();
        return snapshot();
    }

    private static void checkJpeg(byte[] jpeg) {
        if (jpeg.length == 0 || jpeg.length > EditorLayout.MAX_JPEG) throw new IllegalArgumentException("Wallpaper exceeds 1 MB");
        BitmapFactory.Options o = new BitmapFactory.Options();
        o.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.length, o);
        if (o.outWidth <= 0 || o.outHeight <= 0 || !"image/jpeg".equals(o.outMimeType)
                || o.outWidth > 8192 || o.outHeight > 8192) {
            throw new IllegalArgumentException("The wallpaper must be a JPEG image");
        }
    }

    // ---- uninstall -----------------------------------------------------------------------------------

    JSONObject uninstall(JSONObject payload) throws JSONException {
        String pkg = payload.optString("package");
        if (!EditorLayout.validPackage(pkg) || pkg.equals(ctx.getPackageName())) {
            throw new IllegalArgumentException("This app can't be uninstalled from the phone");
        }
        ApplicationInfo ai;
        try {
            ai = ctx.getPackageManager().getApplicationInfo(pkg, 0);
        } catch (PackageManager.NameNotFoundException e) {
            throw new IllegalArgumentException("That app is no longer installed. Refresh the app list.");
        }
        if ((ai.flags & (ApplicationInfo.FLAG_SYSTEM | ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0) {
            throw new IllegalArgumentException("System apps can only be hidden");
        }
        Intent intent = new Intent(Intent.ACTION_DELETE, Uri.fromParts("package", pkg, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(intent);
        return new JSONObject().put("status", "confirmationRequired");
    }

    // ---- files ---------------------------------------------------------------------------------------

    private void saveState(String wallpaperId) {
        try {
            writeAtomic(new File(ctx.getFilesDir(), STATE_FILE),
                    new JSONObject().put("wallpaper", wallpaperId).toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException | JSONException ignored) {
            // Only the wallpaper's name on the phone depends on this file.
        }
    }

    static JSONObject readJson(File f) {
        if (!f.isFile()) return new JSONObject();
        try {
            return new JSONObject(new String(new AtomicFile(f).readFully(), StandardCharsets.UTF_8));
        } catch (IOException | JSONException e) {
            return new JSONObject();
        }
    }

    private static void writeAtomic(File f, byte[] data) throws IOException {
        AtomicFile af = new AtomicFile(f);
        FileOutputStream out = af.startWrite();
        try {
            out.write(data);
            af.finishWrite(out);
        } catch (IOException e) {
            af.failWrite(out);
            throw e;
        }
    }

    private static List<String> strings(JSONArray a) throws JSONException {
        List<String> out = new ArrayList<>();
        if (a == null) return out;
        if (a.length() > EditorLayout.MAX_APPS) throw new IllegalArgumentException("Too many apps in the layout");
        for (int i = 0; i < a.length(); i++) out.add(a.getString(i));
        return out;
    }

    private static String trim(String s, int max) {
        return s.length() <= max ? s : s.substring(0, max);
    }
}
