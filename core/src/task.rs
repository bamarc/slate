//! Background computation and task management with thread-safe UI updates.

use std::cell::Cell;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
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
    P: Fn(f32) + Send + 'static,
    C: FnOnce(Option<T>) + Send + 'static,
{
    let cancellation = TaskCancellation::new();
    let task_cancellation = cancellation.clone();

    thread::spawn(move || {
        run_compute(
            compute_fn,
            on_progress,
            on_complete,
            &task_cancellation,
            event_loop_dispatch,
        );
    });

    cancellation
}

/// A unit of work to run on the UI thread.
type UiJob = Box<dyn FnOnce() + Send>;

fn event_loop_dispatch(job: UiJob) {
    let _ = slint::invoke_from_event_loop(job);
}

/// Minimum progress delta (fraction) that is forwarded to the UI.
const PROGRESS_STEP: f32 = 0.005;

/// Runs `compute_fn` on the current thread, forwarding throttled progress and
/// the final result through `dispatch` (which normally posts to the UI thread).
///
/// A panic inside `compute_fn` is caught and reported as `on_complete(None)`.
fn run_compute<T, F, P, C, D>(
    compute_fn: F,
    on_progress: P,
    on_complete: C,
    cancellation: &TaskCancellation,
    dispatch: D,
) where
    T: Send + 'static,
    F: FnOnce(&dyn Fn() -> bool, &dyn Fn(f32)) -> Option<T>,
    P: Fn(f32) + Send + 'static,
    C: FnOnce(Option<T>) + Send + 'static,
    D: Fn(UiJob),
{
    let on_progress = Arc::new(Mutex::new(on_progress));
    // Latest reported value (f32 bits) and whether a UI job is already queued.
    let latest = Arc::new(AtomicU32::new(0f32.to_bits()));
    let pending = Arc::new(AtomicBool::new(false));
    let last_sent = Cell::new(f32::NEG_INFINITY);

    let is_cancelled_fn = || cancellation.is_cancelled();
    let progress_fn = |pct: f32| {
        if (pct - last_sent.get()).abs() < PROGRESS_STEP {
            return;
        }
        last_sent.set(pct);
        latest.store(pct.to_bits(), Ordering::Relaxed);
        // Coalesce: at most one progress job in the UI queue at a time.
        if pending.swap(true, Ordering::AcqRel) {
            return;
        }
        let on_progress = Arc::clone(&on_progress);
        let latest = Arc::clone(&latest);
        let pending = Arc::clone(&pending);
        dispatch(Box::new(move || {
            pending.store(false, Ordering::Release);
            let pct = f32::from_bits(latest.load(Ordering::Relaxed));
            if let Ok(cb) = on_progress.lock() {
                cb(pct);
            }
        }));
    };

    let result = catch_unwind(AssertUnwindSafe(|| {
        compute_fn(&is_cancelled_fn, &progress_fn)
    }))
    .unwrap_or_else(|_| {
        log::error!("background compute task panicked");
        None
    });

    dispatch(Box::new(move || on_complete(result)));
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

    fn immediate(job: UiJob) {
        job();
    }

    #[test]
    fn completes_with_result() {
        let out = Arc::new(Mutex::new(None));
        let o = out.clone();
        run_compute(
            |_, _| Some(7),
            |_| {},
            move |r| *o.lock().unwrap() = Some(r),
            &TaskCancellation::new(),
            immediate,
        );
        assert_eq!(*out.lock().unwrap(), Some(Some(7)));
    }

    #[test]
    fn cancellation_is_visible_to_compute() {
        let c = TaskCancellation::new();
        c.cancel();
        let out = Arc::new(Mutex::new(None));
        let o = out.clone();
        run_compute(
            |is_cancelled, _| if is_cancelled() { None } else { Some(1) },
            |_| {},
            move |r: Option<i32>| *o.lock().unwrap() = Some(r),
            &c,
            immediate,
        );
        assert_eq!(*out.lock().unwrap(), Some(None));
    }

    #[test]
    fn panic_reports_none() {
        let out = Arc::new(Mutex::new(None));
        let o = out.clone();
        run_compute(
            |_, _| -> Option<i32> { panic!("boom") },
            |_| {},
            move |r| *o.lock().unwrap() = Some(r),
            &TaskCancellation::new(),
            immediate,
        );
        assert_eq!(*out.lock().unwrap(), Some(None));
    }

    #[test]
    fn progress_is_throttled() {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let c = calls.clone();
        run_compute(
            |_, progress| {
                for i in 0..=10_000 {
                    progress(i as f32 / 10_000.0);
                }
                Some(())
            },
            move |p| c.lock().unwrap().push(p),
            |_| {},
            &TaskCancellation::new(),
            immediate,
        );
        let n = calls.lock().unwrap().len();
        assert!(n <= 210, "too many progress dispatches: {n}");
        assert!(n >= 100);
    }

    #[test]
    fn progress_coalesces_while_pending() {
        // Dispatcher that queues jobs without running them: only one may queue.
        let queue: Arc<Mutex<Vec<UiJob>>> = Arc::new(Mutex::new(Vec::new()));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = seen.clone();
        let queue_ref = &*queue;
        let dispatch = |job: UiJob| queue_ref.lock().unwrap().push(job);
        run_compute(
            |_, progress| {
                progress(0.1);
                progress(0.5);
                progress(0.9);
                Some(())
            },
            move |p| s.lock().unwrap().push(p),
            |_| {},
            &TaskCancellation::new(),
            dispatch,
        );
        let jobs: Vec<UiJob> = std::mem::take(&mut *queue.lock().unwrap());
        // 1 progress job + 1 completion job.
        assert_eq!(jobs.len(), 2);
        for j in jobs {
            j();
        }
        // The single progress job observes the latest value.
        assert_eq!(*seen.lock().unwrap(), vec![0.9]);
    }
}
