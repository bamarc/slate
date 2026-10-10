//! Offline Render Pipeline & Optical Comparison Tool for Slate
//!
//! Captures pixel-perfect PNG snapshots of Slate views and components,
//! and performs optical comparisons (diffs, pixel metrics).

use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;
use image::{ImageBuffer, Rgba};
use slint::ComponentHandle;

slint::include_modules!();

/// Captures a snapshot of the window and saves it to a PNG file.
fn capture_window<T: ComponentHandle>(handle: &T, path: &Path) -> Result<(), Box<dyn std::error::Error>> {
    slint::platform::update_timers_and_animations();
    let window = handle.window();
    let pixel_buffer = window.take_snapshot()?;
    let width = pixel_buffer.width();
    let height = pixel_buffer.height();
    let bytes = pixel_buffer.as_bytes();

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    image::save_buffer(path, bytes, width, height, image::ExtendedColorType::Rgba8)?;
    println!("✓ Saved snapshot to: {}", path.display());
    Ok(())
}

/// Computes an optical comparison between two images, outputs difference heatmap and metrics.
pub fn compare_images(img_a_path: &Path, img_b_path: &Path, diff_out: &Path) -> Result<f64, Box<dyn std::error::Error>> {
    let img_a = image::open(img_a_path)?.to_rgba8();
    let img_b = image::open(img_b_path)?.to_rgba8();

    let (width, height) = img_a.dimensions();
    if (width, height) != img_b.dimensions() {
        return Err(format!(
            "Dimension mismatch: {}x{} vs {}x{}",
            width, height, img_b.width(), img_b.height()
        ).into());
    }

    let mut diff_img: ImageBuffer<Rgba<u8>, Vec<u8>> = ImageBuffer::new(width, height);
    let mut total_diff: u64 = 0;
    let mut differing_pixels: u64 = 0;
    let total_pixels = (width as u64) * (height as u64);

    for y in 0..height {
        for x in 0..width {
            let p_a = img_a.get_pixel(x, y);
            let p_b = img_b.get_pixel(x, y);

            let dr = (p_a[0] as i32 - p_b[0] as i32).abs() as u32;
            let dg = (p_a[1] as i32 - p_b[1] as i32).abs() as u32;
            let db = (p_a[2] as i32 - p_b[2] as i32).abs() as u32;
            let da = (p_a[3] as i32 - p_b[3] as i32).abs() as u32;

            let pixel_diff = dr + dg + db + da;
            total_diff += pixel_diff as u64;

            if pixel_diff > 0 {
                differing_pixels += 1;
                // Highlight differences in vivid magenta/red
                let intensity = ((pixel_diff as f32 / (255.0 * 4.0)) * 200.0 + 55.0) as u8;
                diff_img.put_pixel(x, y, Rgba([255, 0, 128, intensity]));
            } else {
                // Dim down unchanged areas to dark grayscale
                let gray = ((p_a[0] as u32 + p_a[1] as u32 + p_a[2] as u32) / 6) as u8;
                diff_img.put_pixel(x, y, Rgba([gray, gray, gray, 255]));
            }
        }
    }

    if let Some(parent) = diff_out.parent() {
        fs::create_dir_all(parent)?;
    }
    diff_img.save(diff_out)?;

    let mismatch_percent = (differing_pixels as f64 / total_pixels as f64) * 100.0;
    let avg_pixel_diff = total_diff as f64 / (total_pixels as f64 * 4.0);
    println!("Optical Comparison Results ({} vs {}):", img_a_path.display(), img_b_path.display());
    println!("  Total Pixels: {}", total_pixels);
    println!("  Differing Pixels: {} ({:.2}%)", differing_pixels, mismatch_percent);
    println!("  Avg Channel Delta: {:.2} / 255.0", avg_pixel_diff);
    println!("  Diff Heatmap saved to: {}", diff_out.display());

    Ok(mismatch_percent)
}

fn copy_to_brain(src: &Path, file_name: &str) {
    let brain_dir = Path::new("/home/developer/.gemini/antigravity/brain/7238345c-9640-46a6-ae3b-1f8162f4ec01");
    if brain_dir.exists() {
        let dest = brain_dir.join(file_name);
        if let Err(e) = fs::copy(src, &dest) {
            eprintln!("Warning: failed to copy {} to brain artifacts: {}", file_name, e);
        } else {
            println!("  ↳ Copied artifact to brain: {}", file_name);
        }
    }
}

