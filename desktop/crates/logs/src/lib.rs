use std::io::BufRead;
use std::path::{Path, PathBuf};

use berms_rides::{Export, Jump, RideDay, RideSegment, RoutePoint, SegmentKind, Timestamp};
use time::Duration;

use record::Record;

mod record;
mod route;

#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    #[error("couldn't read {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid diagnostics line {line} in {path}: {source}")]
    Line {
        path: PathBuf,
        line: usize,
        #[source]
        source: serde_json::Error,
    },
}

pub fn load_days(paths: &[PathBuf]) -> Result<Export, Error> {
    let mut days = Vec::new();
    for path in paths {
        days.push(load_day(path)?);
    }
    Ok(Export::from_days(days))
}

pub fn load_day(path: &Path) -> Result<RideDay, Error> {
    let file = std::fs::File::open(path).map_err(|source| Error::Read {
        path: path.to_path_buf(),
        source,
    })?;

    let id = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "day".to_owned());

    parse(std::io::BufReader::new(file), id, path)
}

fn parse(reader: impl BufRead, id: String, path: &Path) -> Result<RideDay, Error> {
    let mut assembly = Assembly::new(id);

    for (ix, line) in reader.lines().enumerate() {
        let line = line.map_err(|source| Error::Read {
            path: path.to_path_buf(),
            source,
        })?;
        if line.trim().is_empty() {
            continue;
        }
        let record: Record = serde_json::from_str(&line).map_err(|source| Error::Line {
            path: path.to_path_buf(),
            line: ix + 1,
            source,
        })?;
        assembly.push(record);
    }

    Ok(assembly.finish())
}

struct Assembly {
    id: String,
    started_at: Option<Timestamp>,
    ended_at: Option<Timestamp>,
    last_seen: Option<Timestamp>,
    segments: Vec<RideSegment>,
    open: Option<OpenSegment>,
    next_run_number: usize,
}

struct OpenSegment {
    kind: SegmentKind,
    started_at: Timestamp,
    run_number: Option<usize>,
    route: Vec<RoutePoint>,
    jumps: Vec<Jump>,
}

impl Assembly {
    fn new(id: String) -> Self {
        Self {
            id,
            started_at: None,
            ended_at: None,
            last_seen: None,
            segments: Vec::new(),
            open: None,
            next_run_number: 1,
        }
    }

    fn push(&mut self, record: Record) {
        if let Some(timestamp) = record.timestamp() {
            self.last_seen = Some(timestamp);
        }

        match record {
            Record::SessionStarted { timestamp } => {
                self.started_at.get_or_insert(timestamp);
            }
            Record::SessionStopped { timestamp } => self.ended_at = Some(timestamp),
            Record::DetectorStarted {
                timestamp,
                detail,
                run_number,
            } => {
                self.close(timestamp);
                let kind = kind_from_detail(&detail);
                let run_number = if kind == SegmentKind::Run {
                    let number = run_number.unwrap_or(self.next_run_number);
                    self.next_run_number = self.next_run_number.max(number + 1);
                    Some(number)
                } else {
                    None
                };
                self.open = Some(OpenSegment {
                    kind,
                    started_at: timestamp,
                    run_number,
                    route: Vec::new(),
                    jumps: Vec::new(),
                });
            }
            Record::DetectorFinished {
                timestamp,
                run_number,
            } => {
                if let Some(number) = run_number {
                    if let Some(open) = &mut self.open
                        && open.kind == SegmentKind::Run
                    {
                        open.run_number = Some(number);
                    }
                    self.next_run_number = self.next_run_number.max(number + 1);
                }
                self.close(timestamp);
            }
            Record::GpsRaw {
                timestamp,
                latitude,
                longitude,
                altitude,
                speed,
            } => {
                if let Some(open) = &mut self.open {
                    open.route.push(RoutePoint::new(
                        latitude,
                        longitude,
                        altitude,
                        speed.max(0.0),
                        timestamp,
                    ));
                }
            }
            Record::JumpDetected {
                timestamp,
                accepted,
                airtime_seconds,
            } => {
                if accepted && let Some(open) = &mut self.open {
                    let airtime = Duration::seconds_f64(airtime_seconds.max(0.0));
                    open.jumps.push(Jump::new(
                        timestamp - airtime,
                        timestamp,
                        airtime.as_seconds_f64(),
                    ));
                }
            }
            Record::Other => {}
        }
    }

