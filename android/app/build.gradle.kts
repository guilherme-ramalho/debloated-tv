plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.guilhermeramalho.puriotv"
    compileSdk = 35

    defaultConfig {
        // Permanent once published on Google Play; see android/README.md.
        applicationId = "com.guilhermeramalho.puriotv"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        // The debug build installs beside the release one, like the iPhone's "Debloated TV Dev" scheme.
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    // The iPhone app's TV lists, TV Home APK and licence, copied in at build time (see setupAssets below).
    sourceSets["debug"].assets.srcDir(layout.buildDirectory.dir("setupAssets/debug"))
    sourceSets["release"].assets.srcDir(layout.buildDirectory.dir("setupAssets/release"))
}

// One source of truth for TV setup: ios/Resources. Profiles/<id>/ (the dev-* test lists only in debug builds) and
// Launcher/ (tvhome.apk + tvhome.json come from scripts/bundle-launcher.sh and aren't in git; without them the app
// can't install the new Home, and says so).
val resources = rootProject.file("../ios/Resources")
for (variant in listOf("debug", "release")) {
    val task = tasks.register<Sync>("setupAssets${variant.replaceFirstChar { it.uppercase() }}") {
        into(layout.buildDirectory.dir("setupAssets/$variant"))
        from(resources.resolve("Profiles")) {
            into("Profiles")
            if (variant == "release") exclude("dev-*/**")
            exclude("README.md")
        }
        from(resources.resolve("Launcher")) {
            into("Launcher")
            include("tvhome.apk", "tvhome.json", "LICENSE-cleanyourtv.txt")
        }
    }
    tasks.matching { it.name == "merge${variant.replaceFirstChar { c -> c.uppercase() }}Assets" }.configureEach { dependsOn(task) }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.coroutines.android)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.compose.tooling.preview)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    debugImplementation(libs.compose.tooling)
    testImplementation(libs.junit)
}