fn run_snapshots(out_dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
    println!("🎨 Initializing Slate Optical Render Pipeline...");
    let window = MainWindow::new()?;

    // Standardized window dimension matching desktop resolution
    window.window().set_size(slint::PhysicalSize::new(1040, 720));
    window.show()?;

    // 1. Tab 0: Buttons & Badges (Dark Mode)
    window.set_active_tab(0);
    window.set_modal_open(false);
    window.global::<SlateTheme>().set_is_dark(true);
    thread::sleep(Duration::from_millis(50));
    let tab0_dark = out_dir.join("desktop-tab-buttons-dark.png");
    capture_window(&window, &tab0_dark)?;
    copy_to_brain(&tab0_dark, "desktop-tab-buttons-dark.png");

    // 2. Tab 0: Buttons & Badges (Light Mode)
    window.global::<SlateTheme>().set_is_dark(false);
    thread::sleep(Duration::from_millis(50));
    let tab0_light = out_dir.join("desktop-tab-buttons-light.png");
    capture_window(&window, &tab0_light)?;
    copy_to_brain(&tab0_light, "desktop-tab-buttons-light.png");

    // Switch back to Dark Mode for remaining showcase tabs
    window.global::<SlateTheme>().set_is_dark(true);

    // 3. Tab 1: Forms & Inputs
    window.set_active_tab(1);
    thread::sleep(Duration::from_millis(50));
    let tab1_path = out_dir.join("desktop-tab-forms-dark.png");
    capture_window(&window, &tab1_path)?;
    copy_to_brain(&tab1_path, "desktop-tab-forms-dark.png");

    // 4. Tab 2: Data Display & Tables
    window.set_active_tab(2);
    thread::sleep(Duration::from_millis(50));
    let tab2_path = out_dir.join("desktop-tab-data-dark.png");
    capture_window(&window, &tab2_path)?;
    copy_to_brain(&tab2_path, "desktop-tab-data-dark.png");

    // 5. Tab 3: Feedback & Status
    window.set_active_tab(3);
    thread::sleep(Duration::from_millis(50));
    let tab3_path = out_dir.join("desktop-tab-feedback-dark.png");
    capture_window(&window, &tab3_path)?;
    copy_to_brain(&tab3_path, "desktop-tab-feedback-dark.png");

    // 6. Tab 4: Navigation
    window.set_active_tab(4);
    thread::sleep(Duration::from_millis(50));
    let tab4_path = out_dir.join("desktop-tab-navigation-dark.png");
    capture_window(&window, &tab4_path)?;
    copy_to_brain(&tab4_path, "desktop-tab-navigation-dark.png");

    // 7. Tab 5: Overlays & Modals (Resting state)
    window.set_active_tab(5);
    window.set_modal_open(false);
    thread::sleep(Duration::from_millis(50));
    let tab5_path = out_dir.join("desktop-tab-overlays-dark.png");
    capture_window(&window, &tab5_path)?;
    copy_to_brain(&tab5_path, "desktop-tab-overlays-dark.png");

    // 8. Tab 5 with Modal Dialog Open!
    window.set_modal_open(true);
    thread::sleep(Duration::from_millis(50));
    let modal_path = out_dir.join("desktop-modal-open-dark.png");
    capture_window(&window, &modal_path)?;
    copy_to_brain(&modal_path, "desktop-modal-open-dark.png");
    window.set_modal_open(false);

    // 9. Tab 6: Compute Engine View
    window.set_active_tab(6);
    window.set_compute_progress(0.72);
    window.set_compute_running(true);
    window.set_compute_status("Computing... (72%)".into());
    window.set_compute_result("14,400,000 / 20,000,000 samples".into());
    thread::sleep(Duration::from_millis(50));
    let compute_path = out_dir.join("desktop-tab-compute-dark.png");
    capture_window(&window, &compute_path)?;
    copy_to_brain(&compute_path, "desktop-tab-compute-dark.png");

    // 10. Tab 7: Settings View
    window.set_active_tab(7);
    thread::sleep(Duration::from_millis(50));
    let settings_path = out_dir.join("desktop-tab-settings-dark.png");
    capture_window(&window, &settings_path)?;
    copy_to_brain(&settings_path, "desktop-tab-settings-dark.png");

    // 11. Optical Comparison: Dark vs Light on Buttons & Badges
    let diff_buttons_path = out_dir.join("diff-buttons-theme.png");
    compare_images(&tab0_dark, &tab0_light, &diff_buttons_path)?;
    copy_to_brain(&diff_buttons_path, "diff-buttons-theme.png");

    // ==========================================
    // WebApp Mirror Showcase Snapshots
    // ==========================================
    println!("\n🌐 Rendering WebApp Mirror Layout Snapshots...");
    let web_window = WebMirrorWindow::new()?;
    web_window.window().set_size(slint::PhysicalSize::new(1160, 800));
    web_window.show()?;
    web_window.global::<SlateTheme>().set_is_dark(true);

    // Web Tab 0: Buttons & Badges
    web_window.set_active_tab(0);
    thread::sleep(Duration::from_millis(50));
    let web_tab0 = out_dir.join("web-tab-buttons-dark.png");
    capture_window(&web_window, &web_tab0)?;
    copy_to_brain(&web_tab0, "web-tab-buttons-dark.png");

    // Web Tab 1: Forms & Inputs
    web_window.set_active_tab(1);
    thread::sleep(Duration::from_millis(50));
    let web_tab1 = out_dir.join("web-tab-forms-dark.png");
    capture_window(&web_window, &web_tab1)?;
    copy_to_brain(&web_tab1, "web-tab-forms-dark.png");

    // Web Tab 2: Data Display
    web_window.set_active_tab(2);
    thread::sleep(Duration::from_millis(50));
    let web_tab2 = out_dir.join("web-tab-data-dark.png");
    capture_window(&web_window, &web_tab2)?;
    copy_to_brain(&web_tab2, "web-tab-data-dark.png");

    // Web Tab 3: Feedback
    web_window.set_active_tab(3);
    thread::sleep(Duration::from_millis(50));
    let web_tab3 = out_dir.join("web-tab-feedback-dark.png");
    capture_window(&web_window, &web_tab3)?;
    copy_to_brain(&web_tab3, "web-tab-feedback-dark.png");

    // Web Tab 4: Navigation
    web_window.set_active_tab(4);
    thread::sleep(Duration::from_millis(50));
    let web_tab4 = out_dir.join("web-tab-navigation-dark.png");
    capture_window(&web_window, &web_tab4)?;
    copy_to_brain(&web_tab4, "web-tab-navigation-dark.png");

    // Web Tab 5: Overlays
    web_window.set_active_tab(5);
    thread::sleep(Duration::from_millis(50));
    let web_tab5 = out_dir.join("web-tab-overlays-dark.png");
    capture_window(&web_window, &web_tab5)?;
    copy_to_brain(&web_tab5, "web-tab-overlays-dark.png");

    // Web Tab 6: Components & Compute
    web_window.set_active_tab(6);
    web_window.set_compute_running(true);
    web_window.set_compute_progress(0.72);
    web_window.set_compute_status("Computing... (72%)".into());
    web_window.set_compute_result("14,400,000 / 20,000,000 samples".into());
    thread::sleep(Duration::from_millis(50));
    let web_tab6 = out_dir.join("web-tab-components-dark.png");
    capture_window(&web_window, &web_tab6)?;
    copy_to_brain(&web_tab6, "web-tab-components-dark.png");

    println!("\n✨ Render Pipeline Complete! All snapshots generated in: {}", out_dir.display());
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var("SLINT_BACKEND").is_err() {
        std::env::set_var("SLINT_BACKEND", "software");
    }
    let args: Vec<String> = std::env::args().collect();

    if args.len() >= 4 && args[1] == "compare" {
        let img_a = Path::new(&args[2]);
        let img_b = Path::new(&args[3]);
        let diff_out = if args.len() >= 5 {
            PathBuf::from(&args[4])
        } else {
            PathBuf::from("renders/optical-diff.png")
        };
        compare_images(img_a, img_b, &diff_out)?;
        return Ok(());
    }

    let out_dir = if args.len() > 1 && args[1] != "snapshot" {
        PathBuf::from(&args[1])
    } else if args.len() > 2 {
        PathBuf::from(&args[2])
    } else {
        PathBuf::from("renders")
    };

    run_snapshots(&out_dir)
}
