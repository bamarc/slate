//! Pure unit tests for the semantic types, role mapping, action derivation and error table.
//! These need no window; they cover contracts §2 and §3.

use i_slint_core::accessibility::SupportedAccessibilityAction as S;
use i_slint_core::items::AccessibleRole as R;
use serde_json::json;
use slate_agent::error::Candidate;
use slate_agent::semantic::roles::{derive_actions, parse_bool, parse_f32, role_name};
use slate_agent::semantic::types::*;
use slate_agent::AgentError;

// ---------------------------------------------------------------- ElementRef

#[test]
fn element_ref_from_index_and_display() {
    let r = ElementRef::from_index(42);
    assert_eq!(r.as_str(), "e42");
    assert_eq!(r.to_string(), "e42");
    assert_eq!(serde_json::to_value(&r).unwrap(), json!("e42"));
}

#[test]
fn element_ref_parse_accepts_only_e_digits() {
    assert_eq!(ElementRef::parse("e1"), Some(ElementRef("e1".into())));
    assert_eq!(ElementRef::parse("e0"), Some(ElementRef("e0".into())));
    assert_eq!(ElementRef::parse("e007"), Some(ElementRef("e007".into())));
    for bad in ["", "e", "E1", "e-1", "e1x", "x1", "e 1", " e1", "e1 ", "ee1", "1", "e+1", "e1.0", "é1"] {
        assert_eq!(ElementRef::parse(bad), None, "{bad:?} must be rejected");
    }
}

// ---------------------------------------------------------------- serde shapes

#[test]
fn selector_serializes_only_set_fields_and_roundtrips() {
    let s = Selector { id: Some("a".into()), name_contains: Some("Sav".into()), ..Default::default() };
    assert_eq!(serde_json::to_value(&s).unwrap(), json!({"id": "a", "name_contains": "Sav"}));
    assert_eq!(serde_json::from_value::<Selector>(json!({})).unwrap(), Selector::default());
    assert_eq!(serde_json::from_value::<Selector>(serde_json::to_value(&s).unwrap()).unwrap(), s);
}

#[test]
fn target_is_externally_tagged_snake_case() {
    let t = Target::Ref(ElementRef::from_index(3));
    assert_eq!(serde_json::to_value(&t).unwrap(), json!({"ref": "e3"}));
    let t = Target::Selector(Selector { role: Some("button".into()), ..Default::default() });
    assert_eq!(serde_json::to_value(&t).unwrap(), json!({"selector": {"role": "button"}}));
}

fn leaf(reference: u64) -> SemanticNode {
    SemanticNode {
        reference: ElementRef::from_index(reference),
        role: "button".into(),
        name: "OK".into(),
        value: None,
        description: None,
        id: None,
        states: NodeStates { enabled: true, visible: true, ..Default::default() },
        actions: vec![ActionKind::Activate],
        range: None,
        bounds: None,
        debug: None,
        children: vec![],
    }
}

#[test]
fn semantic_node_exact_json_omits_optionals_and_renames_ref() {
    let v = serde_json::to_value(leaf(1)).unwrap();
    assert_eq!(
        v,
        json!({
            "ref": "e1",
            "role": "button",
            "name": "OK",
            "states": {"enabled": true, "visible": true, "focused": false, "read_only": false},
            "actions": ["activate"]
        })
    );
}

#[test]
fn semantic_node_full_json_roundtrip() {
    let mut n = leaf(2);
    n.value = Some("v".into());
    n.description = Some("d".into());
    n.id = Some("i".into());
    n.states.checked = Some(true);
    n.states.expanded = Some(false);
    n.states.selected = Some(true);
    n.range = Some(ValueRange { min: 0.0, max: 10.0, step: 1.0 });
    n.bounds = Some(slate_agent::model::Rect { x: 1.0, y: 2.0, width: 3.0, height: 4.0 });
    n.debug = Some(DebugInfo { element_id: "x".into(), type_name: "T".into() });
    n.children = vec![leaf(3)];
    let v = serde_json::to_value(&n).unwrap();
    assert_eq!(v["value"], "v");
    assert_eq!(v["range"], json!({"min": 0.0, "max": 10.0, "step": 1.0}));
    assert_eq!(v["children"][0]["ref"], "e3");
    assert_eq!(serde_json::from_value::<SemanticNode>(v).unwrap(), n);
}

