//! Shared demo workload used by the showcase binaries.

/// Number of samples used by the showcase.
pub const DEFAULT_SAMPLES: u64 = 20_000_000;

const BATCH_SIZE: u64 = 200_000;

/// splitmix64: small, fast, full-period 64-bit PRNG.
struct SplitMix64(u64);

impl SplitMix64 {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1) using the top 53 bits.
    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Monte Carlo approximation of pi with [`DEFAULT_SAMPLES`] samples.
pub fn monte_carlo_pi(is_cancelled: &dyn Fn() -> bool, progress: &dyn Fn(f32)) -> Option<f64> {
    monte_carlo_pi_samples(DEFAULT_SAMPLES, is_cancelled, progress)
}

/// Monte Carlo approximation of pi using `total_samples` points in the unit
/// square. Returns `None` if cancelled.
pub fn monte_carlo_pi_samples(
    total_samples: u64,
    is_cancelled: &dyn Fn() -> bool,
    progress: &dyn Fn(f32),
) -> Option<f64> {
    if total_samples == 0 {
        return Some(0.0);
    }
    let mut rng = SplitMix64(0x5EED_1234_ABCD_EF01);
    let mut inside: u64 = 0;

    for i in 0..total_samples {
        if i % BATCH_SIZE == 0 {
            if is_cancelled() {
                return None;
            }
            progress(i as f32 / total_samples as f32);
        }
        let x = rng.next_f64();
        let y = rng.next_f64();
        if x * x + y * y <= 1.0 {
            inside += 1;
        }
    }
    Some(4.0 * inside as f64 / total_samples as f64)
}

/// Status and result text for the UI for a finished run.
pub fn describe_result(result: Option<f64>) -> (&'static str, String) {
    match result {
        Some(pi) => ("Completed", format!("π ≈ {pi:.6}")),
        None => ("Cancelled", "Computation was cancelled".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::f64::consts::PI;

    #[test]
    fn approximates_pi() {
        let pi = monte_carlo_pi_samples(2_000_000, &|| false, &|_| {}).unwrap();
        assert!((pi - PI).abs() < 0.01, "got {pi}");
    }

    #[test]
    fn cancellation_returns_none() {
        assert_eq!(monte_carlo_pi_samples(2_000_000, &|| true, &|_| {}), None);
    }

    #[test]
    fn cancel_midway_returns_none() {
        let polls = Cell::new(0);
        let cancelled = || {
            polls.set(polls.get() + 1);
            polls.get() > 3
        };
        assert_eq!(monte_carlo_pi_samples(2_000_000, &cancelled, &|_| {}), None);
    }

    #[test]
    fn prng_covers_unit_range() {
        let mut rng = SplitMix64(1);
        let v: Vec<f64> = (0..10_000).map(|_| rng.next_f64()).collect();
        assert!(v.iter().all(|x| (0.0..1.0).contains(x)));
        assert!(v.iter().cloned().fold(0.0, f64::max) > 0.99);
    }

    #[test]
    fn describes_results() {
        assert_eq!(describe_result(Some(3.14159265)).0, "Completed");
        assert!(describe_result(Some(3.14159265)).1.contains("3.141593"));
        assert_eq!(describe_result(None).0, "Cancelled");
    }
}
