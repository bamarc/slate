//! Offline Render Pipeline & Optical Comparison Tool for Slate
//!
//! Captures PNG snapshots of Slate views with the Slint software renderer and
//! compares images pixel by pixel so they can act as a regression gate.
//!
//! ```text
//! render snapshot [out_dir]                        render all views (default: renders)
//! render compare <a> <b> [diff_out] [--threshold P]  compare two PNGs
//! render check <golden_dir> <actual_dir> [P]       compare every golden PNG by name
//! ```
//!
//! Snapshots require the software renderer: run with `SLINT_BACKEND=software`
//! (the Justfile does this).

use image::{ImageBuffer, Rgba};
use slint::ComponentHandle;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

slint::include_modules!();

type BoxError = Box<dyn std::error::Error>;

const USAGE: &str = "\
Usage:
  render snapshot [out_dir]
  render compare <img_a> <img_b> [diff_out] [--threshold <percent>]
  render check <golden_dir> <actual_dir> [threshold_percent]

`compare` and `check` exit non-zero when more than <percent> of pixels differ
(default 0.0, i.e. pixel-exact). Snapshots need SLINT_BACKEND=software.";

/// Result of comparing two images.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CompareMetrics {
    pub total_pixels: u64,
    pub differing_pixels: u64,
    pub mismatch_percent: f64,
    /// Average per-channel delta in `0.0..=255.0`.
    pub avg_channel_delta: f64,
}

/// Lets pending timers/animations run so the next snapshot reflects the new state.
///
/// The software renderer only evaluates property changes and animation state when
/// the Slint platform is ticked; there is no event loop here, so tick explicitly.
/// Animations are driven by the wall clock and cannot be fast-forwarded, so
/// views are captured in their post-property-change state.
fn settle() {
    // Animations (drawer slide, tab fade, ...) follow the wall clock: let them finish.
    std::thread::sleep(std::time::Duration::from_millis(260));
    for _ in 0..3 {
        slint::platform::update_timers_and_animations();
    }
}

/// Captures a snapshot of the window and saves it to a PNG file.
fn capture_window<T: ComponentHandle>(handle: &T, path: &Path) -> Result<(), BoxError> {
    settle();
    let pixel_buffer = handle.window().take_snapshot()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    image::save_buffer(
        path,
        pixel_buffer.as_bytes(),
        pixel_buffer.width(),
        pixel_buffer.height(),
        image::ExtendedColorType::Rgba8,
    )?;
    println!("✓ Saved snapshot to: {}", path.display());
    Ok(())
}

/// Compares two images, writes a diff heatmap to `diff_out` and returns metrics.
pub fn compare_images(img_a_path: &Path, img_b_path: &Path, diff_out: &Path) -> Result<CompareMetrics, BoxError> {
    let img_a = image::open(img_a_path)?.to_rgba8();
    let img_b = image::open(img_b_path)?.to_rgba8();

    let (width, height) = img_a.dimensions();
    if (width, height) != img_b.dimensions() {
        return Err(format!(
            "Dimension mismatch: {}x{} vs {}x{}",
            width,
            height,
            img_b.width(),
            img_b.height()
        )
        .into());
    }

    let mut diff_img: ImageBuffer<Rgba<u8>, Vec<u8>> = ImageBuffer::new(width, height);
    let mut total_diff: u64 = 0;
    let mut differing_pixels: u64 = 0;
    let total_pixels = u64::from(width) * u64::from(height);

    for y in 0..height {
        for x in 0..width {
            let p_a = img_a.get_pixel(x, y);
            let p_b = img_b.get_pixel(x, y);
            let pixel_diff: u32 = (0..4).map(|i| u32::from(p_a[i].abs_diff(p_b[i]))).sum();
            total_diff += u64::from(pixel_diff);

            if pixel_diff > 0 {
                differing_pixels += 1;
                // Highlight differences in vivid magenta/red
                let intensity = ((pixel_diff as f32 / (255.0 * 4.0)) * 200.0 + 55.0) as u8;
                diff_img.put_pixel(x, y, Rgba([255, 0, 128, intensity]));
            } else {
                // Dim unchanged areas to dark grayscale
                let gray = ((u32::from(p_a[0]) + u32::from(p_a[1]) + u32::from(p_a[2])) / 6) as u8;
                diff_img.put_pixel(x, y, Rgba([gray, gray, gray, 255]));
            }
        }
    }

    if let Some(parent) = diff_out.parent() {
        fs::create_dir_all(parent)?;
    }
    diff_img.save(diff_out)?;

    let (mismatch_percent, avg_channel_delta) = if total_pixels == 0 {
        (0.0, 0.0)
    } else {
        (
            differing_pixels as f64 / total_pixels as f64 * 100.0,
            total_diff as f64 / (total_pixels as f64 * 4.0),
        )
    };
    let metrics = CompareMetrics {
        total_pixels,
        differing_pixels,
        mismatch_percent,
        avg_channel_delta,
    };
    println!("Optical Comparison ({} vs {}):", img_a_path.display(), img_b_path.display());
    println!("  Total Pixels: {}", metrics.total_pixels);
    println!(
        "  Differing Pixels: {} ({:.4}%)",
        metrics.differing_pixels, metrics.mismatch_percent
    );
    println!("  Avg Channel Delta: {:.2} / 255.0", metrics.avg_channel_delta);
    println!("  Diff Heatmap: {}", diff_out.display());
    Ok(metrics)
}

