//! Reusable start/cancel coordination for a single background computation.

use slate_core::task::{spawn_compute, TaskCancellation};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// Owns at most one running background task. Starting a new run cancels the
/// previous one, and callbacks of superseded runs are suppressed via a
/// run-generation id so they cannot overwrite a newer run's UI state.
///
/// `start` and `cancel` are meant to be called from the UI thread.
#[derive(Clone, Default)]
pub struct ComputeController {
    slot: Arc<Mutex<Option<TaskCancellation>>>,
    generation: Arc<AtomicU64>,
}

impl ComputeController {
    pub fn new() -> Self {
        Self::default()
    }

    /// Cancels any running task and starts a new one. `on_progress` and
    /// `on_complete` run on the UI thread, and only if this run is still the
    /// current one. Returns the run id.
    pub fn start<T, F, P, C>(&self, compute_fn: F, on_progress: P, on_complete: C) -> u64
    where
        T: Send + 'static,
        F: FnOnce(&dyn Fn() -> bool, &dyn Fn(f32)) -> Option<T> + Send + 'static,
        P: Fn(f32) + Send + 'static,
        C: FnOnce(Option<T>) + Send + 'static,
    {
        let mut slot = self.slot.lock().unwrap();
        if let Some(previous) = slot.take() {
            previous.cancel();
        }
        let run_id = self.generation.fetch_add(1, Ordering::SeqCst) + 1;

        let gen_progress = Arc::clone(&self.generation);
        let gen_complete = Arc::clone(&self.generation);
        let slot_complete = Arc::clone(&self.slot);

        let cancellation = spawn_compute(
            compute_fn,
            move |pct| {
                if gen_progress.load(Ordering::SeqCst) == run_id {
                    on_progress(pct);
                }
            },
            move |result| {
                if gen_complete.load(Ordering::SeqCst) != run_id {
                    return;
                }
                slot_complete.lock().unwrap().take();
                on_complete(result);
            },
        );
        *slot = Some(cancellation);
        run_id
    }

    /// Requests cancellation of the current run, if any. Its completion
    /// callback still fires (with `None`) so the UI can leave the running state.
    pub fn cancel(&self) {
        if let Some(handle) = self.slot.lock().unwrap().as_ref() {
            handle.cancel();
        }
    }

    /// Whether a run is in flight (started and not yet completed).
    pub fn is_running(&self) -> bool {
        self.slot.lock().unwrap().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_by_default_and_cancel_is_noop() {
        let c = ComputeController::new();
        assert!(!c.is_running());
        c.cancel();
    }

    #[test]
    fn start_cancels_previous_and_bumps_generation() {
        let c = ComputeController::new();
        // No event loop in tests: completion callbacks never fire, which is fine here.
        let first_cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let f = first_cancelled.clone();
        let id1 = c.start(
            move |is_cancelled, _| {
                while !is_cancelled() {
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                f.store(true, Ordering::SeqCst);
                None::<()>
            },
            |_| {},
            |_| {},
        );
        let id2 = c.start(|_, _| Some(()), |_| {}, |_| {});
        assert!(id2 > id1);
        assert!(c.is_running());
        for _ in 0..2000 {
            if first_cancelled.load(Ordering::SeqCst) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        panic!("previous run was not cancelled");
    }
}
