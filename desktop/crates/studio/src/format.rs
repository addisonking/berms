use time::{Duration, OffsetDateTime, UtcOffset, macros::format_description};

fn local(time: OffsetDateTime) -> OffsetDateTime {
    time.to_offset(UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC))
}

pub fn clock(time: Option<OffsetDateTime>) -> String {
    let Some(time) = time else {
        return "no timestamp".to_owned();
    };
    local(time)
        .format(&format_description!("[hour]:[minute]"))
        .unwrap_or_default()
}

pub fn clock_range(start: OffsetDateTime, end: OffsetDateTime) -> String {
    format!("{}–{}", clock(Some(start)), clock(Some(end)))
}

pub fn day_label(time: OffsetDateTime) -> String {
    local(time)
        .format(&format_description!(
            "[weekday repr:short] [month repr:short] [day padding:none]"
        ))
        .unwrap_or_default()
}

pub fn duration(value: Duration) -> String {
    let total = value.whole_seconds().max(0);
    let hours = total / 3600;
    let minutes = (total % 3600) / 60;
    let seconds = total % 60;
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}

pub fn distance(meters: f64) -> String {
    if meters >= 1000.0 {
        format!("{:.1} km", meters / 1000.0)
    } else {
        format!("{meters:.0} m")
    }
}

pub fn vertical(meters: f64) -> String {
    format!("{meters:.0} m")
}

pub fn speed(meters_per_second: f64) -> String {
    format!("{:.0} km/h", meters_per_second * 3.6)
}

pub fn offset(seconds: i64) -> String {
    let sign = if seconds < 0 { "-" } else { "+" };
    let total = seconds.abs();
    format!("{sign}{}:{:02}", total / 60, total % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_durations() {
        assert_eq!(duration(Duration::seconds(75)), "1:15");
        assert_eq!(duration(Duration::seconds(3675)), "1:01:15");
    }

    #[test]
    fn formats_offsets() {
        assert_eq!(offset(0), "+0:00");
        assert_eq!(offset(-90), "-1:30");
        assert_eq!(offset(3660), "+61:00");
    }
}
