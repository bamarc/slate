use slate_agent::interactable::{
    ClickAction, DismissAction, ExpandAction, Interactable, McpAction, SelectOptionAction,
    SelectRowAction, SendKeysAction, SetValueAction, StepAction, ToggleAction,
};
use slate_agent::model::{ActionResult, Rect, UiElementNode};
use slate_agent::error::AgentError;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

struct MockInteractable {
    id: String,
    role: String,
    label: Option<String>,
    clicked: Arc<AtomicBool>,
    last_value: Arc<Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl Interactable for MockInteractable {
    fn id(&self) -> &str {
        &self.id
    }
    fn role(&self) -> &str {
        &self.role
    }
    fn label(&self) -> Option<&str> {
        self.label.as_deref()
    }
    fn value(&self) -> Option<serde_json::Value> {
        self.last_value.lock().unwrap().as_ref().map(|s| serde_json::json!(s))
    }
    fn bounds(&self) -> Rect {
        Rect::new(10.0, 20.0, 100.0, 40.0)
    }
    fn is_enabled(&self) -> bool {
        true
    }
    fn is_visible(&self) -> bool {
        true
    }
    fn supported_actions(&self) -> &[&'static str] {
        &["click", "set_value", "toggle"]
    }
    async fn perform_action(&self, action: &dyn McpAction) -> Result<ActionResult, AgentError> {
        match action.action_name() {
            "click" => {
                self.clicked.store(true, Ordering::SeqCst);
                Ok(ActionResult::success("clicked").with_element_id(&self.id))
            }
            "set_value" => {
                if let Some(act) = action.as_any().downcast_ref::<SetValueAction>() {
                    *self.last_value.lock().unwrap() = Some(act.value.clone());
                    Ok(ActionResult::success("value set").with_element_id(&self.id))
                } else {
                    Err(AgentError::invalid_operation("Invalid action downcast"))
                }
            }
            "toggle" => {
                let current = self.clicked.load(Ordering::SeqCst);
                self.clicked.store(!current, Ordering::SeqCst);
                Ok(ActionResult::success("toggled").with_element_id(&self.id))
            }
            other => Err(AgentError::invalid_operation(format!("Unsupported action: {}", other))),
        }
    }
    fn to_ui_element_node(&self) -> UiElementNode {
        UiElementNode {
            id: self.id.clone(),
            type_name: self.role.clone(),
            bounds: self.bounds(),
            label: self.label.clone(),
            role: self.role.clone(),
            value: self.value().map(|v| {
                if let Some(s) = v.as_str() {
                    s.to_string()
                } else {
                    v.to_string()
                }
            }),
            enabled: self.is_enabled(),
            focused: false,
            visible: self.is_visible(),
            children: vec![],
            properties: std::collections::HashMap::new(),
        }
    }
}

#[tokio::test]
async fn test_mcp_actions_payload_and_metadata() {
    let click = ClickAction;
    assert_eq!(click.action_name(), "click");
    assert_eq!(click.payload(), serde_json::json!({}));

    let set_val = SetValueAction::new("hello world");
    assert_eq!(set_val.action_name(), "set_value");
    assert_eq!(set_val.value, "hello world");
    assert_eq!(set_val.payload(), serde_json::json!({ "value": "hello world" }));

    let send_keys = SendKeysAction::new("type text").with_clear(true);
    assert_eq!(send_keys.action_name(), "send_keys");
    assert_eq!(send_keys.text, "type text");
    assert!(send_keys.clear_before);

    let toggle = ToggleAction::new().with_state(true);
    assert_eq!(toggle.action_name(), "toggle");
    assert_eq!(toggle.state, Some(true));

    let step = StepAction::new(1.5);
    assert_eq!(step.action_name(), "step");
    assert_eq!(step.delta, 1.5);

    let sel_opt = SelectOptionAction::by_index(2);
    assert_eq!(sel_opt.action_name(), "select_option");
    assert_eq!(sel_opt.index, Some(2));

    let sel_row = SelectRowAction::new(4).with_row_id("row_4");
    assert_eq!(sel_row.action_name(), "select_row");
    assert_eq!(sel_row.row_index, 4);
    assert_eq!(sel_row.row_id.as_deref(), Some("row_4"));

    let expand = ExpandAction::new(true);
    assert_eq!(expand.action_name(), "expand");
    assert_eq!(expand.expanded, Some(true));

    let dismiss = DismissAction;
    assert_eq!(dismiss.action_name(), "dismiss");
}

#[tokio::test]
async fn test_interactable_dispatch() {
    let clicked = Arc::new(AtomicBool::new(false));
    let last_val = Arc::new(Mutex::new(None));
    let mock = MockInteractable {
        id: "mock_btn".into(),
        role: "button".into(),
        label: Some("Mock Button".into()),
        clicked: clicked.clone(),
        last_value: last_val.clone(),
    };

    assert_eq!(mock.id(), "mock_btn");
    assert_eq!(mock.role(), "button");
    assert_eq!(mock.label(), Some("Mock Button"));
    assert_eq!(mock.bounds(), Rect::new(10.0, 20.0, 100.0, 40.0));

    let res = mock.perform_action(&ClickAction).await.unwrap();
    assert!(res.success);
    assert!(clicked.load(Ordering::SeqCst));

    let res2 = mock.perform_action(&SetValueAction::new("slate rocks")).await.unwrap();
    assert!(res2.success);
    assert_eq!(last_val.lock().unwrap().as_deref(), Some("slate rocks"));

    let node = mock.to_ui_element_node();
    assert_eq!(node.id, "mock_btn");
    assert_eq!(node.value, Some("slate rocks".to_string()));
}
