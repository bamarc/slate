//! Slate Agent: Core decoupled automation engine and abstraction layer for Slate desktop applications.
//!
//! Provides protocol-agnostic traits, data models, error types, Slint synchronization bridge,
//! timeout guards, command serialization, ACP extension traits, and fluent builder.

pub mod acp;
pub mod bridge;
pub mod builder;
pub mod engine;
pub mod error;
pub mod model;
pub mod protocol;
pub mod semantic;
pub mod slint_backend;
pub mod traits;

// Convenient top-level re-exports
pub use slint_backend::{
    SlintWindowController, SlintWindowInspector, SlintWindowRenderer, SlintWindowStateProvider,
};
pub use acp::{
    AcpEndpoint, AcpMessage, AcpPerformative, AcpResponse, DefaultAcpEndpoint, MockAcpAdapter,
    MockAcpClient, MockAcpConfig, MockAcpServerHandle,
};
pub use bridge::{ComponentBridge, SlintUiBridge, DEFAULT_UI_TIMEOUT};
pub use builder::{AgentBuildComponents, AgentBuilder, AgentHandle};
pub use engine::{AutomationEngineBuilder, DefaultAutomationEngine};
pub use error::{AgentError, Candidate};
pub use semantic::types::*;
pub use model::{
    ActionResult, AppState, DiagnosticMetrics, ElementSelector, MouseButton, Point, Rect,
    Screenshot, UiElementNode, UiTree,
};
pub use protocol::{AgentProtocolAdapter, ProtocolServerHandle};
pub use traits::{
    AutomationEngine, ElementController, StateProvider, UiInspector, VisualRenderer,
};
