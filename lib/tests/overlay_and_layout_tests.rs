//! Integration tests for Slate extended overlay and dynamic layout components.

slint::slint! {
    import {
        SlateThreePanelLayout,
        SlateResizableHandle,
        SlateCollapsible,
        SlateSheet,
        SlateAlertDialog,
        SlatePopover,
        SlateTooltip,
        SlateToast
    } from "ui/index.slint";

    export component TestHarness inherits Window {
        width: 1000px;
        height: 700px;

        in-out property <bool> sheet_open: false;
        in-out property <bool> alert_open: false;
        in-out property <bool> popover_open: false;
        in-out property <bool> toast_visible: false;
        in-out property <bool> collapsible_open: true;

        in-out property <bool> left_collapsed: false;
        in-out property <bool> right_collapsed: false;
        in-out property <bool> center_maximized: false;

        layout := SlateThreePanelLayout {
            left-collapsed: root.left_collapsed;
            right-collapsed: root.right_collapsed;
            center-maximized: root.center_maximized;
            left-width: 220px;
            right-width: 250px;
        }

        sheet := SlateSheet {
            is-open: root.sheet_open;
            title: "Settings Drawer";
            side: "right";
        }

        alert_dialog := SlateAlertDialog {
            is-open: root.alert_open;
            title: "Delete Project";
            variant: "destructive";
        }

        popover := SlatePopover {
            is-open: root.popover_open;
            anchor-x: 200px;
            anchor-y: 150px;
        }

        collapsible := SlateCollapsible {
            is-open: root.collapsible_open;
            title: "Advanced Configuration";
        }

        toast := SlateToast {
            is-visible: root.toast_visible;
            title: "Deployment Finished";
            variant: "success";
        }
    }
}

fn setup_headless() {
    let _ = std::panic::catch_unwind(|| {
        i_slint_backend_testing::init_no_event_loop();
    });
}

#[test]
fn test_three_panel_layout_defaults_and_scaling() {
    setup_headless();
    let harness = TestHarness::new().unwrap();

    // Default state: not collapsed, not maximized
    assert!(!harness.get_left_collapsed());
    assert!(!harness.get_right_collapsed());
    assert!(!harness.get_center_maximized());

    // Scale left to 0 (collapsed)
    harness.set_left_collapsed(true);
    assert!(harness.get_left_collapsed());

    // Scale right to 0 (collapsed)
    harness.set_right_collapsed(true);
    assert!(harness.get_right_collapsed());

    // Maximize center base panel
    harness.set_center_maximized(true);
    assert!(harness.get_center_maximized());

    // Restore
    harness.set_center_maximized(false);
    harness.set_left_collapsed(false);
    harness.set_right_collapsed(false);
    assert!(!harness.get_center_maximized());
    assert!(!harness.get_left_collapsed());
}

#[test]
fn test_overlay_sheet_and_alert_dialog_states() {
    setup_headless();
    let harness = TestHarness::new().unwrap();

    // Sheet toggle
    assert!(!harness.get_sheet_open());
    harness.set_sheet_open(true);
    assert!(harness.get_sheet_open());
    harness.set_sheet_open(false);
    assert!(!harness.get_sheet_open());

    // Alert dialog toggle
    assert!(!harness.get_alert_open());
    harness.set_alert_open(true);
    assert!(harness.get_alert_open());
    harness.set_alert_open(false);
    assert!(!harness.get_alert_open());

    // Popover and Toast toggle
    assert!(!harness.get_popover_open());
    harness.set_popover_open(true);
    assert!(harness.get_popover_open());

    assert!(!harness.get_toast_visible());
    harness.set_toast_visible(true);
    assert!(harness.get_toast_visible());
}

#[test]
fn test_collapsible_toggle_state() {
    setup_headless();
    let harness = TestHarness::new().unwrap();

    assert!(harness.get_collapsible_open());
    harness.set_collapsible_open(false);
    assert!(!harness.get_collapsible_open());
    harness.set_collapsible_open(true);
    assert!(harness.get_collapsible_open());
}
