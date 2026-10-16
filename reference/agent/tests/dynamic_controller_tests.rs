//! Dynamic Controller Unit Tests covering Scenario T3 (Requirement W1)
//! and full McpAction execution contracts.

use std::sync::Arc;
use slate_agent::bridge::SlintUiBridge;
use slate_agent::error::AgentError;
use slate_agent::interactable::{
    ClickAction, DismissAction, DynamicInteractableElement, ExpandAction, Interactable,
    SelectOptionAction, SelectRowAction, SendKeysAction, SetValueAction, StepAction, ToggleAction,
};
use slate_agent::model::{Rect, UiElementNode};
use slate_agent::slint_engine::SlintDynamicController;
use slate_agent::traits::ElementController;

slint::slint! {
    import {
        SlateButton,
        SlateInput,
        SlateSwitch,
        SlateSlider,
        SlateSegmentedControl,
        SlateTable,
        SlateTableRow,
        SlateAccordion,
        SlateAlert
    } from "../../ui/index.slint";

    export component TestControllerWindow inherits Window {
        width: 800px;
        height: 700px;

        in-out property <int> clicks: 0;
        in-out property <string> text_val: "initial";
        in-out property <bool> switch_val: false;
        in-out property <float> slider_val: 50.0;
        in-out property <int> selected_tab: 0;
        in-out property <int> table_clicked_row: -1;
        in-out property <bool> accordion_open: false;
        in-out property <bool> alert_dismissed: false;

        VerticalLayout {
            padding: 20px;
            spacing: 10px;

            btn := SlateButton {
                id: "target_btn";
                text: "Click Target";
                clicked => { root.clicks += 1; }
            }

            inp := SlateInput {
                id: "target_input";
                text <=> root.text_val;
            }

            sw := SlateSwitch {
                id: "target_switch";
                checked <=> root.switch_val;
            }

            sl := SlateSlider {
                id: "target_slider";
                value <=> root.slider_val;
                minimum: 0.0;
                maximum: 100.0;
            }

            seg := SlateSegmentedControl {
                id: "target_segmented";
                options: ["First", "Second", "Third"];
                selected-index <=> root.selected_tab;
            }

            tbl := SlateTable {
                id: "target_table";
                columns: ["Col A", "Col B"];
                rows: [
                    { id: "row_1", name: "Row One", category: "Cat1", status: "Active", status-variant: "success", value: "100" },
                    { id: "row_2", name: "Row Two", category: "Cat2", status: "Pending", status-variant: "warning", value: "200" }
                ];
                row-clicked(idx, row) => {
                    root.table_clicked_row = idx;
                }
            }

            acc := SlateAccordion {
                id: "target_accordion";
                title: "Collapsible Details";
                expanded <=> root.accordion_open;
            }

            alt := SlateAlert {
                id: "target_alert";
                title: "Alert Message";
                dismissible: true;
                dismissed => { root.alert_dismissed = true; }
            }
        }
    }
}

fn setup_headless() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_integration_test_with_system_time();
    });
}

