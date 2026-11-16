//! Number and age formatting shared by every view (Swift `Format`).

use chrono::{DateTime, Utc};

/// "$4.20" under $100, "$182" from there.
pub fn cost(value: f64) -> String {
    if value >= 100.0 { format!("${value:.0}") } else { format!("${value:.2}") }
}

/// Usage with tokens but no price has no known price: show "—", not "$0.00".
pub fn provider_cost(cost_value: f64, tokens: u64) -> String {
    if is_unpriced(cost_value, tokens) { "—".into() } else { cost(cost_value) }
}

pub fn is_unpriced(cost_value: f64, tokens: u64) -> bool {
    cost_value < 0.000_05 && tokens > 0
}

/// Percent-of-own-peak values can pass 100%; then read as a multiplier.
pub fn peak_percent(value: f64) -> String {
    if value <= 100.0 { format!("{}%", value.round() as i64) } else { format!("{:.1}×", value / 100.0) }
}

/// "812", "64K", "1.2M", "3.4B". Thresholds sit where rounding would roll over.
pub fn tokens(value: u64) -> String {
    let v = value as f64;
    if v >= 999_950_000.0 {
        format!("{:.1}B", v / 1e9)
    } else if v >= 999_500.0 {
        format!("{:.1}M", v / 1e6)
    } else if v >= 1_000.0 {
        format!("{:.0}K", v / 1e3)
    } else {
        value.to_string()
    }
}

/// "42%", for shares and rates in `0...1`.
pub fn percent(fraction: f64, decimals: usize) -> String {
    format!("{:.*}%", decimals, fraction * 100.0)
}

/// "just now", "12s ago", "5m ago", "3h ago", "4d ago".
pub fn age(since: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let s = (now - since).num_seconds();
    match s {
        ..5 => "just now".into(),
        5..60 => format!("{s}s ago"),
        60..3_600 => format!("{}m ago", s / 60),
        3_600..172_800 => format!("{}h ago", s / 3_600),
        _ => format!("{}d ago", s / 86_400),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_roll_over_at_rounding_thresholds() {
        assert_eq!(tokens(999), "999");
        assert_eq!(tokens(64_400), "64K");
        assert_eq!(tokens(999_499), "999K");
        assert_eq!(tokens(999_500), "1.0M");
        assert_eq!(tokens(64_836_184), "64.8M");
        assert_eq!(tokens(999_950_000), "1.0B");
    }

    #[test]
    fn costs_and_peaks() {
        assert_eq!(cost(37.018), "$37.02");
        assert_eq!(cost(181.75), "$182");
        assert_eq!(provider_cost(0.0, 10), "—");
        assert_eq!(provider_cost(0.0, 0), "$0.00");
        assert_eq!(peak_percent(71.7), "72%");
        assert_eq!(peak_percent(1223.0), "12.2×");
    }
}
