use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

use crate::Error;

#[derive(Clone, Debug)]
#[non_exhaustive]
pub struct Clip {
    pub key: String,
    pub name: String,
    pub parts: Vec<ClipPart>,
    pub recorded_at: Option<OffsetDateTime>,
    pub duration: Duration,
}

impl Clip {
    pub fn new(name: impl Into<String>, parts: Vec<ClipPart>) -> Self {
        let name = name.into();
        let recorded_at = parts.iter().filter_map(|part| part.recorded_at).min();
        let duration = parts.iter().map(|part| part.duration).sum();
        Self {
            key: name.to_ascii_lowercase(),
            name,
            parts,
            recorded_at,
            duration,
        }
    }

    pub fn ended_at(&self) -> Option<OffsetDateTime> {
        self.recorded_at.map(|start| start + self.duration)
    }

    pub fn chapter_count(&self) -> usize {
        self.parts.len()
    }
}

#[derive(Clone, Debug)]
#[non_exhaustive]
pub struct ClipPart {
    pub path: PathBuf,
    pub chapter: u32,
    pub recorded_at: Option<OffsetDateTime>,
    pub duration: Duration,
}

impl ClipPart {
    pub fn new(
        path: impl Into<PathBuf>,
        chapter: u32,
        recorded_at: Option<OffsetDateTime>,
        duration: Duration,
    ) -> Self {
        Self {
            path: path.into(),
            chapter,
            recorded_at,
            duration,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
#[non_exhaustive]
pub struct MediaInfo {
    pub duration: Duration,
    pub recorded_at: Option<OffsetDateTime>,
}

pub fn scan_folder(root: &Path) -> Result<Vec<PathBuf>, Error> {
    let entries = std::fs::read_dir(root).map_err(|source| Error::Read {
        path: root.to_path_buf(),
        source,
    })?;

    let mut files = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|source| Error::Read {
            path: root.to_path_buf(),
            source,
        })?;
        let path = entry.path();
        if path.is_file() && is_video(&path) {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

pub fn scan_and_probe(root: &Path) -> Result<Vec<Clip>, Error> {
    let files = scan_folder(root)?;

    let mut groups: BTreeMap<String, Vec<Candidate>> = BTreeMap::new();
    for path in files {
        let candidate = Candidate::from_path(path);
        groups
            .entry(candidate.key.clone())
            .or_default()
            .push(candidate);
    }

    let mut clips = Vec::new();
    for (_, mut candidates) in groups {
        candidates.sort_by_key(|candidate| (candidate.chapter, candidate.path.clone()));

        let mut parts = Vec::new();
        for candidate in candidates {
            let info = probe(&candidate.path)?;
            parts.push(ClipPart {
                path: candidate.path,
                chapter: candidate.chapter,
                recorded_at: info.recorded_at,
                duration: info.duration,
            });
        }

        let name = parts
            .first()
            .and_then(|part| part.path.file_name())
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "clip".to_owned());
        clips.push(Clip::new(name, parts));
    }

    clips.sort_by_key(|clip| clip.recorded_at);
    Ok(clips)
}

pub fn probe(path: &Path) -> Result<MediaInfo, Error> {
    let output = std::process::Command::new(crate::ffprobe_path())
        .args([
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_entries",
            "format=duration:format_tags=creation_time",
        ])
        .arg(path)
        .output()
        .map_err(Error::ProbeUnavailable)?;

    if !output.status.success() {
        return Err(Error::ProbeFailed {
            path: path.to_path_buf(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }

    let parsed: ProbeOutput =
        serde_json::from_slice(&output.stdout).map_err(|source| Error::ProbeOutput {
            path: path.to_path_buf(),
            source,
        })?;

    let format = parsed.format.unwrap_or_default();
    let duration_seconds = format
        .duration
        .as_deref()
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(0.0);

    let recorded_at = match format.tags.and_then(|tags| tags.creation_time) {
        Some(value) => {
            Some(
                OffsetDateTime::parse(&value, &Rfc3339).map_err(|_| Error::Timestamp {
                    path: path.to_path_buf(),
                    value,
                })?,
            )
        }
        None => None,
    };

    Ok(MediaInfo {
        duration: Duration::seconds_f64(duration_seconds.max(0.0)),
        recorded_at,
    })
}

#[derive(Clone, Debug)]
struct Candidate {
    key: String,
    chapter: u32,
    path: PathBuf,
}

impl Candidate {
    fn from_path(path: PathBuf) -> Self {
        let stem = path
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_default();
        let (key, chapter) = parse_name(&stem);
        Self { key, chapter, path }
    }
}

fn parse_name(stem: &str) -> (String, u32) {
    let upper = stem.to_ascii_uppercase();

    if let Some(rest) = upper.strip_prefix("GOPR")
        && rest.len() >= 4
        && rest.chars().all(|c| c.is_ascii_digit())
    {
        return (format!("gopro:{rest}"), 0);
    }

    let letters = upper.get(..2).unwrap_or_default();
    let chapter_and_file = upper.get(2..).unwrap_or_default();
    if matches!(letters, "GP" | "GH" | "GX" | "GL" | "GS" | "GC") && chapter_and_file.len() >= 6 {
        let (chapter, file) = chapter_and_file.split_at(2);
        if chapter.chars().all(|c| c.is_ascii_digit())
            && file.len() >= 4
            && file.chars().all(|c| c.is_ascii_digit())
        {
            return (format!("gopro:{file}"), chapter.parse().unwrap_or_default());
        }
    }

    (format!("file:{}", stem.to_ascii_lowercase()), 0)
}

fn is_video(path: &Path) -> bool {
    let Some(extension) = path.extension() else {
        return false;
    };
    matches!(
        extension.to_string_lossy().to_ascii_lowercase().as_str(),
        "mp4" | "mov" | "m4v"
    )
}

#[derive(Deserialize)]
struct ProbeOutput {
    format: Option<ProbeFormat>,
}

#[derive(Deserialize, Default)]
struct ProbeFormat {
    duration: Option<String>,
    tags: Option<ProbeTags>,
}

#[derive(Deserialize, Default)]
struct ProbeTags {
    creation_time: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_gopro_names() {
        assert_eq!(parse_name("GOPR0042"), ("gopro:0042".into(), 0));
        assert_eq!(parse_name("GP010042"), ("gopro:0042".into(), 1));
        assert_eq!(parse_name("GH020042"), ("gopro:0042".into(), 2));
        assert_eq!(parse_name("gx030123"), ("gopro:0123".into(), 3));
        assert_eq!(parse_name("clip-1"), ("file:clip-1".into(), 0));
        assert_eq!(parse_name("IMG_8486"), ("file:img_8486".into(), 0));
    }

    #[test]
    fn groups_chapters_into_one_clip() {
        let keys: Vec<String> = ["GH010042.MP4", "GH020042.MP4", "GH010043.MP4"]
            .map(|name| Candidate::from_path(PathBuf::from(name)).key)
            .to_vec();

        assert_eq!(keys[0], keys[1], "chapters of one recording share a key");
        assert_ne!(keys[1], keys[2], "different file numbers stay separate");
    }

    #[test]
    fn clip_derives_window_from_parts() {
        let start = OffsetDateTime::from_unix_timestamp(1_788_000_000).unwrap();
        let clip = Clip::new(
            "GH010042.MP4",
            vec![
                ClipPart::new("GH010042.MP4", 1, Some(start), Duration::seconds(10)),
                ClipPart::new(
                    "GH020042.MP4",
                    2,
                    Some(start + Duration::seconds(10)),
                    Duration::seconds(5),
                ),
            ],
        );

        assert_eq!(clip.recorded_at, Some(start));
        assert_eq!(clip.ended_at(), Some(start + Duration::seconds(15)));
        assert_eq!(clip.chapter_count(), 2);
    }
}
