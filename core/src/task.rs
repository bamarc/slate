//! Background computation and task management with thread-safe UI updates.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

/// A handle to a running background task that allows cancellation checking.
#[derive(Clone)]
pub struct TaskCancellation {
    cancelled: Arc<AtomicBool>,
}

impl TaskCancellation {
    pub fn new() -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Request the background task to stop.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    /// Check if cancellation was requested.
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }
}

impl Default for TaskCancellation {
    fn default() -> Self {
        Self::new()
    }
}

/// Spawns a CPU-intensive background calculation and provides UI progress callbacks.
///
/// # Example
/// ```rust,no_run
/// use slate_core::task::spawn_compute;
///
/// let cancellation = spawn_compute(
///     |is_cancelled, progress| {
///         for i in 0..=100 {
///             if is_cancelled() { return None; }
///             progress(i as f32 / 100.0);
///             std::thread::sleep(std::time::Duration::from_millis(10));
///         }
///         Some(42)
///     },
///     |pct| {
///         // Called on the UI thread with progress (0.0 to 1.0)
///         println!("Progress: {:.0}%", pct * 100.0);
///     },
///     |result| {
///         // Called on the UI thread when finished
///         println!("Computation finished: {:?}", result);
///     },
/// );
/// ```
pub fn spawn_compute<T, F, P, C>(
    compute_fn: F,
    on_progress: P,
    on_complete: C,
) -> TaskCancellation
where
    T: Send + 'static,
    F: FnOnce(&dyn Fn() -> bool, &dyn Fn(f32)) -> Option<T> + Send + 'static,
    P: Fn(f32) + Send + Sync + 'static,
    C: Fn(Option<T>) + Send + 'static,
{
    let cancellation = TaskCancellation::new();
    let cancellation_clone = cancellation.clone();

    thread::spawn(move || {
        let is_cancelled_fn = || cancellation_clone.is_cancelled();
        let progress_cb = Arc::new(on_progress);

        let progress_fn = {
            let progress_cb = progress_cb.clone();
            move |pct: f32| {
                let cb = progress_cb.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    cb(pct);
                });
            }
        };

        let result = compute_fn(&is_cancelled_fn, &progress_fn);

        let _ = slint::invoke_from_event_loop(move || {
            on_complete(result);
        });
    });

    cancellation
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cancellation() {
        let c = TaskCancellation::new();
        assert!(!c.is_cancelled());
        c.cancel();
        assert!(c.is_cancelled());
    }
}
