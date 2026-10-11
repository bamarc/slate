//! Default implementation of the `AutomationEngine` facade composing all sub-systems.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use image::ImageEncoder;

use crate::error::AgentError;
use crate::model::{
    ActionResult, AppState, DiagnosticMetrics, MouseButton, Point, Rect, Screenshot,
    UiElementNode, UiTree,
};
use crate::traits::{
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
};

/// Default implementation of `AutomationEngine` that delegates to four sub-component instances.
pub struct DefaultAutomationEngine {
    inspector: Arc<dyn UiInspector>,
    controller: Arc<dyn ElementController>,
    state_provider: Arc<dyn StateProvider>,
    renderer: Arc<dyn VisualRenderer>,
}

impl DefaultAutomationEngine {
    /// Construct a new engine facade from four component handles.
    pub fn new(
        inspector: Arc<dyn UiInspector>,
        controller: Arc<dyn ElementController>,
        state_provider: Arc<dyn StateProvider>,
        renderer: Arc<dyn VisualRenderer>,
    ) -> Self {
        Self {
            inspector,
            controller,
            state_provider,
            renderer,
        }
    }

    /// Create an engine builder to configure individual components.
    pub fn builder() -> AutomationEngineBuilder {
        AutomationEngineBuilder::default()
    }
}

#[async_trait::async_trait]
impl AutomationEngine for DefaultAutomationEngine {
    fn inspector(&self) -> &dyn UiInspector {
        self.inspector.as_ref()
    }

    fn controller(&self) -> &dyn ElementController {
        self.controller.as_ref()
    }

    fn state(&self) -> &dyn StateProvider {
        self.state_provider.as_ref()
    }

    fn renderer(&self) -> &dyn VisualRenderer {
        self.renderer.as_ref()
    }
}

/// Fluent builder for constructing `DefaultAutomationEngine` instances.
#[derive(Default)]
pub struct AutomationEngineBuilder {
    inspector: Option<Arc<dyn UiInspector>>,
    controller: Option<Arc<dyn ElementController>>,
    state_provider: Option<Arc<dyn StateProvider>>,
    renderer: Option<Arc<dyn VisualRenderer>>,
}

impl AutomationEngineBuilder {
    pub fn inspector(mut self, inspector: Arc<dyn UiInspector>) -> Self {
        self.inspector = Some(inspector);
        self
    }

    pub fn controller(mut self, controller: Arc<dyn ElementController>) -> Self {
        self.controller = Some(controller);
        self
    }

    pub fn state_provider(mut self, state: Arc<dyn StateProvider>) -> Self {
        self.state_provider = Some(state);
        self
    }

    pub fn renderer(mut self, renderer: Arc<dyn VisualRenderer>) -> Self {
        self.renderer = Some(renderer);
        self
    }

    /// Build the `DefaultAutomationEngine`, returning an error if any required component is missing.
    pub fn build(self) -> Result<DefaultAutomationEngine, AgentError> {
        let inspector = self
            .inspector
            .ok_or_else(|| AgentError::internal("Missing inspector in AutomationEngineBuilder"))?;
        let controller = self
            .controller
            .ok_or_else(|| AgentError::internal("Missing controller in AutomationEngineBuilder"))?;
        let state_provider = self
            .state_provider
            .ok_or_else(|| AgentError::internal("Missing state_provider in AutomationEngineBuilder"))?;
        let renderer = self
            .renderer
            .ok_or_else(|| AgentError::internal("Missing renderer in AutomationEngineBuilder"))?;

        Ok(DefaultAutomationEngine::new(
            inspector,
            controller,
            state_provider,
            renderer,
        ))
    }
}

// ============================================================================
// Built-in Default Component Implementations
// ============================================================================

/// In-memory thread-safe state provider for application properties and diagnostics.
pub struct DefaultStateProvider {
    active_view: RwLock<String>,
    properties: RwLock<HashMap<String, serde_json::Value>>,
    diagnostics: RwLock<DiagnosticMetrics>,
}

impl DefaultStateProvider {
    pub fn new(initial_view: impl Into<String>) -> Self {
        Self {
            active_view: RwLock::new(initial_view.into()),
            properties: RwLock::new(HashMap::new()),
            diagnostics: RwLock::new(DiagnosticMetrics::default()),
        }
    }
}

