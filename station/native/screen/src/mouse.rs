// Where SendInput puts the pointer and how far it moves it, as numbers (input.rs posts them).

/// A pixel of the virtual desktop as MOUSEEVENTF_ABSOLUTE's 0..65535: Windows takes `n` back as
/// `origin + floor(n * extent / 65536)`, so the least `n` that lands on it: `ceil(rel * 65536 / extent)`, `rel` the
/// pixel's offset (a fraction floored to the pixel it is in: rounded, -0.000001 would land on the display beside).
pub fn absolute(pixel: f64, origin: i32, extent: i32) -> i32 {
    if extent <= 0 || !pixel.is_finite() {
        return 0;
    }
    let rel = (pixel.floor() as i64 - origin as i64).clamp(0, extent as i64 - 1);
    ((rel * 65536 + extent as i64 - 1) / extent as i64).clamp(0, 65535) as i32
}

/// What of a pixel an axis's relative moves left over: each goes as whole pixels, rounded with what the ones before
/// left, so many slow moves add up to all of theirs.
#[derive(Default)]
pub struct Carry {
    rest: f64,
}

impl Carry {
    pub fn take(&mut self, v: f64) -> i32 {
        let v = if v.is_finite() { v } else { 0.0 };
        let whole = (self.rest + v).round();
        self.rest += v - whole;
        whole as i32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What Windows makes of `n`.
    fn back(n: i32, origin: i32, extent: i32) -> i64 {
        origin as i64 + (n as i64 * extent as i64) / 65536
    }

    #[test]
    fn each_pixel_is_landed_on_as_it_is() {
        for (origin, extent) in [(0, 1920), (-1920, 3840), (0, 7), (100, 65536)] {
            for p in [origin, origin + 1, origin + extent / 2, origin + extent - 1] {
                assert_eq!(back(absolute(p as f64, origin, extent), origin, extent), p as i64, "{origin} {extent} {p}");
            }
        }
    }

    #[test]
    fn a_fraction_is_its_pixel_and_outside_is_the_edge() {
        assert_eq!(absolute(-0.000001, 0, 1920), 0);
        assert_eq!(back(absolute(1919.9, 0, 1920), 0, 1920), 1919);
        assert_eq!(back(absolute(5000.0, 0, 1920), 0, 1920), 1919);
        assert_eq!(absolute(f64::NAN, 0, 1920), 0);
    }

    #[test]
    fn slow_moves_add_up() {
        let mut c = Carry::default();
        let sum: i32 = (0..100).map(|_| c.take(0.3)).sum();
        assert_eq!(sum, 30);
        assert_eq!(c.take(f64::INFINITY), 0);
        assert_eq!(c.take(-2.6), -3);
    }
}
