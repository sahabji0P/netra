//! Prints what the dashboard would show, from the live data folder (or
//! `NETRA_DATA_DIR`). A quick check that the core reads the Swift app's files.
//!
//!     cargo run -p netra-core --example summary

use chrono::Utc;
use netra_core::aggregate::{self, UsageRange};
use netra_core::{Library, format, limits, palette, paths, time};

fn main() {
    let dir = paths::data_dir().expect("HOME is set");
    let mut library = Library::new(dir.clone());
    library.apply(Library::poll(&dir, netra_core::library::Held::default()));
    println!("data folder: {}", dir.display());
    println!("history: {:?}, snapshot: {:?}", library.history_status, library.snapshot_status);
    println!("recorded days: {}, engine: {:?}", library.rows.len(), library.engine);

    let today = time::today();
    for range in UsageRange::ALL {
        let current = aggregate::selection(&library.rows, range, 0, today);
        let previous = aggregate::selection(&library.rows, range, 1, today);
        let change = aggregate::change(previous.total.cost, current.total.cost)
            .map(|c| format!("{:+.0}% vs {}", c * 100.0, range.previous_caption()))
            .unwrap_or_default();
        println!(
            "{:>5}: {} · {} tokens · cache {} {}",
            range.label(),
            format::cost(current.total.cost),
            format::tokens(current.total.total_tokens),
            format::percent(aggregate::cache_hit_rate(&current.total), 0),
            change
        );
    }

    if let Some(snapshot) = &library.snapshot {
        let now = Utc::now();
        println!("snapshot taken {}", format::age(snapshot.fetched_at, now));
        for provider in limits::provider_limits(snapshot, &limits::DEFAULT_ORDER, now) {
            println!("{} ({})", palette::display_name(&provider.agent), provider.source);
            for window in &provider.windows {
                let reset = window.resets_at.map(|r| limits::reset_countdown(r, now)).unwrap_or_default();
                println!(
                    "  {:<18} {:>9}  {}",
                    limits::title(&window.label),
                    limits::amount(window, false, provider.is_estimate),
                    reset
                );
            }
        }
    }
}
