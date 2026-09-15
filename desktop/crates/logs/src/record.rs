use berms_rides::Timestamp;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum Record {
    SessionStarted {
        #[serde(with = "time::serde::rfc3339")]
        timestamp: Timestamp,
    },
    SessionStopped {
        #[serde(with = "time::serde::rfc3339")]
        timestamp: Timestamp,
    },
    DetectorStarted {
        #[serde(with = "time::serde::rfc3339")]
        timestamp: Timestamp,
        detail: String,
        #[serde(default, rename = "runNumber")]
        run_number: Option<usize>,
    },
    DetectorFinished {
        #[serde(with = "time::serde::rfc3339")]
        timestamp: Timestamp,
        #[serde(default, rename = "runNumber")]
        run_number: Option<usize>,
    },
    GpsRaw {
        #[serde(with = "time::serde::rfc3339")]
        timestamp: Timestamp,
        latitude: f64,
        longitude: f64,
        #[serde(rename = "gpsAltitude", default)]
        altitude: f64,
        #[serde(default)]
        speed: f64,
    },
    JumpDetected {
        #[serde(with = "time::serde::rfc3339")]
        timestamp: Timestamp,
        #[serde(default)]
        accepted: bool,
        #[serde(rename = "jumpAirtime", default)]
        airtime_seconds: f64,
    },
    #[serde(other)]
    Other,
}

impl Record {
    pub(crate) fn timestamp(&self) -> Option<Timestamp> {
        match self {
            Self::SessionStarted { timestamp }
            | Self::SessionStopped { timestamp }
            | Self::DetectorStarted { timestamp, .. }
            | Self::DetectorFinished { timestamp, .. }
            | Self::GpsRaw { timestamp, .. }
            | Self::JumpDetected { timestamp, .. } => Some(*timestamp),
            Self::Other => None,
        }
    }
}