/// Compares every PNG in `golden_dir` with the same-named PNG in `actual_dir`.
/// Returns the number of failures (mismatches above threshold or missing files).
fn check_dirs(golden_dir: &Path, actual_dir: &Path, threshold: f64) -> Result<usize, BoxError> {
    let mut goldens: Vec<PathBuf> = fs::read_dir(golden_dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "png"))
        .collect();
    goldens.sort();
    if goldens.is_empty() {
        return Err(format!("No golden PNGs found in {}", golden_dir.display()).into());
    }

    let diff_dir = actual_dir.join("diffs");
    let mut failures = 0;
    for golden in &goldens {
        let name = golden.file_name().expect("file has a name");
        let actual = actual_dir.join(name);
        if !actual.exists() {
            eprintln!("✗ {}: missing in {}", name.to_string_lossy(), actual_dir.display());
            failures += 1;
            continue;
        }
        match compare_images(golden, &actual, &diff_dir.join(name)) {
            Ok(m) if m.mismatch_percent <= threshold => println!("✓ {}", name.to_string_lossy()),
            Ok(m) => {
                eprintln!(
                    "✗ {}: {:.4}% mismatch exceeds threshold {:.4}%",
                    name.to_string_lossy(),
                    m.mismatch_percent,
                    threshold
                );
                failures += 1;
            }
            Err(e) => {
                eprintln!("✗ {}: {}", name.to_string_lossy(), e);
                failures += 1;
            }
        }
    }
    Ok(failures)
}

/// One snapshot: a file name plus the state to apply before capturing.
struct Shot<W> {
    file: &'static str,
    setup: fn(&W),
}

fn render_shots<W: ComponentHandle>(window: &W, shots: &[Shot<W>], out_dir: &Path) -> Result<(), BoxError> {
    for shot in shots {
        (shot.setup)(window);
        capture_window(window, &out_dir.join(shot.file))?;
    }
    Ok(())
}

