//! Unit tests for SlintUiBridge, timeout guard, panic isolation, and command serialization.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::time::sleep;

use slate_agent::bridge::{downcast_panic, SlintUiBridge, DEFAULT_UI_TIMEOUT};
use slate_agent::error::AgentError;

#[tokio::test]
async fn test_bridge_default_timeout() {
    let bridge = SlintUiBridge::new();
    assert_eq!(bridge.timeout(), DEFAULT_UI_TIMEOUT);
}

#[tokio::test]
async fn test_bridge_custom_timeout() {
    let custom = Duration::from_millis(250);
    let bridge = SlintUiBridge::with_timeout(custom);
    assert_eq!(bridge.timeout(), custom);
}

#[tokio::test]
async fn test_command_serializer_mutual_exclusion() {
    let bridge = SlintUiBridge::new();
    let counter = Arc::new(AtomicUsize::new(0));

    let t1 = {
        let bridge = bridge.clone();
        let counter = counter.clone();
        tokio::spawn(async move {
            let _guard = bridge.lock_commands().await;
            counter.fetch_add(1, Ordering::SeqCst);
            sleep(Duration::from_millis(50)).await;
            counter.fetch_add(10, Ordering::SeqCst);
        })
    };

    let t2 = {
        let bridge = bridge.clone();
        let counter = counter.clone();
        tokio::spawn(async move {
            // Give t1 a moment to acquire the lock first
            sleep(Duration::from_millis(10)).await;
            let _guard = bridge.lock_commands().await;
            // At this point, t1 MUST have completed its increment of 10
            assert_eq!(counter.load(Ordering::SeqCst), 11);
            counter.fetch_add(100, Ordering::SeqCst);
        })
    };

    let (r1, r2) = tokio::join!(t1, t2);
    r1.unwrap();
    r2.unwrap();
    assert_eq!(counter.load(Ordering::SeqCst), 111);
}

#[tokio::test]
async fn test_timeout_fires_when_channel_stalls() {
    let timeout_dur = Duration::from_millis(40);
    let (tx, rx) = tokio::sync::oneshot::channel::<Result<i32, AgentError>>();

    let timeout_result = tokio::time::timeout(timeout_dur, rx).await;
    let err: Result<i32, AgentError> = match timeout_result {
        Ok(Ok(val)) => val,
        Ok(Err(_)) => Err(AgentError::UiChannelClosed),
        Err(_) => Err(AgentError::Timeout(format!("Timed out after {:?}", timeout_dur))),
    };

    match err {
        Err(AgentError::Timeout(msg)) => {
            assert!(msg.contains("Timed out after 40ms"));
        }
        other => panic!("Expected AgentError::Timeout, got: {:?}", other),
    }

    drop(tx);
}

#[test]
fn test_downcast_panic_string() {
    let payload: Box<dyn std::any::Any + Send + 'static> = Box::new("Test UI panic".to_string());
    let msg = downcast_panic(payload);
    assert_eq!(msg, "Test UI panic");
}

#[test]
fn test_downcast_panic_str_slice() {
    let payload: Box<dyn std::any::Any + Send + 'static> = Box::new("Static panic str");
    let msg = downcast_panic(payload);
    assert_eq!(msg, "Static panic str");
}

#[test]
fn test_downcast_panic_unknown() {
    let payload: Box<dyn std::any::Any + Send + 'static> = Box::new(42i32);
    let msg = downcast_panic(payload);
    assert_eq!(msg, "Unknown panic on UI thread");
}

#[tokio::test]
async fn test_catch_unwind_isolation() {
    let action = || -> Result<(), AgentError> {
        panic!("Slint widget panic simulation");
    };

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(action));
    let outcome: Result<(), AgentError> = match result {
        Ok(res) => res,
        Err(payload) => Err(AgentError::UiPanic(downcast_panic(payload))),
    };

    match outcome {
        Err(AgentError::UiPanic(msg)) => {
            assert!(msg.contains("Slint widget panic simulation"));
        }
        other => panic!("Expected AgentError::UiPanic, got: {:?}", other),
    }
}

#[test]
fn test_error_equality_and_formatting() {
    let err = AgentError::Timeout("5s exceeded".into());
    assert_eq!(err.to_string(), "Operation timed out: 5s exceeded");

    let err2 = AgentError::WindowClosed;
    assert_eq!(
        err2.to_string(),
        "Window or component has been closed / destroyed"
    );

    let err3 = AgentError::EventLoopUnavailable("loop terminated".into());
    assert_eq!(
        err3.to_string(),
        "Slint event loop is unavailable: loop terminated"
    );
}
