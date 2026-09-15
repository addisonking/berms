mod ffmpeg;
mod scan;

pub use ffmpeg::{concat, ffmpeg_path, ffprobe_path};
pub use scan::{Clip, ClipPart, MediaInfo, probe, scan_and_probe, scan_folder};

#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    #[error("couldn't read {path}: {source}")]
    Read {
        path: std::path::PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("couldn't run ffprobe: {0}")]
    ProbeUnavailable(std::io::Error),
    #[error("ffprobe failed for {path}: {stderr}")]
    ProbeFailed {
        path: std::path::PathBuf,
        stderr: String,
    },
    #[error("invalid ffprobe output for {path}: {source}")]
    ProbeOutput {
        path: std::path::PathBuf,
        #[source]
        source: serde_json::Error,
    },
    #[error("unreadable creation_time {value:?} in {path}")]
    Timestamp {
        path: std::path::PathBuf,
        value: String,
    },
    #[error("couldn't run ffmpeg: {0}")]
    FfmpegUnavailable(std::io::Error),
    #[error("ffmpeg failed for {output}: {stderr}")]
    ConcatFailed {
        output: std::path::PathBuf,
        stderr: String,
    },
}