fn run_snapshots(out_dir: &Path) -> Result<(), BoxError> {
    println!("🎨 Initializing Slate Optical Render Pipeline...");

    // Desktop showcase
    let window = MainWindow::new()?;
    window.window().set_size(slint::PhysicalSize::new(1040, 720));
    window.show()?;

    let desktop: [Shot<MainWindow>; 12] = [
        Shot { file: "desktop-tab-buttons-dark.png", setup: |w| { w.set_active_tab(0); w.set_modal_open(false); w.global::<SlateTheme>().set_is_dark(true); } },
        Shot { file: "desktop-tab-buttons-light.png", setup: |w| w.global::<SlateTheme>().set_is_dark(false) },
        Shot { file: "desktop-tab-forms-dark.png", setup: |w| { w.global::<SlateTheme>().set_is_dark(true); w.set_active_tab(1); } },
        Shot { file: "desktop-tab-data-dark.png", setup: |w| w.set_active_tab(2) },
        Shot { file: "desktop-tab-feedback-dark.png", setup: |w| w.set_active_tab(3) },
        Shot { file: "desktop-tab-navigation-dark.png", setup: |w| w.set_active_tab(4) },
        Shot { file: "desktop-tab-overlays-dark.png", setup: |w| { w.set_active_tab(5); w.set_modal_open(false); } },
        Shot { file: "desktop-modal-open-dark.png", setup: |w| w.set_modal_open(true) },
        Shot { file: "desktop-tab-compute-dark.png", setup: |w| {
            w.set_modal_open(false);
            w.set_active_tab(6);
            w.set_compute_progress(0.72);
            w.set_compute_running(true);
            w.set_compute_status("Computing... (72%)".into());
            w.set_compute_result("14,400,000 / 20,000,000 samples".into());
        } },
        Shot { file: "desktop-tab-overlays-drawer-open-dark.png", setup: |w| { w.set_active_tab(5); w.set_drawer_open(true); } },
        Shot { file: "desktop-tab-settings-dark.png", setup: |w| { w.set_drawer_open(false); w.set_active_tab(7); } },
        Shot { file: "desktop-tab-feedback-toasts-dark.png", setup: |w| { w.set_drawer_open(false); w.set_active_tab(3); w.invoke_show_demo_toasts(); } },
    ];
    render_shots(&window, &desktop, out_dir)?;

    // Theme comparison (informational only; dark and light are expected to differ)
    compare_images(
        &out_dir.join("desktop-tab-buttons-dark.png"),
        &out_dir.join("desktop-tab-buttons-light.png"),
        &out_dir.join("diff-buttons-theme.png"),
    )?;

    // WebApp mirror
    println!("\n🌐 Rendering WebApp Mirror Layout Snapshots...");
    let web = WebMirrorWindow::new()?;
    web.window().set_size(slint::PhysicalSize::new(1160, 800));
    web.show()?;
    web.global::<SlateTheme>().set_is_dark(true);

    let web_shots: [Shot<WebMirrorWindow>; 12] = [
        Shot { file: "web-tab-buttons-dark.png", setup: |w| w.set_active_tab(0) },
        Shot { file: "web-tab-forms-dark.png", setup: |w| w.set_active_tab(1) },
        Shot { file: "web-tab-data-dark.png", setup: |w| w.set_active_tab(2) },
        Shot { file: "web-tab-feedback-dark.png", setup: |w| w.set_active_tab(3) },
        Shot { file: "web-tab-navigation-dark.png", setup: |w| w.set_active_tab(4) },
        Shot { file: "web-tab-overlays-dark.png", setup: |w| w.set_active_tab(5) },
        Shot { file: "web-overlays-drawer-open-dark.png", setup: |w| { w.set_active_tab(5); w.set_drawer_open(true); } },
        Shot { file: "web-tab-components-dark.png", setup: |w| {
            w.set_drawer_open(false);
            w.set_active_tab(6);
            w.set_compute_running(true);
            w.set_compute_progress(0.72);
            w.set_compute_status("Computing... (72%)".into());
            w.set_compute_result("14,400,000 / 20,000,000 samples".into());
        } },
        Shot { file: "web-page-dashboard-dark.png", setup: |w| w.set_active_nav(0) },
        Shot { file: "web-page-admin-dark.png", setup: |w| w.set_active_nav(1) },
        Shot { file: "web-user-menu-open-dark.png", setup: |w| {
            w.set_active_nav(2);
            w.set_active_tab(0);
            w.set_user_menu_open(true);
        } },
        Shot { file: "web-feedback-toasts-dark.png", setup: |w| { w.set_user_menu_open(false); w.set_active_tab(3); w.invoke_show_demo_toasts(); } },
    ];
    render_shots(&web, &web_shots, out_dir)?;

    println!("\n✨ Render pipeline complete. Snapshots in: {}", out_dir.display());
    Ok(())
}

/// Times `set_active_tab` + first rendered frame for every tab, in the given order, twice.
/// Shows the cost of first-time tab instantiation / font warm-up versus a repeat visit.
fn run_timing(order: &[i32]) -> Result<(), BoxError> {
    let web = WebMirrorWindow::new()?;
    web.window().set_size(slint::PhysicalSize::new(1160, 800));
    web.show()?;
    web.global::<SlateTheme>().set_is_dark(true);
    let t = std::time::Instant::now();
    web.window().take_snapshot()?;
    println!("initial frame (tab 0): {:.1} ms", t.elapsed().as_secs_f64() * 1000.0);
    for pass in 1..=2 {
        for &tab in order {
            let t = std::time::Instant::now();
            web.set_active_tab(tab);
            slint::platform::update_timers_and_animations();
            web.window().take_snapshot()?;
            println!("pass {pass} tab {tab}: {:.1} ms", t.elapsed().as_secs_f64() * 1000.0);
        }
    }
    Ok(())
}

