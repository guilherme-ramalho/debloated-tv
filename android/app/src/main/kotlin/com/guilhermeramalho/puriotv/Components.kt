package com.guilhermeramalho.puriotv

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.guilhermeramalho.puriotv.core.RemoteFailure

/** A scrolling page with the iPhone's margins (QuietPage), at most 600 dp wide on tablets. */
@Composable
fun Page(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max = 600.dp).fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}

/** A tab's root title, with an optional action on the right (QuietHeading). */
@Composable
fun PageTitle(text: String, trailing: @Composable () -> Unit = {}) =
    Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold, fontSize = 26.sp), modifier = Modifier.weight(1f))
        trailing()
    }

/**
 * A screen pushed inside a tab (the iPhone's NavigationLink destination), with a Material top app bar and Up.
 * System Back pops it too.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubPage(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}, content: @Composable ColumnScope.() -> Unit) {
    BackHandler(onBack = onBack)
    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(title) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) } },
            actions = { actions() },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Quiet.background),
        )
        Page(content)
    }
}

@Composable
fun SectionTitle(text: String) =
    Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))

@Composable
fun Caption(text: String, modifier: Modifier = Modifier) =
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier)

/** A group of rows on a card (QuietCard). */
@Composable
fun RowCard(content: @Composable ColumnScope.() -> Unit) = Card(
    shape = RoundedCornerShape(19.dp),
    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer, contentColor = Color.White),
    border = BorderStroke(1.dp, Quiet.edge),
    modifier = Modifier.fillMaxWidth(),
    content = content,
)

@Composable
fun RowDivider() = HorizontalDivider(color = Quiet.edge)

/** A row that opens something or does something (QuietRow): icon, title, optional detail and value, chevron. */
@Composable
fun NavRow(
    icon: ImageVector?, title: String, detail: String? = null, value: String? = null,
    chevron: Boolean = true, enabled: Boolean = true, tint: Color = Color.White, onClick: (() -> Unit)? = null,
) = ListItem(
    headlineContent = { Text(title, fontWeight = FontWeight.Medium, color = tint) },
    supportingContent = detail?.let { { Text(it, style = MaterialTheme.typography.bodySmall, color = Quiet.muted) } },
    leadingContent = icon?.let { { Icon(it, null, tint = tint) } },
    trailingContent = if (value == null && !(chevron && onClick != null)) null else ({
        Row(verticalAlignment = Alignment.CenterVertically) {
            value?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Quiet.muted, maxLines = 1, modifier = Modifier.widthIn(max = 140.dp)) }
            if (chevron && onClick != null) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Quiet.muted)
        }
    }),
    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    modifier = (if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier).alpha(if (enabled) 1f else 0.45f),
)

/** A setting with a switch (QuietToggleStyle): the whole row toggles. */
@Composable
fun SwitchRow(title: String, detail: String? = null, checked: Boolean, icon: ImageVector? = null, enabled: Boolean = true, onChange: (Boolean) -> Unit) = ListItem(
    headlineContent = { Text(title, fontWeight = FontWeight.Medium) },
    supportingContent = detail?.let { { Text(it, style = MaterialTheme.typography.bodySmall, color = Quiet.muted) } },
    leadingContent = icon?.let { { Icon(it, null) } },
    trailingContent = {
        Switch(checked = checked, onCheckedChange = null, enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = Quiet.toggle, checkedThumbColor = Color.White))
    },
    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    modifier = Modifier.clickable(enabled = enabled) { onChange(!checked) }.alpha(if (enabled) 1f else 0.6f),
)

/** − value + (QuietCounter). */
@Composable
fun Counter(value: Int, range: IntRange, fewer: String, more: String, onChange: (Int) -> Unit) =
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalIconButton(onClick = { onChange(maxOf(range.first, value - 1)) }, enabled = value > range.first, modifier = Modifier.size(40.dp)) {
            Icon(Icons.Rounded.Remove, fewer)
        }
        Text("$value", fontSize = 15.sp, modifier = Modifier.widthIn(min = 18.dp))
        FilledTonalIconButton(onClick = { onChange(minOf(range.last, value + 1)) }, enabled = value < range.last, modifier = Modifier.size(40.dp)) {
            Icon(Icons.Rounded.Add, more)
        }
    }

@Composable
fun PrimaryButton(text: String, icon: ImageVector? = null, enabled: Boolean = true, onClick: () -> Unit) =
    Button(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().height(48.dp)) {
        icon?.let { Icon(it, null, Modifier.size(18.dp)); androidx.compose.foundation.layout.Spacer(Modifier.width(8.dp)) }
        Text(text)
    }

@Composable
fun SecondaryButton(text: String, icon: ImageVector? = null, enabled: Boolean = true, onClick: () -> Unit) =
    OutlinedButton(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().height(48.dp)) {
        icon?.let { Icon(it, null, Modifier.size(18.dp)); androidx.compose.foundation.layout.Spacer(Modifier.width(8.dp)) }
        Text(text)
    }

/** A confirmation (the iPhone's confirmationDialog). */
@Composable
fun Confirm(title: String, message: String? = null, confirm: String, destructive: Boolean = false, onDismiss: () -> Unit, onConfirm: () -> Unit) =
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = message?.let { { Text(it) } },
        confirmButton = { TextButton(onClick = { onDismiss(); onConfirm() }) { Text(confirm, color = if (destructive) Quiet.amber else Quiet.cyan) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )

/** A message shown to the person, already in their language. */
class UserMessage(text: String) : Exception(text)

/** What to show for an error: the app's own text, the problem's text, or a generic one. */
fun errorText(context: Context, e: Throwable?): String = when (e) {
    is UserMessage -> e.message ?: context.getString(R.string.problem_other)
    is RemoteFailure -> context.getString(e.problem.message())
    else -> context.getString(R.string.problem_other)
}
