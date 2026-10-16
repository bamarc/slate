//! Role names, action derivation, and parsing of Slint's stringified accessible properties.

use i_slint_core::accessibility::SupportedAccessibilityAction;
use i_slint_core::items::AccessibleRole;

use super::types::ActionKind;

/// Maps an [`AccessibleRole`] to its snake_case wire name. Unknown (future) variants map to
/// `"unknown"` because the enum is `#[non_exhaustive]`.
pub fn role_name(role: AccessibleRole) -> &'static str {
    match role {
        AccessibleRole::None => "none",
        AccessibleRole::Button => "button",
        AccessibleRole::Checkbox => "checkbox",
        AccessibleRole::Combobox => "combobox",
        AccessibleRole::Groupbox => "groupbox",
        AccessibleRole::Image => "image",
        AccessibleRole::List => "list",
        AccessibleRole::Slider => "slider",
        AccessibleRole::Spinbox => "spinbox",
        AccessibleRole::Tab => "tab",
        AccessibleRole::TabList => "tab_list",
        AccessibleRole::TabPanel => "tab_panel",
        AccessibleRole::Text => "text",
        AccessibleRole::Table => "table",
        AccessibleRole::Tree => "tree",
        AccessibleRole::ProgressIndicator => "progress_indicator",
        AccessibleRole::TextInput => "text_input",
        AccessibleRole::Switch => "switch",
        AccessibleRole::ListItem => "list_item",
        AccessibleRole::RadioButton => "radio_button",
        AccessibleRole::RadioGroup => "radio_group",
        AccessibleRole::WindowTitleBar => "window_title_bar",
        AccessibleRole::Banner => "banner",
        AccessibleRole::Complementary => "complementary",
        AccessibleRole::ContentInfo => "content_info",
        AccessibleRole::Form => "form",
        AccessibleRole::Main => "main",
        AccessibleRole::Navigation => "navigation",
        AccessibleRole::Region => "region",
        AccessibleRole::Search => "search",
        _ => "unknown",
    }
}

/// Derives the semantic actions of an element.
///
/// `supported` is `ItemRc::supported_accessibility_actions()`; `checkable` and `focusable` come
/// from the accessible string properties. The result is sorted (enum order) and deduplicated.
pub fn derive_actions(
    role: &str,
    supported: SupportedAccessibilityAction,
    checkable: bool,
    focusable: bool,
) -> Vec<ActionKind> {
    let mut out = Vec::new();
    if supported.contains(SupportedAccessibilityAction::Default) {
        out.push(ActionKind::Activate);
        if checkable {
            out.push(ActionKind::Toggle);
        }
    }
    let can_inc = supported.contains(SupportedAccessibilityAction::Increment);
    let can_dec = supported.contains(SupportedAccessibilityAction::Decrement);
    if can_inc {
        out.push(ActionKind::Increment);
    }
    if can_dec {
        out.push(ActionKind::Decrement);
    }
    if supported.contains(SupportedAccessibilityAction::Expand) {
        out.push(ActionKind::Expand);
    }
    if supported.contains(SupportedAccessibilityAction::SetValue) {
        out.push(ActionKind::SetValue);
        if role == "text_input" {
            out.push(ActionKind::Type);
        }
    }
    if focusable {
        out.push(ActionKind::Focus);
    }
    if (role == "slider" || role == "spinbox") && can_inc && can_dec {
        out.push(ActionKind::SetValue);
    }
    out.sort();
    out.dedup();
    out
}

/// Parses a Slint-stringified boolean. Slint encodes accessible booleans as `"true"`/`"false"`.
pub fn parse_bool(s: &str) -> Option<bool> {
    match s {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// Parses a Slint-stringified number. Surrounding whitespace is trimmed; NaN and infinities are
/// rejected.
pub fn parse_f32(s: &str) -> Option<f32> {
    let v: f32 = s.trim().parse().ok()?;
    v.is_finite().then_some(v)
}
