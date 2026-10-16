//! Unit tests for data models, geometry, selectors, UI tree hit-testing, screenshots, and error types.

use std::collections::HashMap;
use slate_agent::error::AgentError;
use slate_agent::model::{
    ActionResult, AppState, DiagnosticMetrics, ElementSelector, MouseButton, Point, Rect,
    Screenshot, UiElementNode, UiTree,
};

#[test]
fn test_point_and_rect_geometry() {
    let p1 = Point::new(10.0, 20.0);
    let p2 = Point::new(40.0, 60.0);
    assert_eq!(p1.distance_to(&p2), 50.0);
    assert_eq!(p1.to_string(), "(10, 20)");

    let p_tuple: Point = (15.0, 25.0).into();
    assert_eq!(p_tuple, Point::new(15.0, 25.0));

    let rect = Rect::new(10.0, 10.0, 100.0, 50.0);
    assert_eq!(rect.origin(), Point::new(10.0, 10.0));
    assert_eq!(rect.center(), Point::new(60.0, 35.0));
    assert_eq!(rect.area(), 5000.0);

    // Containment checks (interior, boundaries, exterior)
    assert!(rect.contains(&Point::new(15.0, 20.0)));
    assert!(rect.contains(&Point::new(10.0, 10.0))); // top-left boundary
    assert!(rect.contains(&Point::new(110.0, 60.0))); // bottom-right boundary
    assert!(!rect.contains(&Point::new(5.0, 20.0)));
    assert!(!rect.contains(&Point::new(50.0, 65.0)));

    // Intersections
    let intersecting = Rect::new(50.0, 30.0, 80.0, 80.0);
    let disjoint = Rect::new(200.0, 200.0, 50.0, 50.0);
    assert!(rect.intersects(&intersecting));
    assert!(!rect.intersects(&disjoint));
}

#[test]
fn test_element_selector_parsing() {
    // Coordinate parsing
    assert_eq!(
        ElementSelector::parse("150, 250"),
        ElementSelector::Coordinate(Point::new(150.0, 250.0))
    );
    assert_eq!(
        ElementSelector::parse(" 10.5 , 20.5 "),
        ElementSelector::Coordinate(Point::new(10.5, 20.5))
    );

    // ID parsing with # and id:
    assert_eq!(
        ElementSelector::parse("#submit-btn"),
        ElementSelector::Id("submit-btn".into())
    );
    assert_eq!(
        ElementSelector::parse("id:submit-btn"),
        ElementSelector::Id("submit-btn".into())
    );

    // Label parsing with text: and label:
    assert_eq!(
        ElementSelector::parse("text:Start Compute"),
        ElementSelector::Label("Start Compute".into())
    );
    assert_eq!(
        ElementSelector::parse("label:Preferences"),
        ElementSelector::Label("Preferences".into())
    );

    // Role parsing
    assert_eq!(
        ElementSelector::parse("role:Button"),
        ElementSelector::Role("Button".into())
    );

    // Default fallback
    assert_eq!(
        ElementSelector::parse("my_custom_id"),
        ElementSelector::Id("my_custom_id".into())
    );
}

#[test]
fn test_ui_tree_search_and_deep_hit_test() {
    let button = UiElementNode {
        id: "btn_start".into(),
        type_name: "SlateButton".into(),
        bounds: Rect::new(50.0, 50.0, 100.0, 40.0),
        label: Some("Start Compute".into()),
        role: "Button".into(),
        value: None,
        enabled: true,
        focused: false,
        visible: true,
        children: vec![],
        properties: HashMap::new(),
    };

    let text_input = UiElementNode {
        id: "input_samples".into(),
        type_name: "TextInput".into(),
        bounds: Rect::new(50.0, 100.0, 100.0, 30.0),
        label: Some("Sample Count".into()),
        role: "TextInput".into(),
        value: Some("1000".into()),
        enabled: true,
        focused: false,
        visible: true,
        children: vec![],
        properties: HashMap::new(),
    };

    let card = UiElementNode {
        id: "compute_card".into(),
        type_name: "SlateCard".into(),
        bounds: Rect::new(20.0, 20.0, 200.0, 150.0),
        label: Some("Compute Panel".into()),
        role: "Container".into(),
        value: None,
        enabled: true,
        focused: false,
        visible: true,
        children: vec![button, text_input],
        properties: HashMap::new(),
    };

    let window = UiElementNode {
        id: "main_window".into(),
        type_name: "Window".into(),
        bounds: Rect::new(0.0, 0.0, 800.0, 600.0),
        label: Some("Slate Showcase".into()),
        role: "Window".into(),
        value: None,
        enabled: true,
        focused: true,
        visible: true,
        children: vec![card],
        properties: HashMap::new(),
    };

    let tree = UiTree::new(window).with_window_info("Slate Showcase", 800.0, 600.0);
    assert_eq!(tree.count_elements(), 4);
    assert_eq!(tree.window_title.as_deref(), Some("Slate Showcase"));
    assert_eq!(tree.window_size, Some(Point::new(800.0, 600.0)));

    // Find by ID
    assert!(tree.find_by_id("btn_start").is_some());
    assert_eq!(
        tree.find_by_id("btn_start").unwrap().type_name,
        "SlateButton"
    );
    assert!(tree.find_by_id("input_samples").is_some());
    assert_eq!(
        tree.find_by_id("input_samples").unwrap().value.as_deref(),
        Some("1000")
    );
    assert!(tree.find_by_id("missing").is_none());

    // Find by label
    assert!(tree.find_by_label("Start Compute").is_some());
    assert!(tree.find_by_label("Missing Label").is_none());

    // Selector queries
    assert!(tree.find_by_selector("#btn_start").is_some());
    assert!(tree.find_by_selector("text:Start Compute").is_some());
    assert!(tree.find_by_selector("role:TextInput").is_some());

    // Deep Hit-test: point inside button should return button, NOT parent card or window!
    let inside_button = Point::new(70.0, 60.0);
    let hit = tree.find_at_point(&inside_button);
    assert!(hit.is_some());
    assert_eq!(hit.unwrap().id, "btn_start");

    // Hit-test: point inside card but outside button and input should return card
    let inside_card_only = Point::new(25.0, 25.0);
    let hit_card = tree.find_at_point(&inside_card_only);
    assert!(hit_card.is_some());
    assert_eq!(hit_card.unwrap().id, "compute_card");

    // Hit-test: point outside card should return root window
    let outside_card = Point::new(500.0, 500.0);
    let hit_window = tree.find_at_point(&outside_card);
    assert!(hit_window.is_some());
    assert_eq!(hit_window.unwrap().id, "main_window");

    // Point outside window bounds
    let outside_all = Point::new(900.0, 900.0);
    assert!(tree.find_at_point(&outside_all).is_none());
}

