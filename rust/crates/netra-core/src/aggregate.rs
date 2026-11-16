//! The sums behind the Usage page (Swift `DashboardUsageAggregator`), kept
//! out of the UI so every number on the page is testable.

use chrono::{Days, NaiveDate};

use crate::model::{AgentStat, PeriodRow, UNATTRIBUTED, combine_models_by_name, sort_agents};
use crate::palette;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum UsageRange {
    Today,
    #[default]
    SevenDays,
    ThirtyDays,
    NinetyDays,
}

impl UsageRange {
    pub const ALL: [UsageRange; 4] = [Self::Today, Self::SevenDays, Self::ThirtyDays, Self::NinetyDays];

    pub fn day_count(self) -> u64 {
        match self {
            Self::Today => 1,
            Self::SevenDays => 7,
            Self::ThirtyDays => 30,
            Self::NinetyDays => 90,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Today => "Today",
            Self::SevenDays => "7d",
            Self::ThirtyDays => "30d",
            Self::NinetyDays => "90d",
        }
    }

    pub fn caption(self) -> &'static str {
        match self {
            Self::Today => "Today",
            Self::SevenDays => "Last 7 days",
            Self::ThirtyDays => "Last 30 days",
            Self::NinetyDays => "Last 90 days",
        }
    }

    /// How the previous equal-length window is named in comparisons.
    pub fn previous_caption(self) -> &'static str {
        match self {
            Self::Today => "yesterday",
            Self::SevenDays => "previous 7 days",
            Self::ThirtyDays => "previous 30 days",
            Self::NinetyDays => "previous 90 days",
        }
    }
}

/// The recorded days inside a range, plus their total.
#[derive(Debug, Clone, PartialEq)]
pub struct Selection {
    pub start: NaiveDate,
    pub end: NaiveDate,
    /// Recorded days only, oldest first. Days without usage are absent.
    pub rows: Vec<PeriodRow>,
    pub total: PeriodRow,
}

impl Selection {
    /// Every day in the range, oldest first, with the recorded row if any.
    /// Charts use this so idle days still take a slot.
    pub fn each_day(&self) -> Vec<(NaiveDate, Option<&PeriodRow>)> {
        self.start
            .iter_days()
            .take_while(|d| *d <= self.end)
            .map(|d| (d, self.rows.iter().find(|r| r.date == d)))
            .collect()
    }
}

/// Days inside `range` ending on `today`, `periods_back` whole ranges ago
/// (1 = the equal-length window just before).
pub fn selection(rows: &[PeriodRow], range: UsageRange, periods_back: u64, today: NaiveDate) -> Selection {
    let n = range.day_count();
    let end = today.checked_sub_days(Days::new(n * periods_back)).unwrap_or(today);
    let start = end.checked_sub_days(Days::new(n - 1)).unwrap_or(end);
    let picked: Vec<PeriodRow> = rows.iter().filter(|r| r.date >= start && r.date <= end).cloned().collect();
    let total = aggregate(&picked, range.label(), start);
    Selection { start, end, rows: picked, total }
}

/// Sums rows into one, merging each agent's models by name.
pub fn aggregate(rows: &[PeriodRow], period: &str, date: NaiveDate) -> PeriodRow {
    let mut agents: Vec<AgentStat> = Vec::new();
    for agent in rows.iter().flat_map(|r| &r.agents) {
        if let Some(total) = agents.iter_mut().find(|a| a.name == agent.name) {
            total.cost += agent.cost;
            total.total_tokens += agent.total_tokens;
            total.input_tokens += agent.input_tokens;
            total.output_tokens += agent.output_tokens;
            total.cache_creation_tokens += agent.cache_creation_tokens;
            total.cache_read_tokens += agent.cache_read_tokens;
            total.models = combine_models_by_name(total.models.iter().chain(&agent.models));
        } else {
            agents.push(agent.clone());
        }
    }
    sort_agents(&mut agents);

    let unattributed: Vec<&AgentStat> = rows.iter().filter_map(|r| r.unattributed.as_ref()).collect();
    let unattributed = (!unattributed.is_empty()).then(|| AgentStat {
        name: UNATTRIBUTED.into(),
        cost: unattributed.iter().map(|a| a.cost).sum(),
        total_tokens: unattributed.iter().map(|a| a.total_tokens).sum(),
        input_tokens: unattributed.iter().map(|a| a.input_tokens).sum(),
        output_tokens: unattributed.iter().map(|a| a.output_tokens).sum(),
        cache_creation_tokens: unattributed.iter().map(|a| a.cache_creation_tokens).sum(),
        cache_read_tokens: unattributed.iter().map(|a| a.cache_read_tokens).sum(),
        models: combine_models_by_name(unattributed.iter().flat_map(|a| &a.models)),
    });

    PeriodRow {
        period: period.into(),
        date,
        cost: rows.iter().map(|r| r.cost).sum(),
        input_tokens: rows.iter().map(|r| r.input_tokens).sum(),
        output_tokens: rows.iter().map(|r| r.output_tokens).sum(),
        cache_creation_tokens: rows.iter().map(|r| r.cache_creation_tokens).sum(),
        cache_read_tokens: rows.iter().map(|r| r.cache_read_tokens).sum(),
        total_tokens: rows.iter().map(|r| r.total_tokens).sum(),
        agents,
        unattributed,
        models: combine_models_by_name(rows.iter().flat_map(|r| &r.models)),
    }
}

