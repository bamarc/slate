//! Protocol-agnostic core traits for UI inspection, interaction, rendering, and state querying.

use crate::error::AgentError;
use crate::model::{
    ActionResult, AppState, DiagnosticMetrics, MouseButton, Point, Rect, Screenshot,
    UiElementNode, UiTree,
};

/// Trait for inspecting the Slint component tree and element geometry.
#[async_trait::async_trait]
pub trait UiInspector: Send + Sync {
    /// Inspect and return the complete hierarchical UI tree of the window.
    async fn inspect_tree(&self) -> Result<UiTree, AgentError>;

    /// Find an element by selector (ID, label, role, or coordinate).
    async fn find_element(&self, target: &str) -> Result<UiElementNode, AgentError> {
        let tree = self.inspect_tree().await?;
        tree.find_by_selector(target)
            .cloned()
            .ok_or_else(|| AgentError::element_not_found(target, "Element not present in UI tree"))
    }

    /// Query the bounding rectangle of a specific element.
    async fn get_element_bounds(&self, target: &str) -> Result<Rect, AgentError> {
        let elem = self.find_element(target).await?;
        Ok(elem.bounds)
    }
}

/// Trait for dispatching user interaction events to UI elements.
#[async_trait::async_trait]
pub trait ElementController: Send + Sync {
    /// Dispatch a click event to an element by selector (ID, label, or "x,y" coordinates).
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError>;

    /// Dispatch a click event at specific coordinates with a specific button.
    async fn click_at(&self, point: Point, button: MouseButton) -> Result<ActionResult, AgentError>;

    /// Send text input to the currently focused element or targeted element.
    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError>;

    /// Set the value of an interactive element (e.g. text field, slider).
    async fn set_value(&self, target: &str, value: &str) -> Result<ActionResult, AgentError>;

    /// Toggle a boolean control (e.g. switch or checkbox).
    async fn toggle_element(&self, target: &str) -> Result<ActionResult, AgentError>;

    /// Toggle a boolean control with an optional explicit target state.
    async fn toggle_element_state(
        &self,
        target: &str,
        _state: Option<bool>,
    ) -> Result<ActionResult, AgentError> {
        self.toggle_element(target).await
    }
}

/// Trait for querying and mutating application business state and diagnostics.
#[async_trait::async_trait]
pub trait StateProvider: Send + Sync {
    /// Query current application state, optionally filtered by a specific query key.
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError>;

    /// Query current diagnostic and performance metrics.
    async fn get_diagnostics(&self) -> Result<DiagnosticMetrics, AgentError>;

    /// Set an application state property by key.
    async fn set_property(&self, key: &str, value: serde_json::Value) -> Result<(), AgentError>;
}

/// Trait for capturing visual frames and querying viewport dimensions.
#[async_trait::async_trait]
pub trait VisualRenderer: Send + Sync {
    /// Capture the current rendered window frame as a PNG screenshot.
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError>;

    /// Query the current viewport/window dimensions (width, height) in logical pixels.
    async fn get_viewport_size(&self) -> Result<(u32, u32), AgentError>;
}

/// Unified automation engine facade composing inspector, controller, renderer, and state provider.
#[async_trait::async_trait]
pub trait AutomationEngine: Send + Sync {
    /// Access the UI inspector component.
    fn inspector(&self) -> &dyn UiInspector;

    /// Access the element controller component.
    fn controller(&self) -> &dyn ElementController;

    /// Access the application state provider.
    fn state(&self) -> &dyn StateProvider;

    /// Access the visual renderer component.
    fn renderer(&self) -> &dyn VisualRenderer;

    // --- High-level async convenience facade methods ---

    /// Inspect the UI tree.
    async fn inspect_tree(&self) -> Result<UiTree, AgentError> {
        self.inspector().inspect_tree().await
    }

    /// Click an element by selector.
    async fn click_element(&self, target: &str) -> Result<ActionResult, AgentError> {
        self.controller().click_element(target).await
    }

    /// Send text keys.
    async fn send_keys(&self, target: Option<&str>, text: &str) -> Result<ActionResult, AgentError> {
        self.controller().send_keys(target, text).await
    }

    /// Query application state.
    async fn get_state(&self, query: Option<&str>) -> Result<AppState, AgentError> {
        self.state().get_state(query).await
    }

    /// Capture window screenshot.
    async fn get_screenshot(&self) -> Result<Screenshot, AgentError> {
        self.renderer().get_screenshot().await
    }
}
