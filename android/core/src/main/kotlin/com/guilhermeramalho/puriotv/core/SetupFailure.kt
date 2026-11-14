package com.guilhermeramalho.puriotv.core

/**
 * Why a TV setup step stopped, as a code the app turns into a translated sentence (strings.xml), with the values the
 * sentence needs in [SetupFailure.args]. [english] is the iPhone app's English text (%1$s… for the args), used as the
 * exception message for logs and as a fallback.
 */
enum class SetupIssue(val english: String) {
    // ADB
    ADB_UNREACHABLE("Couldn't reach the TV's debugging port %1\$s. Check that network debugging is on. (%2\$s)"),
    ADB_REFUSED("The TV refused this phone. Accept \"Allow USB debugging?\" on the TV and try again."),
    ADB_BUSY("Another TV command is still running"),
    ADB_STREAM_REFUSED("The TV refused %1\$s"),
    ADB_FILE_REFUSED("The TV refused the file: %1\$s"),
    ADB_KEY_SIZE("The TV debugging key must be RSA-2048"),

    // Debloat
    LIST_NOT_PACKAGES("This list has lines that are not package names: %1\$s"),
    NO_APPS_LISTED("The TV listed no apps, so nothing was changed. Check the connection and try again."),
    APPLY_UNCHECKED("The TV didn't say which apps are on, so this step couldn't be checked. Reconnect and review again."),
    RESTORE_OTHER_TV("This recovery record belongs to another TV (%1\$s), so nothing was changed. Pick the record made on this TV."),
    RESTORE_UNCHECKED("The restore ran, but the TV didn't say which apps are on now, so it couldn't be checked. Run it again."),

    // New Home screen
    HOME_CHOOSER_AMBIGUOUS("Home has no default and %1\$s stock launchers claim it. Pick a default Home on the TV first."),
    HOME_SETUP_WIZARD("Home belongs to Google TV's setup wizard. Finish the TV's setup, or include the setup wizard in the debloat, then try again."),
    HOME_UNKNOWN("Home currently belongs to %1\$s, which isn't a stock launcher this app knows. Nothing was changed."),
    OLD_ANDROID("This TV runs Android SDK %1\$s; the new Home screen needs Android 8.0 (SDK 26) or newer. Nothing was changed."),
    APK_DAMAGED("The Home screen arrived damaged on the TV (checksum mismatch). Nothing was installed; try again."),
    INSTALL_OLDER_SDK("The TV refused the Home screen as too new for its Android version. Nothing else was changed."),
    INSTALL_OTHER_KEY("A different build of this Home screen is already on the TV, signed with another key. Uninstall it on the TV first, then try again."),
    INSTALL_DOWNGRADE("The TV already has a newer Home screen than this app carries. Update Purio TV, then try again. Nothing was changed."),
    INSTALL_REFUSED("The TV refused to install the Home screen: %1\$s"),
    HOME_DID_NOT_START("The new Home screen didn't start, so the stock one was left as it was."),
    HOME_STAYED("Home stayed on %1\$s instead of the new Home screen. The stock one was never turned off, so the TV works as before."),
    HOME_SWITCH_NO_ANSWER("The TV stopped answering while Home was being switched. The stock Home screen was put back."),
    HOME_WENT_ELSEWHERE("Home went to %1\$s instead of the new Home screen, so the stock one was put back. On Google TV this usually means the setup wizard also claims Home: include it in the debloat, then try again."),
    HELPERS_NOT_GRANTED("The new Home screen is installed, but the TV didn't give it permission to restore the remote's helpers after a force stop. Run setup again."),
    SECURE_SETTINGS_KEPT("The new Home screen is installed, but it may still hold permission to change system settings from an earlier install. Run setup again."),
    INVALID_THEME("Invalid Home layout"),
    THEME_REFUSED("The TV refused the Home layout: %1\$s"),

    // The guided setup (SetupSequence)
    NOT_CONNECTED("Connect to the TV first"),
    INVALID_ADDRESS("Enter the TV's IP address, for example 192.168.1.20"),
    NO_BUNDLED_HOME("This build doesn't include the Home screen."),
    STOPPED_DURING_GROUP("The TV stopped answering during group %1\$s. Reconnect and review again; nothing after it was changed."),
    WIFI_NOT_BACK("The TV didn't come back after saving its Wi-Fi again. On the TV, join %1\$s in Settings › Network & Internet, then connect again. Nothing else was changed."),
    WIFI_NOT_SAVED("Couldn't save %1\$s again (check the password). On the TV, join it in Settings › Network & Internet, then review again. Nothing else was changed."),
    DEBUGGING_UNREACHABLE("The TV is no longer connected. Turn debugging off in the TV's menus."),
    UPDATE_HOME_NOT_OURS("The TV's Home is its own Home screen again, so there's nothing to update. Run setup to bring the new one back. Nothing was changed."),
    UPDATE_NO_PROFILE("This phone didn't set up this TV's Home screen, so it can't update it from here. Nothing was changed."),
    UPDATE_NOT_INSTALLED("The new Home screen isn't on this TV. Use Run setup instead. Nothing was changed."),
    UPDATE_STILL_OLD("The TV still reports the old Home screen after the update. Try again."),
}

class SetupFailure(val issue: SetupIssue, vararg args: String) :
    Exception(String.format(java.util.Locale.ROOT, issue.english, *args)) {
    val args: List<String> = args.toList()
}