/// One model line in the breakdown, attributed to the agent that ran it.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelRow {
    pub provider: String,
    pub name: String,
    pub cost: f64,
    pub tokens: u64,
}

/// Models attributed to their agent. Model usage the agents don't account for
/// is kept as an `other` line so totals still add up.
pub fn model_rows(row: &PeriodRow) -> Vec<ModelRow> {
    let agent_models: Vec<ModelRow> = row
        .agents
        .iter()
        .flat_map(|agent| {
            agent.models.iter().map(|m| ModelRow {
                provider: agent.name.clone(),
                name: m.name.clone(),
                cost: m.cost,
                tokens: m.total_tokens,
            })
        })
        .collect();

    let mut rows = agent_models.clone();
    for model in &row.models {
        let attributed = agent_models.iter().filter(|r| r.name == model.name);
        let (cost, tokens) = attributed.fold((0.0, 0u64), |(c, t), r| (c + r.cost, t + r.tokens));
        let residual_cost = (model.cost - cost).max(0.0);
        let residual_tokens = model.total_tokens.saturating_sub(tokens);
        if residual_cost > 0.000_001 || residual_tokens > 0 {
            let provider = if agent_models.is_empty() {
                palette::provider_for_model(&model.name).unwrap_or(UNATTRIBUTED)
            } else {
                UNATTRIBUTED
            };
            rows.push(ModelRow {
                provider: provider.into(),
                name: model.name.clone(),
                cost: residual_cost,
                tokens: residual_tokens,
            });
        }
    }

    let mut combined: Vec<ModelRow> = Vec::new();
    for row in rows {
        if let Some(existing) = combined.iter_mut().find(|r| r.provider == row.provider && r.name == row.name) {
            existing.cost += row.cost;
            existing.tokens += row.tokens;
        } else {
            combined.push(row);
        }
    }
    combined.sort_by(|a, b| b.cost.total_cmp(&a.cost).then(b.tokens.cmp(&a.tokens)).then(a.name.cmp(&b.name)));
    combined
}

/// Share of all input tokens (uncached + cache writes + cache reads) that was
/// served from cache.
pub fn cache_hit_rate(row: &PeriodRow) -> f64 {
    let input = row.input_tokens + row.cache_creation_tokens + row.cache_read_tokens;
    if input == 0 { 0.0 } else { row.cache_read_tokens as f64 / input as f64 }
}

/// Relative change from `previous` to `current`; `None` without a baseline.
pub fn change(previous: f64, current: f64) -> Option<f64> {
    (previous > 0.0).then(|| (current - previous) / previous)
}

/// One slice of the token-composition bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenPart {
    CacheReads,
    UncachedInput,
    CacheWrites,
    Output,
    /// Totals above the four standard parts (e.g. reasoning tokens).
    Other,
}

impl TokenPart {
    pub fn label(self) -> &'static str {
        match self {
            Self::CacheReads => "Cache reads",
            Self::UncachedInput => "Uncached input",
            Self::CacheWrites => "Cache writes",
            Self::Output => "Output",
            Self::Other => "Other (e.g. reasoning)",
        }
    }
}

pub fn token_parts(row: &PeriodRow) -> Vec<(TokenPart, u64)> {
    let mut parts = vec![
        (TokenPart::CacheReads, row.cache_read_tokens),
        (TokenPart::UncachedInput, row.input_tokens),
        (TokenPart::CacheWrites, row.cache_creation_tokens),
        (TokenPart::Output, row.output_tokens),
    ];
    let known: u64 = parts.iter().map(|p| p.1).sum();
    if row.total_tokens > known {
        parts.push((TokenPart::Other, row.total_tokens - known));
    }
    parts
}
