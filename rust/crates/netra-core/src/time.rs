//! Dates as the Swift app stores them.
//!
//! Swift's `JSONEncoder` writes a `Date` as seconds since 2001-01-01 UTC
//! (Apple's reference date), as an integer or a float. Day keys in the history
//! are local calendar days, `yyyy-MM-dd`.

use chrono::{DateTime, Local, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Deserializer};

/// Seconds between the Unix epoch and 2001-01-01 00:00:00 UTC.
pub const APPLE_REFERENCE_OFFSET: f64 = 978_307_200.0;

pub fn from_apple_seconds(seconds: f64) -> Option<DateTime<Utc>> {
    if !seconds.is_finite() {
        return None;
    }
    let unix = seconds + APPLE_REFERENCE_OFFSET;
    let whole = unix.floor();
    let nanos = ((unix - whole) * 1e9).round().min(999_999_999.0) as u32;
    Utc.timestamp_opt(whole as i64, nanos).single()
}

pub fn to_apple_seconds(date: DateTime<Utc>) -> f64 {
    date.timestamp() as f64 + f64::from(date.timestamp_subsec_nanos()) / 1e9 - APPLE_REFERENCE_OFFSET
}

/// `yyyy-MM-dd` → a calendar day; anything else is not a day key.
pub fn parse_day(key: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(key, "%Y-%m-%d").ok()
}

/// Today's local calendar day.
pub fn today() -> NaiveDate {
    Local::now().date_naive()
}

/// Serde adapters for Apple reference-date fields.
pub mod apple_date {
    use super::*;

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let seconds = f64::deserialize(d)?;
        from_apple_seconds(seconds).ok_or_else(|| serde::de::Error::custom("date out of range"))
    }

    pub mod option {
        use super::*;

        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
            Ok(Option::<f64>::deserialize(d)?.and_then(from_apple_seconds))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apple_reference_date_round_trips() {
        let date = from_apple_seconds(0.0).unwrap();
        assert_eq!(date.to_rfc3339(), "2001-01-01T00:00:00+00:00");
        let later = from_apple_seconds(816_461_773.5).unwrap();
        assert_eq!(later.to_rfc3339(), "2026-11-15T18:56:13.500+00:00");
        assert!((to_apple_seconds(later) - 816_461_773.5).abs() < 1e-6);
    }

    #[test]
    fn only_full_day_keys_parse() {
        assert_eq!(parse_day("2026-11-16"), NaiveDate::from_ymd_opt(2026, 11, 16));
        assert_eq!(parse_day("2026-11"), None);
        assert_eq!(parse_day("other"), None);
    }
}
