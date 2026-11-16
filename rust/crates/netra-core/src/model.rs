//! Normalized usage rows, matching the Swift `ModelStat`, `AgentStat` and
//! `PeriodRow` in `Models.swift`. Field names are the persisted JSON keys.

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

/// The agent name for usage a report could not attribute to any agent.
pub const UNATTRIBUTED: &str = "other";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct ModelStat {
    pub name: String,
    pub cost: f64,
    pub total_tokens: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentStat {
    pub name: String,
    pub cost: f64,
    pub total_tokens: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    pub models: Vec<ModelStat>,
}

/// Highest cost first; equal cost falls back to more tokens, then name, so
/// the order never depends on hash iteration.
fn by_cost_desc(a: (f64, u64, &str), b: (f64, u64, &str)) -> std::cmp::Ordering {
    b.0.total_cmp(&a.0).then(b.1.cmp(&a.1)).then(a.2.cmp(b.2))
}

/// Swift's `[ModelStat].combinedByName()`: one entry per model name, summed.
pub fn combine_models_by_name<'a>(models: impl IntoIterator<Item = &'a ModelStat>) -> Vec<ModelStat> {
    let mut combined: Vec<ModelStat> = Vec::new();
    for model in models {
        if let Some(total) = combined.iter_mut().find(|m| m.name == model.name) {
            total.cost += model.cost;
            total.total_tokens += model.total_tokens;
            total.input_tokens += model.input_tokens;
            total.output_tokens += model.output_tokens;
            total.cache_creation_tokens += model.cache_creation_tokens;
            total.cache_read_tokens += model.cache_read_tokens;
        } else {
            combined.push(model.clone());
        }
    }
    combined.sort_by(|a, b| by_cost_desc((a.cost, a.total_tokens, &a.name), (b.cost, b.total_tokens, &b.name)));
    combined
}

pub(crate) fn sort_agents(agents: &mut [AgentStat]) {
    agents.sort_by(|a, b| by_cost_desc((a.cost, a.total_tokens, &a.name), (b.cost, b.total_tokens, &b.name)));
}

/// One day (or one summed range) of usage.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PeriodRow {
    /// The day key (`yyyy-MM-dd`) or a range label.
    pub period: String,
    /// The first day the row covers.
    pub date: NaiveDate,
    pub cost: f64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    pub total_tokens: u64,
    /// Attributed agents, most expensive first. `other` is not among them.
    pub agents: Vec<AgentStat>,
    /// Usage no agent accounts for, if any.
    pub unattributed: Option<AgentStat>,
    /// Every model in the row, attributed or not, combined by name.
    pub models: Vec<ModelStat>,
}

impl PeriodRow {
    /// Swift's `PeriodRow(period:date:parts:)`: row totals include `other`,
    /// the agent list does not.
    pub fn from_parts(period: impl Into<String>, date: NaiveDate, parts: &[AgentStat]) -> Self {
        let mut agents: Vec<AgentStat> = parts.iter().filter(|a| a.name != UNATTRIBUTED).cloned().collect();
        sort_agents(&mut agents);
        PeriodRow {
            period: period.into(),
            date,
            cost: parts.iter().map(|a| a.cost).sum(),
            input_tokens: parts.iter().map(|a| a.input_tokens).sum(),
            output_tokens: parts.iter().map(|a| a.output_tokens).sum(),
            cache_creation_tokens: parts.iter().map(|a| a.cache_creation_tokens).sum(),
            cache_read_tokens: parts.iter().map(|a| a.cache_read_tokens).sum(),
            total_tokens: parts.iter().map(|a| a.total_tokens).sum(),
            agents,
            unattributed: parts.iter().find(|a| a.name == UNATTRIBUTED).cloned(),
            models: combine_models_by_name(parts.iter().flat_map(|a| &a.models)),
        }
    }

    /// Every part that carries usage: the agents plus `other`.
    pub fn parts(&self) -> impl Iterator<Item = &AgentStat> {
        self.agents.iter().chain(self.unattributed.iter())
    }
}