#[test]
fn snapshot_options_defaults_and_modes() {
    let o: SnapshotOptions = serde_json::from_value(json!({})).unwrap();
    assert_eq!(o, SnapshotOptions::default());
    assert_eq!(o.mode, SnapshotMode::Semantic);
    assert!(!o.include_bounds);
    let o: SnapshotOptions =
        serde_json::from_value(json!({"mode": "full", "root": "e5", "include_bounds": true, "max_depth": 2})).unwrap();
    assert_eq!(o.mode, SnapshotMode::Full);
    assert_eq!(o.root, Some(ElementRef("e5".into())));
    assert_eq!(o.max_depth, Some(2));
    assert_eq!(serde_json::to_value(SnapshotOptions::default()).unwrap(), json!({"mode": "semantic", "include_bounds": false}));
}

#[test]
fn action_kind_wire_names_order_and_as_str_agree() {
    let all = [
        (ActionKind::Activate, "activate"),
        (ActionKind::Toggle, "toggle"),
        (ActionKind::SetValue, "set_value"),
        (ActionKind::Increment, "increment"),
        (ActionKind::Decrement, "decrement"),
        (ActionKind::Expand, "expand"),
        (ActionKind::Focus, "focus"),
        (ActionKind::Type, "type"),
    ];
    for (k, name) in all {
        assert_eq!(serde_json::to_value(k).unwrap(), json!(name));
        assert_eq!(k.as_str(), name);
        assert_eq!(serde_json::from_value::<ActionKind>(json!(name)).unwrap(), k);
    }
    let kinds: Vec<_> = all.iter().map(|(k, _)| *k).collect();
    let mut sorted = kinds.clone();
    sorted.sort();
    assert_eq!(kinds, sorted, "enum declaration order is the sort order");
}

#[test]
fn act_options_and_fallback_defaults() {
    let o: ActOptions = serde_json::from_value(json!({})).unwrap();
    assert_eq!(o, ActOptions::default());
    assert_eq!(o.fallback, Fallback::None);
    assert!(!o.replace);
    let o: ActOptions = serde_json::from_value(json!({"value": "3", "text": "hi", "replace": true, "fallback": "pointer"})).unwrap();
    assert_eq!(o.fallback, Fallback::Pointer);
    assert_eq!(o.value.as_deref(), Some("3"));
    assert_eq!(serde_json::to_value(ActionMethod::KeyEvents).unwrap(), json!("key_events"));
    assert_eq!(serde_json::to_value(ActionMethod::Accessibility).unwrap(), json!("accessibility"));
}

#[test]
fn wait_condition_exists_defaults_to_true() {
    let w: WaitCondition = serde_json::from_value(json!({"target": {"ref": "e1"}})).unwrap();
    assert!(w.exists);
    assert_eq!(w.target, Target::Ref(ElementRef("e1".into())));
    let w: WaitCondition =
        serde_json::from_value(json!({"target": {"selector": {"id": "x"}}, "exists": false, "checked": true})).unwrap();
    assert!(!w.exists);
    assert_eq!(w.checked, Some(true));
}

#[test]
fn action_outcome_json_shape() {
    let o = ActionOutcome { action: ActionKind::Toggle, method: ActionMethod::Accessibility, steps: 1, target: leaf(9) };
    let v = serde_json::to_value(&o).unwrap();
    assert_eq!(v["action"], "toggle");
    assert_eq!(v["method"], "accessibility");
    assert_eq!(v["steps"], 1);
    assert_eq!(v["target"]["ref"], "e9");
}

// ---------------------------------------------------------------- roles

#[test]
fn role_name_covers_every_role_variant_exactly() {
    let table = [
        (R::None, "none"),
        (R::Button, "button"),
        (R::Checkbox, "checkbox"),
        (R::Combobox, "combobox"),
        (R::Groupbox, "groupbox"),
        (R::Image, "image"),
        (R::List, "list"),
        (R::Slider, "slider"),
        (R::Spinbox, "spinbox"),
        (R::Tab, "tab"),
        (R::TabList, "tab_list"),
        (R::TabPanel, "tab_panel"),
        (R::Text, "text"),
        (R::Table, "table"),
        (R::Tree, "tree"),
        (R::ProgressIndicator, "progress_indicator"),
        (R::TextInput, "text_input"),
        (R::Switch, "switch"),
        (R::ListItem, "list_item"),
        (R::RadioButton, "radio_button"),
        (R::RadioGroup, "radio_group"),
        (R::WindowTitleBar, "window_title_bar"),
        (R::Banner, "banner"),
        (R::Complementary, "complementary"),
        (R::ContentInfo, "content_info"),
        (R::Form, "form"),
        (R::Main, "main"),
        (R::Navigation, "navigation"),
        (R::Region, "region"),
        (R::Search, "search"),
    ];
    assert_eq!(table.len(), 30);
    let mut seen = std::collections::HashSet::new();
    for (role, name) in table {
        assert_eq!(role_name(role), name);
        assert!(seen.insert(name), "duplicate name {name}");
    }
}

