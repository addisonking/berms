use std::path::{Path, PathBuf};

use berms_footage::Clip;
use time::OffsetDateTime;

use crate::format;

pub fn stitch_run(clips: &[Clip], output: &Path) -> Result<(), String> {
    let mut ordered: Vec<&Clip> = clips.iter().collect();
    ordered.sort_by_key(|clip| clip.recorded_at);

    let parts: Vec<PathBuf> = ordered
        .iter()
        .flat_map(|clip| clip.parts.iter().map(|part| part.path.clone()))
        .collect();

    if parts.is_empty() {
        return Err("nothing to build".to_owned());
    }

    berms_footage::concat(&parts, output).map_err(|error| error.to_string())
}

pub fn output_path(root: &Path, day: OffsetDateTime, title: &str, run_number: usize) -> PathBuf {
    root.join("Berms Exports").join(format!(
        "{}-run-{:02}-{}.mp4",
        slug(&format::day_label(day)),
        run_number,
        slug(title)
    ))
}

fn slug(value: &str) -> String {
    let mut slug = String::new();
    let mut pending_dash = false;
    for character in value.chars() {
        if character.is_ascii_alphanumeric() {
            if pending_dash && !slug.is_empty() {
                slug.push('-');
            }
            slug.push(character.to_ascii_lowercase());
            pending_dash = false;
        } else {
            pending_dash = true;
        }
    }

    if slug.len() > 48 {
        slug.truncate(48);
        while slug.ends_with('-') {
            slug.pop();
        }
    }

    if slug.is_empty() {
        "untitled".to_owned()
    } else {
        slug
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::format_description::well_known::Rfc3339;

    #[test]
    fn slugs_titles() {
        assert_eq!(
            slug("Twilight Zone → Lower Twilight"),
            "twilight-zone-lower-twilight"
        );
        assert_eq!(slug("  "), "untitled");
    }

    #[test]
    fn builds_output_path() {
        let day = OffsetDateTime::parse("2026-09-06T15:12:00Z", &Rfc3339).unwrap();
        let path = output_path(Path::new("/footage"), day, "Kamikaze", 2);
        assert_eq!(
            path,
            Path::new("/footage/Berms Exports/sun-sep-6-run-02-kamikaze.mp4")
        );
    }
}