#[tokio::test]
async fn test_dynamic_controller_scenario_t3_element_not_found() {
    let (tx_ready, rx_ready) = std::sync::mpsc::channel();
    let ui_thread = std::thread::spawn(move || {
        setup_headless();
        let window = TestControllerWindow::new().expect("window create");
        window.show().expect("window show");
        let bridge = Arc::new(SlintUiBridge::new());
        let controller = Arc::new(SlintDynamicController::new(window.as_weak(), bridge.clone()));
        tx_ready.send((window.as_weak(), bridge, controller)).unwrap();
        let _ = slint::run_event_loop();
        drop(window);
    });

    let (weak, bridge, controller) = rx_ready.recv().expect("recv setup");

    // ========================================================================
    // SCENARIO T3 / Requirement W1: Element Not Found Handling
    // ========================================================================
    let err = controller
        .click_element("completely_absent_widget_xyz")
        .await
        .expect_err("Must return error for absent element");

    match err {
        AgentError::ElementNotFound { target, reason } => {
            assert_eq!(target, "completely_absent_widget_xyz");
            assert!(
                reason.contains("not present") || reason.contains("not found"),
                "Expected descriptive reason, got: {}",
                reason
            );
        }
        other => panic!("Expected AgentError::ElementNotFound, got {:?}", other),
    }

    // Also verify perform_action returns ElementNotFound for nonexistent targets
    let action_err = controller
        .perform_action("missing_btn", &ClickAction)
        .await
        .expect_err("Must return error");
    match action_err {
        AgentError::ElementNotFound { target, .. } => assert_eq!(target, "missing_btn"),
        other => panic!("Expected ElementNotFound, got {:?}", other),
    }

    // ========================================================================
    // SCENARIO: Action Execution Matrix on Live Components
    // ========================================================================

    // 1. ClickAction
    let click_res = controller
        .perform_action("target_btn", &ClickAction)
        .await
        .expect("click failed");
    assert!(click_res.success);

    // 2. SetValueAction
    let set_res = controller
        .perform_action("target_input", &SetValueAction::new("updated text"))
        .await
        .expect("set_value failed");
    assert!(set_res.success);

    // 3. SendKeysAction with clear_before
    let send_res = controller
        .perform_action(
            "target_input",
            &SendKeysAction::new("replaced").with_clear(true),
        )
        .await
        .expect("send_keys failed");
    assert!(send_res.success);

    // 4. ToggleAction with explicit state idempotence
    let toggle_on = controller
        .perform_action("target_switch", &ToggleAction::new().with_state(true))
        .await
        .expect("toggle on failed");
    assert!(toggle_on.success);

    // Calling again with state(true) should succeed without toggling off
    let toggle_noop = controller
        .perform_action("target_switch", &ToggleAction::new().with_state(true))
        .await
        .expect("toggle idempotence failed");
    assert!(toggle_noop.success);

    // 5. SelectOptionAction (by index)
    let opt_res = controller
        .perform_action("target_segmented", &SelectOptionAction::by_index(1))
        .await
        .expect("select_option by index failed");
    assert!(opt_res.success);

    // 6. SelectRowAction (by row_id)
    let row_res = controller
        .perform_action("target_table", &SelectRowAction::new(0).with_row_id("row_2"))
        .await
        .expect("select_row failed");
    assert!(row_res.success);

    // 7. ExpandAction with idempotency
    let expand_res = controller
        .perform_action("target_accordion", &ExpandAction::new(true))
        .await
        .expect("expand failed");
    assert!(expand_res.success);

    let expand_noop = controller
        .perform_action("target_accordion", &ExpandAction::new(true))
        .await
        .expect("expand idempotency failed");
    assert!(expand_noop.success);

    // 8. StepAction (increment slider)
    let step_res = controller
        .perform_action("target_slider", &StepAction::new(1.0))
        .await
        .expect("step failed");
    assert!(step_res.success);

    // 9. DismissAction (on dismissible alert)
    let dismiss_res = controller
        .perform_action("target_alert_dismiss", &DismissAction)
        .await
        .expect("dismiss failed");
    assert!(dismiss_res.success);

    // ========================================================================
    // SCENARIO: DynamicInteractableElement Integration
    // ========================================================================
    let dummy_node = UiElementNode {
        id: "target_btn".to_string(),
        type_name: "SlateButton".to_string(),
        bounds: Rect::new(0.0, 0.0, 100.0, 40.0),
        label: Some("Click Target".to_string()),
        role: "button".to_string(),
        value: None,
        enabled: true,
        focused: false,
        visible: true,
        children: vec![],
        properties: std::collections::HashMap::new(),
    };

    let interactable = DynamicInteractableElement::new(dummy_node, controller.clone());
    assert_eq!(interactable.id(), "target_btn");
    assert_eq!(interactable.role(), "button");
    assert_eq!(interactable.supported_actions(), &["click"]);
    assert!(interactable.is_enabled());
    assert!(interactable.is_visible());

    let dyn_click = interactable.perform_action(&ClickAction).await.unwrap();
    assert!(dyn_click.success);

    // Verify window state on UI thread
    let (clicks, val, sw_val, sl_val, tab_idx, tbl_idx, acc_open, alt_dismissed) = bridge
        .run_on_ui(move || {
            let win = weak.upgrade().ok_or(AgentError::WindowClosed)?;
            Ok((
                win.get_clicks(),
                win.get_text_val().to_string(),
                win.get_switch_val(),
                win.get_slider_val(),
                win.get_selected_tab(),
                win.get_table_clicked_row(),
                win.get_accordion_open(),
                win.get_alert_dismissed(),
            ))
        })
        .await
        .unwrap();

    // target_btn was clicked twice: once via perform_action, once via DynamicInteractableElement
    assert_eq!(clicks, 2, "Clicks count must be 2");
    assert_eq!(val, "replaced", "Text value must be 'replaced'");
    assert!(sw_val, "Switch state must be true");
    assert!((sl_val - 60.0).abs() < 0.001, "Slider stepped by 10% to 60.0");
    assert_eq!(tab_idx, 1, "Tab index must be 1 (Second option)");
    assert_eq!(tbl_idx, 1, "Table row index must be 1 (row_2)");
    assert_eq!(acc_open, true, "Accordion must be open");
    assert!(alt_dismissed, "Alert must be dismissed");

    // Cleanup
    let _ = slint::quit_event_loop();
    let _ = ui_thread.join();
}
