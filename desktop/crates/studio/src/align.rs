use berms_footage::Clip;
use berms_rides::RideSegment;
use time::Duration;

pub fn matches(clip: &Clip, segment: &RideSegment, offset: Duration) -> bool {
    let Some(start) = clip.recorded_at else {
        return false;
    };
    let end = start + clip.duration;
    segment.overlaps(start + offset, end + offset)
}

pub fn matching_clips(clips: &[Clip], segment: &RideSegment, offset: Duration) -> Vec<usize> {
    clips
        .iter()
        .enumerate()
        .filter(|(_, clip)| matches(clip, segment, offset))
        .map(|(ix, _)| ix)
        .collect()
}

pub fn unmatched_clips<'a>(
    clips: &[Clip],
    segments: impl Iterator<Item = &'a RideSegment>,
    offset: Duration,
) -> Vec<usize> {
    let segments: Vec<&RideSegment> = segments.collect();
    clips
        .iter()
        .enumerate()
        .filter(|(_, clip)| {
            !segments
                .iter()
                .any(|segment| matches(clip, segment, offset))
        })
        .map(|(ix, _)| ix)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use berms_footage::ClipPart;
    use berms_rides::Export;
    use time::Duration;

    use crate::test_data;

    fn runs() -> Vec<RideSegment> {
        Export::from_json(test_data::EXPORT_JSON).unwrap().days()[0]
            .runs()
            .cloned()
            .collect()
    }

    #[test]
    fn overlapping_clip_matches_run() {
        let runs = runs();
        assert!(matches(
            &test_data::clip("2026-09-06T15:17:00Z", 120.0),
            &runs[0],
            Duration::ZERO
        ));
    }

    #[test]
    fn distant_clip_needs_a_clock_shift() {
        let runs = runs();
        let clip = test_data::clip("2026-09-06T15:20:00Z", 60.0);
        assert!(!matches(&clip, &runs[0], Duration::ZERO));
        assert!(matches(&clip, &runs[0], Duration::minutes(-8)));
    }

    #[test]
    fn clip_without_timestamp_never_matches() {
        let runs = runs();
        let clip = Clip::new(
            "clip.MP4",
            vec![ClipPart::new("clip.MP4", 0, None, Duration::seconds(10))],
        );
        assert!(!matches(&clip, &runs[0], Duration::ZERO));
    }

    #[test]
    fn lists_unassigned_clips() {
        let runs = runs();
        let clips = [
            test_data::clip("2026-09-06T15:13:00Z", 60.0),
            test_data::clip("2026-09-06T15:36:00Z", 60.0),
            test_data::clip("2026-09-06T18:00:00Z", 60.0),
        ];

        assert_eq!(matching_clips(&clips, &runs[0], Duration::ZERO), vec![0]);
        assert_eq!(
            unmatched_clips(&clips, runs.iter(), Duration::ZERO),
            vec![2]
        );
    }
}