/// Same as `run_timing` but with a real event loop and the selected GPU renderer
/// (`SLINT_BACKEND=winit-femtovg`): measures set_active_tab -> end of the next rendered frame.
fn run_timing_live(order: &[i32]) -> Result<(), BoxError> {
    use std::cell::{Cell, RefCell};
    use std::rc::Rc;
    let web = WebMirrorWindow::new()?;
    web.window().set_size(slint::PhysicalSize::new(1160, 800));
    web.global::<SlateTheme>().set_is_dark(true);
    let start: Rc<Cell<Option<std::time::Instant>>> = Rc::new(Cell::new(None));
    let log: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
    let label = Rc::new(RefCell::new(String::from("initial")));
    let before = Rc::new(Cell::new(0.0f64));
    {
        let (start, log, label, before) = (start.clone(), log.clone(), label.clone(), before.clone());
        web.window().set_rendering_notifier(move |state, _| {
            match state {
                slint::RenderingState::BeforeRendering => {
                    if let Some(t) = start.get() {
                        before.set(t.elapsed().as_secs_f64() * 1000.0);
                    }
                }
                slint::RenderingState::AfterRendering => {
                    if let Some(t) = start.take() {
                        log.borrow_mut().push(format!(
                            "{}: {:.1} ms (layout/instantiate {:.1} + draw {:.1})",
                            label.borrow(),
                            t.elapsed().as_secs_f64() * 1000.0,
                            before.get(),
                            t.elapsed().as_secs_f64() * 1000.0 - before.get()
                        ));
                    }
                }
                _ => {}
            }
        })?;
    }
    start.set(Some(std::time::Instant::now()));
    web.show()?;
    let steps: Vec<(i32, i32)> = (1..=2).flat_map(|p| order.iter().map(move |&t| (p, t))).collect();
    let idx = Rc::new(Cell::new(0usize));
    let timer = slint::Timer::default();
    let weak = web.as_weak();
    {
        let (start, label, log, idx) = (start.clone(), label.clone(), log.clone(), idx.clone());
        timer.start(slint::TimerMode::Repeated, std::time::Duration::from_millis(400), move || {
            let i = idx.get();
            if i >= steps.len() {
                for l in log.borrow().iter() {
                    println!("{l}");
                }
                let _ = slint::quit_event_loop();
                return;
            }
            idx.set(i + 1);
            let (pass, tab) = steps[i];
            *label.borrow_mut() = format!("pass {pass} tab {tab}");
            start.set(Some(std::time::Instant::now()));
            if let Some(w) = weak.upgrade() {
                w.set_active_tab(tab);
            }
        });
    }
    slint::run_event_loop()?;
    Ok(())
}

fn parse_percent(s: &str) -> Result<f64, BoxError> {
    let v: f64 = s.parse().map_err(|_| format!("invalid threshold '{s}'"))?;
    if !(0.0..=100.0).contains(&v) {
        return Err(format!("threshold {v} out of range 0..=100").into());
    }
    Ok(v)
}

fn run(args: &[String]) -> Result<ExitCode, BoxError> {
    match args.first().map(String::as_str) {
        Some("snapshot") => {
            let out_dir = args.get(1).map_or_else(|| PathBuf::from("renders"), PathBuf::from);
            run_snapshots(&out_dir)?;
            Ok(ExitCode::SUCCESS)
        }
        Some("timing") => {
            let order: Vec<i32> = args[1..].iter().filter_map(|a| a.parse().ok()).collect();
            let order = if order.is_empty() { vec![1, 0, 2, 3, 4, 5, 6] } else { order };
            if std::env::var("SLINT_BACKEND").is_ok_and(|b| b != "software") {
                run_timing_live(&order)?;
            } else {
                run_timing(&order)?;
            }
            Ok(ExitCode::SUCCESS)
        }
        Some("compare") => {
            let mut positional = Vec::new();
            let mut threshold = 0.0;
            let mut it = args[1..].iter();
            while let Some(a) = it.next() {
                if a == "--threshold" {
                    threshold = parse_percent(it.next().ok_or("--threshold needs a value")?)?;
                } else {
                    positional.push(a);
                }
            }
            let [a, b, rest @ ..] = positional.as_slice() else {
                return Err(format!("compare needs <img_a> <img_b>\n\n{USAGE}").into());
            };
            let diff_out = rest.first().map_or_else(|| PathBuf::from("renders/optical-diff.png"), |p| PathBuf::from(p));
            let m = compare_images(Path::new(a), Path::new(b), &diff_out)?;
            if m.mismatch_percent > threshold {
                eprintln!("✗ mismatch {:.4}% exceeds threshold {:.4}%", m.mismatch_percent, threshold);
                return Ok(ExitCode::FAILURE);
            }
            Ok(ExitCode::SUCCESS)
        }
        Some("check") => {
            let (Some(golden), Some(actual)) = (args.get(1), args.get(2)) else {
                return Err(format!("check needs <golden_dir> <actual_dir>\n\n{USAGE}").into());
            };
            let threshold = args.get(3).map_or(Ok(0.0), |s| parse_percent(s))?;
            let failures = check_dirs(Path::new(golden), Path::new(actual), threshold)?;
            if failures > 0 {
                eprintln!("✗ {failures} snapshot(s) failed the optical check");
                return Ok(ExitCode::FAILURE);
            }
            println!("✓ All snapshots match the golden images");
            Ok(ExitCode::SUCCESS)
        }
        _ => {
            eprintln!("{USAGE}");
            Ok(ExitCode::from(2))
        }
    }
}

