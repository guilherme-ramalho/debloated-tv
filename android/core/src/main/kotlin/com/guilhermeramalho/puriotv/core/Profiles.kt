package com.guilhermeramalho.puriotv.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File

/**
 * Where profile folders come from (ios/Resources/Profiles: one folder per TV with profile.json, debloat.txt and
 * optional tv.json / config.json). The app implements it over AssetManager; [DirectoryProfileSource] reads a folder.
 */
interface ProfileSource {
    /** The profile folder names. */
    fun ids(): List<String>
    /** One file of a profile folder, null when it doesn't exist. */
    fun read(id: String, file: String): ByteArray?
}

class DirectoryProfileSource(private val root: File) : ProfileSource {
    override fun ids(): List<String> = root.listFiles()?.filter { it.isDirectory }?.map { it.name }?.sorted() ?: emptyList()
    override fun read(id: String, file: String): ByteArray? = File(File(root, id), file).takeIf { it.isFile }?.readBytes()
}

internal val ProfileJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

/** A supported TV: upstream's tested debloat.txt plus what the app needs to run it alone (Resources/Profiles/README.md). */
class DebloatProfile(val manifest: Manifest, val list: DebloatList, val theme: JsonObject, val notes: String = "") {
    @Serializable
    data class Manifest(
        val id: String,
        val name: String,
        val source: String,
        val developmentOnly: Boolean? = null,
        val match: Map<String, List<String>>,
        val stockLauncher: String? = null,
        val launcher: LauncherOptions,
        val dockCandidates: List<String>,
        /** A list from cleanyourtv brought in by scripts/import-tv-lists.py: chosen by ProfileMatcher, not `match`. */
        val community: Boolean? = null,
        val brand: String? = null,
        val os: String? = null,
        /** Whether setup may offer the new Home screen with this list (the importer's rules). */
        val homeScreen: Boolean? = null,
        /** Why not: fireOS, debloatOnly, cvte or noConfig. */
        val homeScreenNote: String? = null,
        /** Sentences from the list's header that warn or say what to keep, shown on the review screen. */
        val warnings: List<String>? = null,
        /** How the list identifies its own unit: "device", "product", "model" (the importer's reading of its header). */
        val names: Map<String, List<String>>? = null,
    )

    val id: String get() = manifest.id
    val isCommunity: Boolean get() = manifest.community == true
    /** Hand-written profiles always may; a community list only when the importer allowed it. */
    val offersHomeScreen: Boolean get() = !isCommunity || manifest.homeScreen == true

    override fun equals(other: Any?) = other is DebloatProfile && manifest == other.manifest && list == other.list
    override fun hashCode() = manifest.hashCode() * 31 + list.hashCode()
    override fun toString() = "DebloatProfile($id)"

    /** Every property in `match` must be one of its listed values. */
    fun matches(properties: Map<String, String>): Boolean = manifest.match.isNotEmpty() && manifest.match.all { (key, values) ->
        val value = properties[key]?.trim() ?: return@all false
        value in values
    }

    /** config.json for the launcher: the profile's theme with the dock the user chose (pretty, sorted keys). */
    fun themeConfig(dock: List<String>): ByteArray {
        val config = modelSpecificDefaults.toMutableMap()
        config.putAll(theme)
        config["dock_apps"] = JsonArray(dock.filter(Pattern::isPackage).map(::JsonPrimitive))
        // The phone is where Home is arranged: the launcher's tile menu (on by default since 3.3: hold OK for Move,
        // Remove from Home) would change the layout behind the phone's editor. A profile can still turn it on.
        if ("tile_menu" !in config) config["tile_menu"] = JsonPrimitive(false)
        return prettyJson.encodeToString(JsonElement.serializer(), sorted(JsonObject(config))).toByteArray()
    }

    companion object {
        /**
         * The launcher's built-in defaults for these are upstream's author's TV (TCL: its remote's app buttons and
         * Settings keycode, com.tcl.tv as Live TV). Every model starts from none of them; its profile's theme names its
         * own. An empty list or string in config.json overrides the built-in default.
         */
        val modelSpecificDefaults: Map<String, JsonElement> = mapOf(
            "app_keys" to JsonArray(emptyList()), "settings_key_keycodes" to JsonArray(emptyList()),
            "hidden_apps" to JsonArray(emptyList()), "live_tv_package" to JsonPrimitive(""),
        )

        private val prettyJson = Json { prettyPrint = true }

        internal fun sorted(e: JsonElement): JsonElement = when (e) {
            is JsonObject -> JsonObject(e.toSortedMap().mapValues { sorted(it.value) })
            is JsonArray -> JsonArray(e.map(::sorted))
            else -> e
        }

        /** Reads one profile folder: profile.json, debloat.txt and (optional) tv.json. Throws when it can't. */
        fun load(source: ProfileSource, id: String): DebloatProfile {
            val data = source.read(id, "profile.json") ?: throw java.io.FileNotFoundException("$id/profile.json")
            val text = data.decodeToString()
            val manifest = ProfileJson.decodeFromString(Manifest.serializer(), text)
            val obj = Json.parseToJsonElement(text).jsonObject
            val listText = source.read(id, "debloat.txt") ?: throw java.io.FileNotFoundException("$id/debloat.txt")
            val list = DebloatList.parse(listText.decodeToString())
            val notes = try {
                source.read(id, "tv.json")?.let { (Json.parseToJsonElement(it.decodeToString()) as? JsonObject)?.get("notes")?.jsonPrimitive?.content }
            } catch (e: Exception) { null } ?: ""
            return DebloatProfile(manifest, list, obj["theme"] as? JsonObject ?: JsonObject(emptyMap()), notes)
        }

        /** All profiles (the app's bundled Profiles), skipping development ones unless asked; unreadable ones are left out. */
        fun loadAll(source: ProfileSource, includeDevelopment: Boolean): List<DebloatProfile> =
            source.ids().mapNotNull { id -> try { load(source, id) } catch (e: Exception) { null } }
                .filter { includeDevelopment || it.manifest.developmentOnly != true }
                .sortedBy { it.manifest.name }

        fun match(properties: Map<String, String>, profiles: List<DebloatProfile>): DebloatProfile? =
            profiles.firstOrNull { it.matches(properties) }
    }
}