// ---------------------------------------------------------------- derive_actions

#[test]
fn derive_actions_default_and_checkable() {
    assert_eq!(derive_actions("button", S::Default, false, false), vec![ActionKind::Activate]);
    assert_eq!(derive_actions("checkbox", S::Default, true, false), vec![ActionKind::Activate, ActionKind::Toggle]);
    assert_eq!(derive_actions("button", S::empty(), true, false), Vec::<ActionKind>::new(), "checkable alone gives nothing");
}

#[test]
fn derive_actions_inc_dec_expand_sorted() {
    let all = S::Default | S::Increment | S::Decrement | S::Expand;
    assert_eq!(
        derive_actions("list_item", all, false, false),
        vec![ActionKind::Activate, ActionKind::Increment, ActionKind::Decrement, ActionKind::Expand]
    );
    assert_eq!(derive_actions("x", S::Expand, false, false), vec![ActionKind::Expand]);
}

#[test]
fn derive_actions_set_value_and_type() {
    assert_eq!(
        derive_actions("text_input", S::SetValue, false, true),
        vec![ActionKind::SetValue, ActionKind::Focus, ActionKind::Type]
    );
    assert_eq!(derive_actions("custom", S::SetValue, false, false), vec![ActionKind::SetValue]);
    assert_eq!(derive_actions("text_input", S::empty(), false, false), Vec::<ActionKind>::new());
}

#[test]
fn derive_actions_focus_flag() {
    assert_eq!(derive_actions("group", S::empty(), false, true), vec![ActionKind::Focus]);
}

#[test]
fn derive_actions_slider_stepping_rule() {
    let both = S::Increment | S::Decrement;
    assert_eq!(
        derive_actions("slider", both, false, false),
        vec![ActionKind::SetValue, ActionKind::Increment, ActionKind::Decrement]
    );
    assert_eq!(
        derive_actions("spinbox", both, false, false),
        vec![ActionKind::SetValue, ActionKind::Increment, ActionKind::Decrement]
    );
    // only one direction: no stepped SetValue
    assert_eq!(derive_actions("slider", S::Increment, false, false), vec![ActionKind::Increment]);
    // other roles with both directions: no SetValue
    assert_eq!(derive_actions("button", both, false, false), vec![ActionKind::Increment, ActionKind::Decrement]);
    // native SetValue + both: deduplicated
    assert_eq!(
        derive_actions("slider", both | S::SetValue, false, false),
        vec![ActionKind::SetValue, ActionKind::Increment, ActionKind::Decrement]
    );
}

#[test]
fn derive_actions_is_sorted_and_deduplicated() {
    let all = S::Default | S::Increment | S::Decrement | S::Expand | S::SetValue;
    let out = derive_actions("slider", all, true, true);
    let mut sorted = out.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(out, sorted);
    assert_eq!(out.iter().filter(|a| **a == ActionKind::SetValue).count(), 1);
}

// ---------------------------------------------------------------- parsing

#[test]
fn parse_bool_accepts_only_true_false() {
    assert_eq!(parse_bool("true"), Some(true));
    assert_eq!(parse_bool("false"), Some(false));
    for bad in ["", "True", "TRUE", "1", "0", "yes", " true", "true "] {
        assert_eq!(parse_bool(bad), None, "{bad:?}");
    }
}

#[test]
fn parse_f32_parses_numbers_and_rejects_garbage() {
    assert_eq!(parse_f32("1"), Some(1.0));
    assert_eq!(parse_f32("-2.5"), Some(-2.5));
    assert_eq!(parse_f32(" 3.25 "), Some(3.25));
    assert_eq!(parse_f32("1e2"), Some(100.0));
    for bad in ["", "abc", "1,5", "NaN", "inf", "-inf", "1 2"] {
        assert_eq!(parse_f32(bad), None, "{bad:?}");
    }
}

// ---------------------------------------------------------------- errors

