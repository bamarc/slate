//! Slate WebApp Mirror Showcase
//!
//! Replicates the web application's exact layout:
//! - Top 64px AppLayout header with logo, title, horizontal nav links, design toggle, and user profile
//! - Sticky subheader with title "Component Showcase" and "44+ components" badge
//! - Horizontal Shadcn/Radix-style tabs list
//! - Card-based section layout matching web ShowcasePage.tsx
//! - Full interactive component states and background compute integration

use std::sync::{Arc, Mutex};
use slate::core::task::{spawn_compute, TaskCancellation};

slint::include_modules!();

fn main() -> Result<(), Box<dyn std::error::Error>> {
    slate::init();
    log::info!("Starting Slate WebApp Mirror Showcase...");

    let mirror_window = WebMirrorWindow::new()?;
    let current_task: Arc<Mutex<Option<TaskCancellation>>> = Arc::new(Mutex::new(None));

    // Handle Start Compute
    {
        let window_weak = mirror_window.as_weak();
        let task_slot = current_task.clone();

        mirror_window.on_start_compute(move || {
            let Some(window) = window_weak.upgrade() else { return; };

            window.set_compute_running(true);
            window.set_compute_progress(0.0);
            window.set_compute_status("Computing...".into());
            window.set_compute_result("Working on 20,000,000 samples...".into());

            let win_progress = window_weak.clone();
            let win_complete = window_weak.clone();

            let cancellation = spawn_compute(
                |is_cancelled, progress| {
                    let total_samples: u64 = 20_000_000;
                    let batch_size: u64 = 200_000;
                    let mut inside_circle: u64 = 0;
                    let mut lfsr: u64 = 0xACE1;

                    for i in 0..total_samples {
                        if i % batch_size == 0 {
                            if is_cancelled() {
                                return None;
                            }
                            progress(i as f32 / total_samples as f32);
                        }

                        lfsr = (lfsr >> 1) ^ (-((lfsr & 1) as i64) as u64 & 0xB400);
                        let x = (lfsr as f64) / (u64::MAX as f64) * 2.0 - 1.0;

                        lfsr = (lfsr >> 1) ^ (-((lfsr & 1) as i64) as u64 & 0xB400);
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
        mirror_window.on_cancel_compute(move || {
            if let Some(handle) = task_slot.lock().unwrap().take() {
                handle.cancel();
            }
        });
    }

    // Handle Theme Toggle
    {
        let window_weak = mirror_window.as_weak();
        mirror_window.on_toggle_theme(move || {
            if let Some(win) = window_weak.upgrade() {
                let theme = win.global::<SlateTheme>();
                theme.set_is_dark(!theme.get_is_dark());
            }
        });
    }

    mirror_window.run()?;
    Ok(())
}