/** One list setup can offer for a TV, and why. */
data class ProfileMatch(
    val profile: DebloatProfile,
    val kind: Kind,
    /** List apps installed on this TV and still enabled: what setup would offer. */
    val present: Int,
    /** Which of the TV's names the list mentions ("BeyondTV4"); empty for a closest match. */
    val named: List<String>,
    internal val score: Double,
) {
    enum class Kind {
        /** A hand-written profile whose `match` fits this TV exactly (tested with Purio TV). */
        TESTED,
        /** A community list that names this TV's device or product in its header (made for this model). */
        MODEL,
        /** A community list for another model of the same platform: the closest one. */
        CLOSEST,
    }
    val id: String get() = profile.id
}

/**
 * Picks cleanyourtv lists for a TV the way an agent would (ProfileMatcher.swift): the list whose own unit is this TV
 * (its device and product names, read by the importer from the list's header), or failing that the one whose brand's
 * own apps are most present on it. Whichever list is chosen, only its own entries are ever offered, and the safety
 * checks still run.
 */
object ProfileMatcher {
    fun rank(properties: Map<String, String>, installed: Set<String>, disabled: Set<String> = emptySet(),
             profiles: List<DebloatProfile>, limit: Int = 8): List<ProfileMatch> {
        fun value(key: String) = (properties[key] ?: "").trim().lowercase()
        val device = value("ro.product.device"); val product = value("ro.product.name"); val model = value("ro.product.model")
        val maker = value("ro.product.manufacturer")
        fun names(p: DebloatProfile, kind: String) = (p.manifest.names?.get(kind) ?: emptyList()).map { it.lowercase() }.toSet()
        // A board name several lists share (BeyondTV4 is on 11) doesn't say which of them this TV is.
        val deviceShared = device.isNotEmpty() && profiles.count { it.isCommunity && device in names(it, "device") } > 1
        val out = mutableListOf<ProfileMatch>()
        for (profile in profiles) {
            val present = profile.list.entries.count { it.packageName in installed && it.packageName !in disabled }
            if (!profile.isCommunity) {
                if (profile.matches(properties)) out += ProfileMatch(profile, ProfileMatch.Kind.TESTED, present, emptyList(), 100.0)
                continue
            }
            if (present <= 0) continue
            val products = names(profile, "product"); val devices = names(profile, "device"); val models = names(profile, "model")
            val productHit = product.isNotEmpty() && product in products
            val deviceHit = device.isNotEmpty() && device in devices
            val modelHit = model.isNotEmpty() && model in models
            // Its own unit: the same product, or the same model, or a board name only this list uses (and no other product named).
            val identifies = productHit || modelHit || (deviceHit && !deviceShared && (products.isEmpty() || productHit))
            var score = (if (productHit) 3.0 else 0.0) + (if (modelHit) 2.0 else 0.0) + (if (deviceHit) (if (deviceShared) 1.0 else 2.0) else 0.0)
            val brand = (profile.manifest.brand ?: "").lowercase()
            val sameBrand = maker.isNotEmpty() && (brand.contains(maker) || (brand.isNotEmpty() && maker.contains(brand)))
            if (sameBrand) score += 0.5
            // The brand's own apps tell platforms apart; Google's and Android's are on every TV.
            val vendor = profile.list.entries.filter {
                !(it.packageName.startsWith("com.google.") || it.packageName.startsWith("com.android.") || it.packageName.startsWith("android."))
            }
            val pool = vendor.ifEmpty { profile.list.entries }
            val overlap = pool.count { it.packageName in installed }.toDouble() / maxOf(1, pool.size)
            score += overlap * 2
            if (!(identifies || deviceHit || (sameBrand && overlap >= 0.3) || overlap >= 0.6)) continue
            val named = listOf(productHit to properties["ro.product.name"], deviceHit to properties["ro.product.device"],
                modelHit to properties["ro.product.model"]).mapNotNull { (hit, v) -> if (hit) v?.trim() else null }
            out += ProfileMatch(profile, if (identifies) ProfileMatch.Kind.MODEL else ProfileMatch.Kind.CLOSEST, present,
                if (identifies) named else emptyList(), score)
        }
        return out.sortedWith(compareByDescending<ProfileMatch> { it.score }.thenBy { it.profile.manifest.name }).take(limit)
    }
}
