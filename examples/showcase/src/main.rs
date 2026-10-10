//! Slate Showcase Application
//!
//! Demonstrates the Slate framework:
//! - Navigation split view
//! - Kirigami/Libadwaita-inspired widgets
//! - Background compute with progress reporting
//! - Live theme switching

use std::sync::{Arc, Mutex};
use slate::core::task::{spawn_compute, TaskCancellation};

slint::include_modules!();

fn main() -> Result<(), Box<dyn std::error::Error>> {
    slate::init();
    log::info!("Starting Slate Showcase application...");

    let main_window = MainWindow::new()?;
    let current_task: Arc<Mutex<Option<TaskCancellation>>> = Arc::new(Mutex::new(None));

    // Handle Start Compute
    {
        let window_weak = main_window.as_weak();
        let task_slot = current_task.clone();

        main_window.on_start_compute(move || {
            let Some(window) = window_weak.upgrade() else { return; };

            window.set_compute_running(true);
            window.set_compute_progress(0.0);
            window.set_compute_status("Computing...".into());
            window.set_compute_result("Working on 20,000,000 samples...".into());

            let win_progress = window_weak.clone();
            let win_complete = window_weak.clone();

            let cancellation = spawn_compute(
                |is_cancelled, progress| {
                    // Monte Carlo Pi approximation
                    let total_samples: u64 = 20_000_000;
                    let batch_size: u64 = 200_000;
                    let mut inside_circle: u64 = 0;
                    let mut lfsr: u64 = 0xACE1; // fast deterministic pseudo-random

                    for i in 0..total_samples {
                        if i % batch_size == 0 {
                            if is_cancelled() {
                                return None;
                            }
                            progress(i as f32 / total_samples as f32);
                        }

                        // X coordinate
                        lfsr = (lfsr >> 1) ^ (-( (lfsr & 1) as i64 ) as u64 & 0xB400);
                        let x = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;

                        // Y coordinate
                        lfsr = (lfsr >> 1) ^ (-( (lfsr & 1) as i64 ) as u64 & 0xB400);
                        let y = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;

                        if x * x + y * y <= 1.0 {
                            inside_circle += 1;
                        }
                    }

                    let pi_approx = 4.0 * (inside_circle as f64) / (total_samples as f64);
                    Some(pi_approx)
                },
                move |pct| {
                    if let Some(win) = win_progress.upgrade() {
                        win.set_compute_progress(pct);
                    }
                },
                move |result| {
                    if let Some(win) = win_complete.upgrade() {
                        win.set_compute_running(false);
                        match result {
                            Some(pi) => {
                                win.set_compute_progress(1.0);
                                win.set_compute_status("Completed".into());
                                win.set_compute_result(format!("π ≈ {:.6}", pi).into());
                            }
                            None => {
                                win.set_compute_status("Cancelled".into());
                                win.set_compute_result("Computation was cancelled".into());
                            }
                        }
                    }
                },
            );

            *task_slot.lock().unwrap() = Some(cancellation);
        });
    }

    // Handle Cancel Compute
    {
        let task_slot = current_task.clone();
        main_window.on_cancel_compute(move || {
            if let Some(handle) = task_slot.lock().unwrap().take() {
                handle.cancel();
            }
        });
    }

    // Handle Theme Toggle
    {
        let window_weak = main_window.as_weak();
        main_window.on_toggle_theme(move || {
            if let Some(win) = window_weak.upgrade() {
                let theme = win.global::<SlateTheme>();
                theme.set_is_dark(!theme.get_is_dark());
            }
        });
    }

    main_window.run()?;
    Ok(())
}
