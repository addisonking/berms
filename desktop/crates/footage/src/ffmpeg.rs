use std::path::{Path, PathBuf};

use crate::Error;

pub fn ffprobe_path() -> PathBuf {
    std::env::var_os("BERMS_FFPROBE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("ffprobe"))
}

pub fn ffmpeg_path() -> PathBuf {
    std::env::var_os("BERMS_FFMPEG")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("ffmpeg"))
}

pub fn concat(parts: &[PathBuf], output: &Path) -> Result<(), Error> {
    let list_path = output.with_extension("concat.txt");
    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent).map_err(|source| Error::Read {
            path: parent.to_path_buf(),
            source,
        })?;
    }

    let mut list = String::new();
    for part in parts {
        list.push_str("file '");
        list.push_str(&escape_concat_path(part));
        list.push_str("'\n");
    }
    std::fs::write(&list_path, list).map_err(|source| Error::Read {
        path: list_path.clone(),
        source,
    })?;

    let result = std::process::Command::new(ffmpeg_path())
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
        ])
        .arg(&list_path)
        .args(["-c", "copy", "-movflags", "+faststart"])
        .arg(output)
        .output()
        .map_err(Error::FfmpegUnavailable);

    let _ = std::fs::remove_file(&list_path);

    match result {
        Ok(output_info) if output_info.status.success() => Ok(()),
        Ok(output_info) => Err(Error::ConcatFailed {
            output: output.to_path_buf(),
            stderr: String::from_utf8_lossy(&output_info.stderr)
                .trim()
                .to_owned(),
        }),
        Err(error) => Err(error),
    }
}

fn escape_concat_path(path: &Path) -> String {
    path.to_string_lossy().replace('\'', r"'\''")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_single_quotes() {
        assert_eq!(
            escape_concat_path(Path::new("/tmp/it's here/GH010042.MP4")),
            r"/tmp/it'\''s here/GH010042.MP4"
        );
    }
}
