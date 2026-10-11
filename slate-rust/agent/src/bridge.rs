//! Thread-safe, non-blocking bridge between asynchronous tasks and the Slint UI event loop.

use std::any::Any;
use std::sync::Arc;
use std::time::Duration;
use slint::ComponentHandle;
use tokio::sync::{oneshot, Mutex};
use tokio::time::timeout;

use crate::error::AgentError;

/// Default timeout duration for UI thread operations (5 seconds).
pub const DEFAULT_UI_TIMEOUT: Duration = Duration::from_secs(5);

/// Thread-safe synchronization bridge for executing operations on the Slint event loop.
///
/// Dispatches closures to the Slint UI thread via `slint::invoke_from_event_loop`,
/// awaits results over a `tokio::sync::oneshot` channel with a timeout guard,
/// and catches UI-thread panics without terminating the application.
#[derive(Clone)]
pub struct SlintUiBridge {
    /// Mutex for serializing UI mutation commands to prevent interleaving race conditions.
    command_lock: Arc<Mutex<()>>,
    /// Configurable timeout for UI thread operations.
    timeout: Duration,
}

impl SlintUiBridge {
    /// Creates a new `SlintUiBridge` with the default 5-second timeout.
    pub fn new() -> Self {
        Self::with_timeout(DEFAULT_UI_TIMEOUT)
    }

    /// Creates a new `SlintUiBridge` with a custom timeout duration.
    pub fn with_timeout(timeout: Duration) -> Self {
        Self {
            command_lock: Arc::new(Mutex::new(())),
            timeout,
        }
    }

    /// Returns the configured timeout duration.
    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    /// Acquires the command serializer lock.
    ///
    /// Holding this lock ensures exclusive access to the UI event loop
    /// for multi-step interactions (e.g. pointer press -> delay -> pointer release).
    pub async fn lock_commands(&self) -> tokio::sync::MutexGuard<'_, ()> {
        self.command_lock.lock().await
    }

    /// Dispatches a closure to execute on the Slint UI event loop thread.
    ///
    /// The closure is wrapped in `std::panic::catch_unwind` to intercept any panics
    /// that might occur in UI code, converting them into typed `AgentError::UiPanic`.
    ///
    /// # Errors
    /// - `AgentError::EventLoopUnavailable` if `slint::invoke_from_event_loop` fails.
    /// - `AgentError::Timeout` if the UI thread does not complete the closure within `self.timeout`.
    /// - `AgentError::UiPanic` if the closure panics on the UI thread.
    /// - `AgentError::UiChannelClosed` if the response channel is dropped unexpectedly.
    pub async fn run_on_ui<F, R>(&self, action: F) -> Result<R, AgentError>
    where
        F: FnOnce() -> Result<R, AgentError> + Send + 'static,
        R: Send + 'static,
    {
        let (tx, rx) = oneshot::channel();

        slint::invoke_from_event_loop(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(action));
            let outcome = match result {
                Ok(inner_res) => inner_res,
                Err(panic_payload) => {
                    let msg = downcast_panic(panic_payload);
                    log::error!("Intercepted panic on Slint UI thread: {}", msg);
                    Err(AgentError::UiPanic(msg))
                }
            };
            let _ = tx.send(outcome);
        })
        .map_err(|e| AgentError::EventLoopUnavailable(e.to_string()))?;

        match timeout(self.timeout, rx).await {
            Ok(Ok(val)) => val,
            Ok(Err(_oneshot_closed)) => Err(AgentError::UiChannelClosed),
            Err(_elapsed) => Err(AgentError::Timeout(format!(
                "UI thread operation timed out after {:?}",
                self.timeout
            ))),
        }
    }

    /// Dispatches a closure to execute on the Slint UI event loop with command serialization.
    ///
    /// Automatically acquires the command serializer lock before dispatching and releases it
    /// once the UI thread operation completes or times out.
    pub async fn run_serialized<F, R>(&self, action: F) -> Result<R, AgentError>
    where
        F: FnOnce() -> Result<R, AgentError> + Send + 'static,
        R: Send + 'static,
    {
        let _guard = self.lock_commands().await;
        self.run_on_ui(action).await
    }
}

impl Default for SlintUiBridge {
    fn default() -> Self {
        Self::new()
    }
}

/// Typed component bridge holding a `Weak<T>` handle for a specific Slint window/component.
#[derive(Clone)]
pub struct ComponentBridge<T: ComponentHandle + 'static> {
    bridge: Arc<SlintUiBridge>,
    weak: slint::Weak<T>,
}

impl<T: ComponentHandle + 'static> ComponentBridge<T> {
    /// Creates a new `ComponentBridge` wrapping a component weak handle and a `SlintUiBridge`.
    pub fn new(weak: slint::Weak<T>, bridge: Arc<SlintUiBridge>) -> Self {
        Self { bridge, weak }
    }

    /// Returns a reference to the underlying `SlintUiBridge`.
    pub fn bridge(&self) -> &Arc<SlintUiBridge> {
        &self.bridge
    }

    /// Returns a reference to the component weak handle.
    pub fn weak(&self) -> &slint::Weak<T> {
        &self.weak
    }

    /// Dispatches an action requiring access to the upgraded component handle.
    ///
    /// Automatically upgrades `self.weak` on the UI thread.
    /// Returns `Err(AgentError::WindowClosed)` if the component has been destroyed.
    pub async fn run_with_window<F, R>(&self, action: F) -> Result<R, AgentError>
    where
        F: FnOnce(T) -> Result<R, AgentError> + Send + 'static,
        R: Send + 'static,
    {
        let weak = self.weak.clone();
        self.bridge
            .run_on_ui(move || {
                let handle = weak.upgrade().ok_or(AgentError::WindowClosed)?;
                action(handle)
            })
            .await
    }

    /// Dispatches an action requiring access to the upgraded component handle with command serialization.
    pub async fn run_with_window_serialized<F, R>(&self, action: F) -> Result<R, AgentError>
    where
        F: FnOnce(T) -> Result<R, AgentError> + Send + 'static,
        R: Send + 'static,
    {
        let _guard = self.bridge.lock_commands().await;
        self.run_with_window(action).await
    }
}

/// Helper function to safely extract panic messages from dynamic panic payloads.
pub fn downcast_panic(payload: Box<dyn Any + Send + 'static>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "Unknown panic on UI thread".to_string()
    }
}
