use berms_footage::{Clip, ClipPart};
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

pub const EXPORT_JSON: &str = r#"{
    "version": 1,
    "exportedAt": "2026-09-14T02:38:37Z",
    "days": [{
        "id": "day-1",
        "startedAt": "2026-09-06T15:05:00Z",
        "endedAt": "2026-09-06T16:05:00Z",
        "segments": [
            {
                "id": "run-1",
                "kind": "run",
                "startedAt": "2026-09-06T15:12:00Z",
                "endedAt": "2026-09-06T15:18:30Z",
                "distanceMeters": 3120.0,
                "verticalMeters": 412.0,
                "maximumSpeedMetersPerSecond": 13.8,
                "trails": ["Kamikaze"]
            },
            {
                "id": "lift-1",
                "kind": "lift",
                "startedAt": "2026-09-06T15:19:00Z",
                "endedAt": "2026-09-06T15:31:00Z"
            },
            {
                "id": "run-2",
                "kind": "run",
                "startedAt": "2026-09-06T15:35:00Z",
                "endedAt": "2026-09-06T15:40:10Z"
            }
        ]
    }]
}"#;

pub fn clip(started_at: &str, seconds: f64) -> Clip {
    let recorded_at = OffsetDateTime::parse(started_at, &Rfc3339).unwrap();
    Clip::new(
        "GH010042.MP4",
        vec![ClipPart::new(
            "GH010042.MP4",
            1,
            Some(recorded_at),
            Duration::seconds_f64(seconds),
        )],
    )
}
