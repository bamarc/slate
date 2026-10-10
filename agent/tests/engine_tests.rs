//! Unit tests for DefaultAutomationEngine facade, builder composition, and default components.

use std::collections::HashMap;
use std::sync::Arc;

use slate_agent::engine::{
    AutomationEngineBuilder, DefaultAutomationEngine, DefaultElementController,
    DefaultStateProvider, DefaultUiInspector, DefaultVisualRenderer,
};
use slate_agent::error::AgentError;
use slate_agent::model::{
    ActionResult, AppState, DiagnosticMetrics, MouseButton, Point, Rect, Screenshot,
    UiElementNode, UiTree,
};
use slate_agent::traits::{
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
};

struct DummyInspector;
#[async_trait::async_trait]
impl UiInspector for DummyInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        Ok(UiTree::new(UiElementNode {
            id: "root".into(),
            type_name: "Window".into(),
            bounds: Rect::ZERO,
            label: None,
            role: "Window".into(),
            value: None,
            enabled: true,
            focused: true,
            visible: true,
            children: vec![],
            properties: HashMap::new(),
        }))
    }
}

struct DummyController;
#[async_trait::async_trait]
impl ElementController for DummyController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Clicked {}", target)))
    }
    async fn click_at(&self, _p: Point, _b: MouseButton) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success("Clicked coordinate"))
    }
    async fn send_keys(&self, _t: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Typed {}", text)))
    }
    async fn set_value(&self, _t: &str, _v: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success("Set value"))
    }
    async fn toggle_element(&self, _t: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success("Toggled"))
    }
}

struct DummyState;
#[async_trait::async_trait]
impl StateProvider for DummyState {
    async fn get_state(&self, _q: Option<&str>) -> Result<AppState, AgentError> {
        Ok(AppState::new("MockView"))
    }
    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        Ok(DiagnosticMetrics::default())
    }
    async fn set_property(&self, _k: &str, _v: serde_json::Value) -> Result<(), AgentError> {
        Ok(())
    }
}

struct DummyRenderer;
#[async_trait::async_trait]
impl VisualRenderer for DummyRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        Ok(Screenshot::new(100, 100, "png", vec![1, 2, 3]))
    }
    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        Ok((100, 100))
    }
}

#[tokio::test]
async fn test_default_automation_engine_facade() {
    let engine = DefaultAutomationEngine::new(
        Arc::new(DummyInspector),
        Arc::new(DummyController),
        Arc::new(DummyState),
        Arc::new(DummyRenderer),
    );

    let tree = engine.inspect_tree().await.unwrap();
    assert_eq!(tree.root.id, "root");

    let action = engine.click_element("btn_test").await.unwrap();
    assert!(action.success);
    assert_eq!(action.message, "Clicked btn_test");

    let typed = engine.send_keys(None, "Hello Slate").await.unwrap();
    assert!(typed.success);
    assert_eq!(typed.message, "Typed Hello Slate");

    let state = engine.get_state(None).await.unwrap();
    assert_eq!(state.active_view, "MockView");

    let shot = engine.get_screenshot().await.unwrap();
    assert_eq!(shot.width, 100);
    assert_eq!(shot.data, vec![1, 2, 3]);
}

#[tokio::test]
async fn test_automation_engine_builder() {
    // Missing components produce error
    let incomplete = AutomationEngineBuilder::default()
        .inspector(Arc::new(DummyInspector))
        .build();
    assert!(incomplete.is_err());

    // Complete builder succeeds
    let engine = AutomationEngineBuilder::default()
        .inspector(Arc::new(DummyInspector))
        .controller(Arc::new(DummyController))
        .state_provider(Arc::new(DummyState))
        .renderer(Arc::new(DummyRenderer))
        .build()
        .unwrap();

    let state = engine.get_state(None).await.unwrap();
    assert_eq!(state.active_view, "MockView");
}

#[tokio::test]
async fn test_default_subcomponents() {
    // 1. DefaultStateProvider
    let state_provider = DefaultStateProvider::new("InitialView");
    let state = state_provider.get_state(None).await.unwrap();
    assert_eq!(state.active_view, "InitialView");

    state_provider
        .set_property("count", serde_json::json!(10))
        .await
        .unwrap();
    let state2 = state_provider.get_state(Some("count")).await.unwrap();
    assert_eq!(state2.get_property("count"), Some(&serde_json::json!(10)));

    let diag = state_provider.get_diagnostics().await.unwrap();
    assert!(diag.fps.is_none());

    // 2. DefaultVisualRenderer
    let renderer = DefaultVisualRenderer::new(200, 150);
    let size = renderer.get_viewport_size().await.unwrap();
    assert_eq!(size, (200, 150));
    let shot = renderer.get_screenshot().await.unwrap();
    assert_eq!(shot.width, 200);
    assert_eq!(shot.height, 150);
    assert!(!shot.data.is_empty());

    // 3. DefaultUiInspector
    let inspector = DefaultUiInspector::new("Test Window", 1024.0, 768.0);
    let tree = inspector.inspect_tree().await.unwrap();
    assert_eq!(tree.root.id, "root_window");
    assert_eq!(tree.window_title.as_deref(), Some("Test Window"));

    // 4. DefaultElementController
    let controller = DefaultElementController;
    let click = controller.click_element("btn").await.unwrap();
    assert!(click.success);
    let keys = controller.send_keys(Some("inp"), "hello").await.unwrap();
    assert!(keys.success);
    let set_val = controller.set_value("inp", "world").await.unwrap();
    assert!(set_val.success);
    assert_eq!(set_val.updated_value, Some(serde_json::json!("world")));
    let toggled = controller.toggle_element("switch").await.unwrap();
    assert!(toggled.success);
}
