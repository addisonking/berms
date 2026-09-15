use std::path::PathBuf;

use berms_footage::Clip;
use berms_rides::{Export, RideDay, RideSegment};
use time::Duration;

use crate::{align, format, run_list::RunEntry};

pub struct Library {
    export: Option<Export>,
    clips: Vec<Clip>,
    footage_root: Option<PathBuf>,
    offset_seconds: i64,
}

impl Library {
    pub fn new() -> Self {
        Self {
            export: None,
            clips: Vec::new(),
            footage_root: None,
            offset_seconds: 0,
        }
    }

    pub fn set_footage(&mut self, root: PathBuf, clips: Vec<Clip>) -> usize {
        self.footage_root = Some(root);
        self.clips = clips;
        self.clips.len()
    }

    pub fn set_export(&mut self, export: Export) -> usize {
        self.export = Some(export);
        self.run_count()
    }

    pub fn shift_clock(&mut self, delta_seconds: i64) {
        self.offset_seconds += delta_seconds;
    }

    pub fn offset_seconds(&self) -> i64 {
        self.offset_seconds
    }

    fn offset(&self) -> Duration {
        Duration::seconds(self.offset_seconds)
    }

    pub fn footage_root(&self) -> Option<&std::path::Path> {
        self.footage_root.as_deref()
    }

    pub fn clips(&self) -> &[Clip] {
        &self.clips
    }

    pub fn run_count(&self) -> usize {
        self.runs().count()
    }

    pub fn clip_count(&self) -> usize {
        self.clips.len()
    }

    pub fn entries(&self) -> Vec<RunEntry> {
        let mut entries = Vec::new();
        let Some(export) = &self.export else {
            return entries;
        };

        for day in export.days() {
            for (ix, segment) in day.runs().enumerate() {
                let run_number = segment.run_number.unwrap_or(ix + 1);
                let clip_count = self.matching_clips(segment).len();
                entries.push(RunEntry {
                    day_id: day.id.clone(),
                    segment_id: segment.id.clone(),
                    title: segment.title().into(),
                    subtitle: subtitle(day, segment, run_number, clip_count).into(),
                    run_number,
                });
            }
        }
        entries
    }

    pub fn unmatched_count(&self) -> usize {
        align::unmatched_clips(&self.clips, self.runs(), self.offset()).len()
    }

    pub fn unmatched_clips(&self) -> Vec<&Clip> {
        align::unmatched_clips(&self.clips, self.runs(), self.offset())
            .into_iter()
            .map(|ix| &self.clips[ix])
            .collect()
    }

    pub fn matching_clips(&self, segment: &RideSegment) -> Vec<usize> {
        align::matching_clips(&self.clips, segment, self.offset())
    }

    pub fn footage_for(&self, entry: &RunEntry) -> Vec<Clip> {
        let Some(segment) = self.find_segment(entry) else {
            return Vec::new();
        };
        self.matching_clips(segment)
            .into_iter()
            .map(|ix| self.clips[ix].clone())
            .collect()
    }

    pub fn find_segment(&self, entry: &RunEntry) -> Option<&RideSegment> {
        self.export
            .as_ref()?
            .days()
            .iter()
            .find(|day| day.id == entry.day_id)?
            .segments
            .iter()
            .find(|segment| segment.id == entry.segment_id)
    }

    fn runs(&self) -> impl Iterator<Item = &RideSegment> {
        self.export
            .iter()
            .flat_map(Export::days)
            .flat_map(RideDay::runs)
    }
}

fn subtitle(day: &RideDay, segment: &RideSegment, run_number: usize, clip_count: usize) -> String {
    let clips = match clip_count {
        1 => "1 clip".to_owned(),
        count => format!("{count} clips"),
    };
    format!(
        "{} · run {} · {} · {}",
        format::day_label(day.started_at),
        run_number,
        format::clock_range(segment.started_at, segment.ended_at),
        clips
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_data;

    fn loaded() -> Library {
        let mut library = Library::new();
        library.set_export(Export::from_json(test_data::EXPORT_JSON).unwrap());
        library.set_footage(
            PathBuf::from("/footage"),
            vec![
                test_data::clip("2026-09-06T15:13:00Z", 60.0),
                test_data::clip("2026-09-06T15:36:00Z", 60.0),
                test_data::clip("2026-09-06T18:00:00Z", 60.0),
            ],
        );
        library
    }

    #[test]
    fn counts_runs_and_clips() {
        let library = loaded();
        assert_eq!(library.run_count(), 2, "lift is not a run");
        assert_eq!(library.clip_count(), 3);
    }

    #[test]
    fn entries_carry_run_identity() {
        let entries = loaded().entries();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].run_number, 1);
        assert!(entries[0].title.contains("Kamikaze"));
        assert!(entries[0].subtitle.contains("1 clip"));
        assert!(entries[1].subtitle.contains("1 clip"));
    }

    #[test]
    fn clock_shift_reassigns_clips() {
        let mut library = Library::new();
        library.set_export(Export::from_json(test_data::EXPORT_JSON).unwrap());
        library.set_footage(
            PathBuf::from("/footage"),
            vec![test_data::clip("2026-09-06T15:28:00Z", 60.0)],
        );

        assert_eq!(library.unmatched_count(), 1);
        library.shift_clock(8 * 60);
        assert_eq!(library.unmatched_count(), 0);

        let entries = library.entries();
        assert_eq!(library.footage_for(&entries[1]).len(), 1);
    }

    #[test]
    fn footage_for_selected_run_is_ordered() {
        let library = loaded();
        let entries = library.entries();
        let footage = library.footage_for(&entries[0]);
        assert_eq!(footage.len(), 1);
    }
}