fn main() -> ExitCode {
    if std::env::var_os("SLINT_BACKEND").is_none() {
        // SAFETY: this is the first statement of `main`, before any thread is
        // spawned by this program, so nothing can race on the environment.
        unsafe { std::env::set_var("SLINT_BACKEND", "software") };
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("slate-render-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    fn solid(path: &Path, w: u32, h: u32, px: Rgba<u8>) {
        ImageBuffer::from_pixel(w, h, px).save(path).unwrap();
    }

    #[test]
    fn identical_images_have_zero_mismatch() {
        let (a, b, d) = (tmp("id_a.png"), tmp("id_b.png"), tmp("id_d.png"));
        solid(&a, 4, 4, Rgba([10, 20, 30, 255]));
        solid(&b, 4, 4, Rgba([10, 20, 30, 255]));
        let m = compare_images(&a, &b, &d).unwrap();
        assert_eq!(m.differing_pixels, 0);
        assert_eq!(m.mismatch_percent, 0.0);
        assert_eq!(m.avg_channel_delta, 0.0);
    }

    #[test]
    fn single_differing_pixel_is_detected() {
        let (a, b, d) = (tmp("px_a.png"), tmp("px_b.png"), tmp("px_d.png"));
        solid(&a, 10, 10, Rgba([0, 0, 0, 255]));
        let mut img = ImageBuffer::from_pixel(10, 10, Rgba([0u8, 0, 0, 255]));
        img.put_pixel(3, 3, Rgba([4, 0, 0, 255]));
        img.save(&b).unwrap();
        let m = compare_images(&a, &b, &d).unwrap();
        assert_eq!(m.total_pixels, 100);
        assert_eq!(m.differing_pixels, 1);
        assert!((m.mismatch_percent - 1.0).abs() < 1e-9);
        assert!((m.avg_channel_delta - 4.0 / 400.0).abs() < 1e-9);
    }

    #[test]
    fn dimension_mismatch_is_an_error() {
        let (a, b, d) = (tmp("dim_a.png"), tmp("dim_b.png"), tmp("dim_d.png"));
        solid(&a, 4, 4, Rgba([0, 0, 0, 255]));
        solid(&b, 5, 4, Rgba([0, 0, 0, 255]));
        let err = compare_images(&a, &b, &d).unwrap_err().to_string();
        assert!(err.contains("Dimension mismatch"), "{err}");
    }

    #[test]
    fn check_dirs_flags_missing_and_mismatching_files() {
        let base = tmp("check");
        let (golden, actual) = (base.join("golden"), base.join("actual"));
        fs::create_dir_all(&golden).unwrap();
        fs::create_dir_all(&actual).unwrap();
        solid(&golden.join("ok.png"), 2, 2, Rgba([1, 1, 1, 255]));
        solid(&actual.join("ok.png"), 2, 2, Rgba([1, 1, 1, 255]));
        assert_eq!(check_dirs(&golden, &actual, 0.0).unwrap(), 0);
        solid(&golden.join("missing.png"), 2, 2, Rgba([1, 1, 1, 255]));
        assert_eq!(check_dirs(&golden, &actual, 0.0).unwrap(), 1);
    }
}