    fn close(&mut self, ended_at: Timestamp) {
        let Some(open) = self.open.take() else {
            return;
        };
        if open.route.is_empty() {
            return;
        }

        let distance = route::distance_meters(&open.route);
        let vertical = match open.kind {
            SegmentKind::Run => route::descent_meters(&open.route),
            SegmentKind::Lift => -route::ascent_meters(&open.route),
            _ => 0.0,
        };
        let maximum_speed = route::maximum_speed(&open.route);

        let segment = RideSegment::new(
            format!("{}-seg-{:02}", self.id, self.segments.len() + 1),
            open.kind,
            open.started_at,
            ended_at.max(open.started_at),
        )
        .with_route(open.route)
        .with_jumps(open.jumps)
        .with_distance_meters(distance)
        .with_vertical_meters(vertical)
        .with_maximum_speed_meters_per_second(maximum_speed);
        self.segments.push(match open.run_number {
            Some(number) => segment.with_run_number(number),
            None => segment,
        });
    }

    fn finish(mut self) -> RideDay {
        if let Some(last_seen) = self.last_seen {
            self.close(last_seen);
        }

        let started_at = self
            .started_at
            .or_else(|| self.segments.first().map(|segment| segment.started_at))
            .unwrap_or(Timestamp::UNIX_EPOCH);

        let mut day = RideDay::new(self.id, started_at).with_segments(self.segments);
        if let Some(ended_at) = self.ended_at {
            day = day.with_ended_at(ended_at);
        }
        day
    }
}

fn kind_from_detail(detail: &str) -> SegmentKind {
    if detail.eq_ignore_ascii_case("run") {
        SegmentKind::Run
    } else if detail.eq_ignore_ascii_case("lift") {
        SegmentKind::Lift
    } else {
        SegmentKind::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOG: &str = r#"{"kind":"session_started","timestamp":"2026-09-13T19:08:36Z"}
{"kind":"detector_started","timestamp":"2026-09-13T19:08:36Z","detail":"Lift"}
{"kind":"gps_raw","timestamp":"2026-09-13T19:08:40Z","latitude":41.190,"longitude":-74.500,"gpsAltitude":148.0,"speed":-1}
{"kind":"detector_finished","timestamp":"2026-09-13T19:13:47Z"}
{"kind":"detector_started","timestamp":"2026-09-13T19:14:41Z","detail":"Run"}
{"kind":"gps_raw","timestamp":"2026-09-13T19:14:45Z","latitude":41.191,"longitude":-74.500,"gpsAltitude":140.0,"speed":8.5}
{"kind":"jump_detected","timestamp":"2026-09-13T19:15:05Z","accepted":true,"jumpAirtime":0.32}
{"kind":"gps_raw","timestamp":"2026-09-13T19:24:50Z","latitude":41.192,"longitude":-74.500,"gpsAltitude":120.0,"speed":11.0}
{"kind":"memory_footprint","timestamp":"2026-09-13T19:20:00Z","footprint_mb":120}
{"kind":"detector_finished","timestamp":"2026-09-13T19:25:18Z"}
{"kind":"session_stopped","timestamp":"2026-09-13T22:09:14Z"}
"#;

    fn day() -> RideDay {
        parse(LOG.as_bytes(), "day-1".to_owned(), Path::new("<memory>")).unwrap()
    }

    #[test]
    fn builds_segments_from_detector_events() {
        let day = day();
        assert_eq!(day.segments.len(), 2);
        assert_eq!(day.run_count(), 1);
        assert_eq!(day.segments[0].kind, SegmentKind::Lift);
        assert_eq!(day.segments[1].kind, SegmentKind::Run);
        assert!(day.ended_at.is_some());
    }

    #[test]
    fn collects_route_jumps_and_stats() {
        let day = day();
        let run = day.runs().next().unwrap();
        assert_eq!(run.route.len(), 2);
        assert_eq!(run.jumps.len(), 1);
        assert!((run.jumps[0].airtime_seconds - 0.32).abs() < f64::EPSILON);
        assert!(run.distance_meters > 100.0);
        assert!(run.vertical_meters > 0.0, "runs report descent");
        assert!((run.maximum_speed_meters_per_second - 11.0).abs() < f64::EPSILON);
        assert!(day.segments[0].vertical_meters <= 0.0, "lifts report climb");
    }

    #[test]
    fn ignores_unknown_records() {
        let day = day();
        assert_eq!(day.segments.len(), 2, "memory_footprint is not a segment");
    }
}