impl Default for DefaultStateProvider {
    fn default() -> Self {
        Self::new("main")
    }
}

#[async_trait::async_trait]
impl StateProvider for DefaultStateProvider {
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        let view = self
            .active_view
            .read()
            .map_err(|e| AgentError::state_error(e.to_string()))?
            .clone();
        let props = self
            .properties
            .read()
            .map_err(|e| AgentError::state_error(e.to_string()))?;
        let diag = self
            .diagnostics
            .read()
            .map_err(|e| AgentError::state_error(e.to_string()))?
            .clone();

        let mut state = AppState::new(view).with_diagnostics(diag);

        if let Some(key) = query {
            if let Some(val) = props.get(key) {
                state = state.with_property(key, val.clone());
            }
        } else {
            for (k, v) in props.iter() {
                state = state.with_property(k, v.clone());
            }
        }

        Ok(state)
    }

    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError> {
        self.diagnostics
            .read()
            .map(|d| d.clone())
            .map_err(|e| AgentError::state_error(e.to_string()))
    }

    async fn set_property(&self, key: &str, value: serde_json::Value) -> Result<(), AgentError> {
        let mut props = self
            .properties
            .write()
            .map_err(|e| AgentError::state_error(e.to_string()))?;
        props.insert(key.to_string(), value);
        Ok(())
    }
}

/// Fallback visual renderer creating synthetic frame buffers or query viewport dimensions.
pub struct DefaultVisualRenderer {
    width: u32,
    height: u32,
}

impl DefaultVisualRenderer {
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }
}

impl Default for DefaultVisualRenderer {
    fn default() -> Self {
        Self::new(800, 600)
    }
}

#[async_trait::async_trait]
impl VisualRenderer for DefaultVisualRenderer {
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        // Minimal valid 1x1 or sized PNG frame
        let mut img_buf = Vec::new();
        let rgba_data = vec![255u8; (self.width * self.height * 4) as usize];
        image::codecs::png::PngEncoder::new(&mut img_buf)
            .write_image(
                &rgba_data,
                self.width,
                self.height,
                image::ExtendedColorType::Rgba8,
            )
            .map_err(|e| AgentError::render_error(e.to_string()))?;

        Ok(Screenshot::new(self.width, self.height, "png", img_buf))
    }

    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError> {
        Ok((self.width, self.height))
    }
}

/// In-memory UI tree inspector.
pub struct DefaultUiInspector {
    root_title: String,
    width: f32,
    height: f32,
}

impl DefaultUiInspector {
    pub fn new(root_title: impl Into<String>, width: f32, height: f32) -> Self {
        Self {
            root_title: root_title.into(),
            width,
            height,
        }
    }
}

impl Default for DefaultUiInspector {
    fn default() -> Self {
        Self::new("Slate Window", 800.0, 600.0)
    }
}

#[async_trait::async_trait]
impl UiInspector for DefaultUiInspector {
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        let root = UiElementNode {
            id: "root_window".to_string(),
            type_name: "Window".to_string(),
            bounds: Rect::new(0.0, 0.0, self.width, self.height),
            label: Some(self.root_title.clone()),
            role: "Window".to_string(),
            value: None,
            enabled: true,
            focused: true,
            visible: true,
            children: Vec::new(),
            properties: HashMap::new(),
        };

        Ok(UiTree::new(root).with_window_info(&self.root_title, self.width, self.height))
    }
}

/// Element controller returning action results.
#[derive(Default)]
pub struct DefaultElementController;

#[async_trait::async_trait]
impl ElementController for DefaultElementController {
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Clicked '{}'", target)).with_element_id(target))
    }

    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!(
            "Clicked at ({}, {}) with {:?}",
            point.x, point.y, button
        )))
    }

    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        let msg = match target {
            Some(t) => format!("Sent keys '{}' to '{}'", text, t),
            None => format!("Sent keys '{}' to active element", text),
        };
        let mut res = ActionResult::success(msg);
        if let Some(t) = target {
            res = res.with_element_id(t);
        }
        Ok(res)
    }

    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Set value '{}' on '{}'", value, target))
            .with_element_id(target)
            .with_value(serde_json::json!(value)))
    }

    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        Ok(ActionResult::success(format!("Toggled '{}'", target)).with_element_id(target))
    }
}
