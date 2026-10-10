//! Slate Showcase Application
//!
//! Demonstrates the Slate framework:
//! - Navigation split view
//! - Kirigami/Libadwaita-inspired widgets
//! - Background compute with progress reporting
//! - Live theme switching

use slate::demo;
use slate::{AppBuilder, ComputeController};

slint::include_modules!();

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let app = AppBuilder::new("Slate Showcase");
    app.init();

    let main_window = MainWindow::new()?;
    main_window.global::<SlateTheme>().set_is_dark(app.is_dark());

    let controller = ComputeController::new();

    {
        let window_weak = main_window.as_weak();
        let controller = controller.clone();
        main_window.on_start_compute(move || {
            let Some(window) = window_weak.upgrade() else { return; };
            window.set_compute_running(true);
            window.set_compute_progress(0.0);
            window.set_compute_status("Computing...".into());
            window.set_compute_result("Working on 20,000,000 samples...".into());

            let win_progress = window_weak.clone();
            let win_complete = window_weak.clone();
            controller.start(
                demo::monte_carlo_pi,
                move |pct| {
                    if let Some(win) = win_progress.upgrade() {
                        win.set_compute_progress(pct);
                    }
                },
                move |result| {
                    if let Some(win) = win_complete.upgrade() {
                        let (status, text) = demo::describe_result(result);
                        win.set_compute_running(false);
                        if result.is_some() {
                            win.set_compute_progress(1.0);
                        }
                        win.set_compute_status(status.into());
                        win.set_compute_result(text.into());
                    }
                },
            );
        });
    }

    {
        let controller = controller.clone();
        main_window.on_cancel_compute(move || controller.cancel());
    }

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
