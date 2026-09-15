use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use time::{Duration, OffsetDateTime, serde::rfc3339};

pub type Timestamp = OffsetDateTime;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Export {
    pub version: u32,
    #[serde(with = "rfc3339")]
    pub exported_at: Timestamp,
    #[serde(default)]
    pub days: Vec<RideDay>,
}

impl Export {
    pub fn load(path: &Path) -> Result<Self, Error> {
        let data = std::fs::read_to_string(path).map_err(|source| Error::Read {
            path: path.to_path_buf(),
            source,
        })?;
        Self::from_json(&data)
    }

    pub fn from_json(json: &str) -> Result<Self, Error> {
        Ok(serde_json::from_str(json)?)
    }

    pub fn from_days(days: impl IntoIterator<Item = RideDay>) -> Self {
        let mut days: Vec<RideDay> = days.into_iter().collect();
        days.sort_by_key(|day| day.started_at);
        Self {
            version: 1,
            exported_at: OffsetDateTime::now_utc(),
            days,
        }
    }

    pub fn days(&self) -> &[RideDay] {
        &self.days
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct RideDay {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(with = "rfc3339")]
    pub started_at: Timestamp,
    #[serde(default, with = "rfc3339::option")]
    pub ended_at: Option<Timestamp>,
    #[serde(default)]
    pub segments: Vec<RideSegment>,
}

impl RideDay {
    pub fn new(id: impl Into<String>, started_at: Timestamp) -> Self {
        Self {
            id: id.into(),
            name: None,
            notes: None,
            started_at,
            ended_at: None,
            segments: Vec::new(),
        }
    }

    pub fn with_name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }

    pub fn with_ended_at(mut self, ended_at: Timestamp) -> Self {
        self.ended_at = Some(ended_at);
        self
    }

    pub fn with_segments(mut self, segments: Vec<RideSegment>) -> Self {
        self.segments = segments;
        self
    }

    pub fn runs(&self) -> impl Iterator<Item = &RideSegment> {
        self.segments
            .iter()
            .filter(|segment| segment.kind == SegmentKind::Run)
    }

    pub fn run_count(&self) -> usize {
        self.runs().count()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
#[non_exhaustive]
pub enum SegmentKind {
    #[default]
    Run,
    Lift,
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct RideSegment {
    pub id: String,
    #[serde(default)]
    pub kind: SegmentKind,
    #[serde(default)]
    pub run_number: Option<usize>,
    #[serde(with = "rfc3339")]
    pub started_at: Timestamp,
    #[serde(with = "rfc3339")]
    pub ended_at: Timestamp,
    #[serde(default)]
    pub distance_meters: f64,
    #[serde(default)]
    pub vertical_meters: f64,
    #[serde(default)]
    pub maximum_speed_meters_per_second: f64,
    #[serde(default)]
    pub trails: Vec<String>,
    #[serde(default)]
    pub route: Vec<RoutePoint>,
    #[serde(default)]
    pub jumps: Vec<Jump>,
}

impl RideSegment {
    pub fn new(
        id: impl Into<String>,
        kind: SegmentKind,
        started_at: Timestamp,
        ended_at: Timestamp,
    ) -> Self {
        Self {
            id: id.into(),
            kind,
            run_number: None,
            started_at,
            ended_at,
            distance_meters: 0.0,
            vertical_meters: 0.0,
            maximum_speed_meters_per_second: 0.0,
            trails: Vec::new(),
            route: Vec::new(),
            jumps: Vec::new(),
        }
    }

    pub fn with_route(mut self, route: Vec<RoutePoint>) -> Self {
        self.route = route;
        self
    }

    pub fn with_run_number(mut self, run_number: usize) -> Self {
        self.run_number = Some(run_number);
        self
    }

    pub fn with_jumps(mut self, jumps: Vec<Jump>) -> Self {
        self.jumps = jumps;
        self
    }

    pub fn with_trails(mut self, trails: Vec<String>) -> Self {
        self.trails = trails;
        self
    }

    pub fn with_distance_meters(mut self, distance_meters: f64) -> Self {
        self.distance_meters = distance_meters;
        self
    }

    pub fn with_vertical_meters(mut self, vertical_meters: f64) -> Self {
        self.vertical_meters = vertical_meters;
        self
    }

    pub fn with_maximum_speed_meters_per_second(mut self, speed: f64) -> Self {
        self.maximum_speed_meters_per_second = speed;
        self
    }

    pub fn duration(&self) -> Duration {
        self.ended_at - self.started_at
    }

    pub fn title(&self) -> String {
        if self.trails.is_empty() {
            "Untitled run".to_owned()
        } else {
            self.trails.join(" → ")
        }
    }

    pub fn contains(&self, time: Timestamp) -> bool {
        self.started_at <= time && time <= self.ended_at
    }

    pub fn overlaps(&self, start: Timestamp, end: Timestamp) -> bool {
        start < self.ended_at && self.started_at < end
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct RoutePoint {
    pub latitude: f64,
    pub longitude: f64,
    #[serde(default)]
    pub altitude: f64,
    #[serde(default)]
    pub speed: f64,
    #[serde(with = "rfc3339")]
    pub timestamp: Timestamp,
}

impl RoutePoint {
    pub fn new(
        latitude: f64,
        longitude: f64,
        altitude: f64,
        speed: f64,
        timestamp: Timestamp,
    ) -> Self {
        Self {
            latitude,
            longitude,
            altitude,
            speed,
            timestamp,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[non_exhaustive]
pub struct Jump {
    #[serde(with = "rfc3339")]
    pub takeoff_at: Timestamp,
    #[serde(with = "rfc3339")]
    pub landing_at: Timestamp,
    pub airtime_seconds: f64,
}

impl Jump {
    pub fn new(takeoff_at: Timestamp, landing_at: Timestamp, airtime_seconds: f64) -> Self {
        Self {
            takeoff_at,
            landing_at,
            airtime_seconds,
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    #[error("couldn't read {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid export json: {0}")]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/sample-day.json")
    }

    #[test]
    fn parses_sample_export() {
        let export = Export::load(&fixture()).unwrap();
        assert_eq!(export.days().len(), 1);

        let day = &export.days()[0];
        assert_eq!(day.run_count(), 3);

        let runs: Vec<_> = day.runs().collect();
        assert_eq!(runs[0].title(), "Kamikaze");
        assert_eq!(runs[2].trails, ["Twilight Zone", "Lower Twilight"]);
        assert_eq!(runs[2].run_number, Some(3));
        assert!(runs[0].route.len() >= 5);
        assert!(runs[0].contains(runs[0].started_at + Duration::minutes(1)));
        assert!(runs.iter().all(|run| run.kind == SegmentKind::Run));
        assert_eq!(day.segments.len(), 4, "includes the lift");
    }
}
