package com.guilhermeramalho.puriotv

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * The iPhone app's colours (QuietTheme in QuietStyle.swift) as a Material 3 dark scheme: navy background, slightly
 * lighter cards, muted blue-grey secondary text, cyan accent. Layout and components follow Material, not iOS.
 */
object Quiet {
    val background = Color(0xFF101D32)
    val panel = Color(0xFF18253A)
    val panelHigh = Color(0xFF1F2E47)
    val muted = Color(0xFFAEB9CC)
    val cyan = Color(0xFF9AE3EC)
    val toggle = Color(0xFF479C8E)
    val ink = Color(0xFF13161C)          // remote keys
    val inputs = Color(0xFF16304F)
    val green = Color(0xFF5CC8A8)
    val amber = Color(0xFFF0AA5A)
    val power = Color(0xFFFF575C)
    val edge = Color.White.copy(alpha = 0.07f)
}

private val scheme = darkColorScheme(
    primary = Quiet.cyan,
    onPrimary = Color(0xFF13213A),
    primaryContainer = Color(0xFF1C4A57),
    onPrimaryContainer = Color(0xFFD7F6FA),
    secondary = Quiet.muted,
    onSecondary = Color(0xFF13213A),
    secondaryContainer = Quiet.panelHigh,
    onSecondaryContainer = Color.White,
    tertiary = Quiet.toggle,
    background = Quiet.background,
    onBackground = Color.White,
    surface = Quiet.background,
    onSurface = Color.White,
    surfaceVariant = Quiet.panel,
    onSurfaceVariant = Quiet.muted,
    surfaceContainerLowest = Color(0xFF0B1526),
    surfaceContainerLow = Color(0xFF13213A),
    surfaceContainer = Quiet.panel,
    surfaceContainerHigh = Quiet.panelHigh,
    surfaceContainerHighest = Color(0xFF263652),
    outline = Color(0xFF46526A),
    outlineVariant = Color(0xFF2A374F),
    error = Quiet.amber,
    onError = Color(0xFF2B1600),
)

@Composable
fun PurioTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = scheme, content = content)