#[test]
fn test_screenshot_base64_and_json() {
    let fake_png_bytes = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]; // PNG signature
    let screenshot = Screenshot::new(800, 600, "png", fake_png_bytes.clone());

    assert_eq!(screenshot.width, 800);
    assert_eq!(screenshot.height, 600);
    assert_eq!(screenshot.byte_len(), 8);

    let b64 = screenshot.to_base64();
    assert!(!b64.is_empty());
    assert_eq!(screenshot.to_base64_png(), b64);
    assert_eq!(
        screenshot.data_url(),
        format!("data:image/png;base64,{}", b64)
    );

    // Serialization round-trip
    let json = serde_json::to_string(&screenshot).unwrap();
    let deserialized: Screenshot = serde_json::from_str(&json).unwrap();
    assert_eq!(deserialized.width, 800);
    assert_eq!(deserialized.height, 600);
    assert_eq!(deserialized.data, fake_png_bytes);
}

#[test]
fn test_app_state_and_diagnostics() {
    let diag = DiagnosticMetrics {
        fps: Some(59.9),
        memory_bytes: Some(1024 * 1024 * 45), // 45MB
        event_loop_lag_ms: Some(0.42),
        active_background_tasks: Some(2),
        ..Default::default()
    };

    let app_state = AppState::new("Showcase::Compute")
        .with_property("counter", serde_json::json!(42))
        .with_property("is_running", serde_json::json!(true))
        .with_diagnostics(diag);

    assert_eq!(app_state.active_view, "Showcase::Compute");
    assert_eq!(
        app_state.get_property("counter"),
        Some(&serde_json::json!(42))
    );
    assert_eq!(
        app_state.get_property("is_running"),
        Some(&serde_json::json!(true))
    );
    assert!(app_state.get_property("missing").is_none());

    let json = serde_json::to_string_pretty(&app_state).unwrap();
    let parsed: AppState = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed.active_view, "Showcase::Compute");
    assert_eq!(parsed.get_property("counter"), Some(&serde_json::json!(42)));
    assert_eq!(parsed.diagnostics.as_ref().unwrap().fps, Some(59.9));
    assert_eq!(
        parsed
            .diagnostics
            .as_ref()
            .unwrap()
            .active_background_tasks,
        Some(2)
    );
}

#[test]
fn test_action_result_constructors() {
    let success = ActionResult::success("Clicked button")
        .with_element_id("btn_start")
        .with_value(serde_json::json!("running"))
        .with_detail("latency_ms", serde_json::json!(12));

    assert!(success.success);
    assert!(success.target_found);
    assert_eq!(success.element_id.as_deref(), Some("btn_start"));
    assert_eq!(
        success.updated_value,
        Some(serde_json::json!("running"))
    );
    assert_eq!(
        success.details.get("latency_ms"),
        Some(&serde_json::json!(12))
    );

    let failure = ActionResult::failure("Button disabled");
    assert!(!failure.success);
    assert!(failure.target_found);

    let not_found = ActionResult::not_found("btn_missing");
    assert!(!not_found.success);
    assert!(!not_found.target_found);
    assert!(not_found.message.contains("not found"));
}

#[test]
fn test_mouse_button_default() {
    assert_eq!(MouseButton::default(), MouseButton::Left);
}

#[test]
fn test_agent_error_variants_and_serialization() {
    let err = AgentError::element_not_found("btn_submit", "Not visible on screen");
    assert_eq!(
        err.to_string(),
        "Element not found: target 'btn_submit', reason: Not visible on screen"
    );

    let timeout = AgentError::timeout("click_element", 5000);
    assert_eq!(
        timeout.to_string(),
        "Operation timed out: Operation 'click_element' timed out after 5000ms"
    );

    let window_closed = AgentError::window_closed();
    assert_eq!(
        window_closed.to_string(),
        "Window or component has been closed / destroyed"
    );

    let event_loop = AgentError::event_loop_unavailable("event loop stopped");
    assert_eq!(
        event_loop.to_string(),
        "Slint event loop is unavailable: event loop stopped"
    );

    let panic_err = AgentError::ui_panic("unexpected panic");
    assert_eq!(
        panic_err.to_string(),
        "UI thread panic intercepted: unexpected panic"
    );

    let json = serde_json::to_string(&err).unwrap();
    let deserialized: AgentError = serde_json::from_str(&json).unwrap();
    assert_eq!(deserialized, err);
}