#[test]
fn agent_error_code_table_is_exact() {
    let c = |r: &str| r.to_string();
    let table: Vec<(AgentError, &str)> = vec![
        (AgentError::element_not_found("t", "r"), "element_not_found"),
        (AgentError::timeout("op", 5), "timeout"),
        (AgentError::window_unavailable("r"), "window_unavailable"),
        (AgentError::window_closed(), "window_closed"),
        (AgentError::event_loop_unavailable("r"), "event_loop_unavailable"),
        (AgentError::ui_channel_closed(), "ui_channel_closed"),
        (AgentError::ui_panic("r"), "ui_panic"),
        (AgentError::dispatch_failed("r"), "dispatch_failed"),
        (AgentError::render_error("r"), "render_error"),
        (AgentError::state_error("r"), "state_error"),
        (AgentError::invalid_operation("r"), "invalid_operation"),
        (AgentError::serialization("r"), "serialization_error"),
        (AgentError::protocol("r"), "protocol_error"),
        (AgentError::internal("r"), "internal"),
        (AgentError::StaleRef { reference: c("e1"), reason: c("r") }, "stale_ref"),
        (AgentError::AmbiguousTarget { count: 2, candidates: vec![] }, "ambiguous_target"),
        (AgentError::NotInteractable { reference: c("e1"), reason: c("disabled") }, "not_interactable"),
        (AgentError::UnsupportedAction { reference: c("e1"), action: c("toggle"), supported: vec![] }, "unsupported_action"),
        (AgentError::InvalidParams { path: c("/p"), message: c("m") }, "invalid_params"),
        (AgentError::ActionNotFound { name: c("n") }, "action_not_found"),
        (AgentError::ActionFailed { name: c("n"), reason: c("r") }, "action_failed"),
    ];
    assert_eq!(table.len(), 21);
    let mut codes = std::collections::HashSet::new();
    for (err, code) in &table {
        assert_eq!(err.code(), *code);
        assert!(codes.insert(*code));
        let j = err.to_error_json();
        assert_eq!(j["code"], *code);
        assert_eq!(j["message"], err.to_string());
        assert!(j.get("details").is_some(), "details key always present");
    }
}

#[test]
fn to_error_json_details_shapes() {
    let e = AgentError::InvalidParams { path: "/value".into(), message: "missing".into() };
    assert_eq!(
        e.to_error_json(),
        json!({"code": "invalid_params", "message": "Invalid params at '/value': missing", "details": {"path": "/value", "message": "missing"}})
    );
    let e = AgentError::AmbiguousTarget {
        count: 2,
        candidates: vec![Candidate { reference: "e1".into(), role: "button".into(), name: "A".into() }],
    };
    let j = e.to_error_json();
    assert_eq!(j["details"]["count"], 2);
    assert_eq!(j["details"]["candidates"][0], json!({"reference": "e1", "role": "button", "name": "A"}));
    let e = AgentError::UnsupportedAction { reference: "e1".into(), action: "toggle".into(), supported: vec!["activate".into()] };
    assert_eq!(e.to_error_json()["details"]["supported"], json!(["activate"]));
    assert_eq!(AgentError::window_closed().to_error_json()["details"], serde_json::Value::Null);
    assert_eq!(AgentError::timeout("x", 1).to_error_json()["details"], serde_json::Value::Null);
}

#[test]
fn new_error_messages_match_contract() {
    assert_eq!(
        AgentError::StaleRef { reference: "e1".into(), reason: "element was destroyed".into() }.to_string(),
        "Stale element ref 'e1': element was destroyed"
    );
    assert_eq!(AgentError::AmbiguousTarget { count: 3, candidates: vec![] }.to_string(), "Selector matched 3 elements");
    assert_eq!(
        AgentError::NotInteractable { reference: "e2".into(), reason: "disabled".into() }.to_string(),
        "Element 'e2' is not interactable: disabled"
    );
    assert_eq!(
        AgentError::UnsupportedAction { reference: "e2".into(), action: "toggle".into(), supported: vec!["activate".into()] }.to_string(),
        "Action 'toggle' unsupported on 'e2'; supported: [\"activate\"]"
    );
    assert_eq!(AgentError::ActionNotFound { name: "x".into() }.to_string(), "Action not found: x");
    assert_eq!(AgentError::ActionFailed { name: "x".into(), reason: "boom".into() }.to_string(), "Action 'x' failed: boom");
}

#[test]
fn new_errors_serde_roundtrip() {
    let e = AgentError::AmbiguousTarget {
        count: 1,
        candidates: vec![Candidate { reference: "e1".into(), role: "r".into(), name: "n".into() }],
    };
    let back: AgentError = serde_json::from_str(&serde_json::to_string(&e).unwrap()).unwrap();
    assert_eq!(back, e);
}
