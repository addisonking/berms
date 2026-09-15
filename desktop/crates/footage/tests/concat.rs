use std::process::Command;

#[test]
fn concatenates_clips_with_stream_copy() {
    if Command::new("ffmpeg").arg("-version").output().is_err() {
        eprintln!("skipping: ffmpeg is not on PATH");
        return;
    }

    let dir = std::env::temp_dir().join(format!("berms-footage-concat-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    let mut parts = Vec::new();
    for (name, color) in [("a.mp4", "red"), ("b.mp4", "blue")] {
        let path = dir.join(name);
        let status = Command::new("ffmpeg")
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                &format!("color=c={color}:duration=1:size=320x240:rate=30"),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
            ])
            .arg(&path)
            .status()
            .unwrap();
        assert!(status.success(), "failed to generate {name}");
        parts.push(path);
    }

    let output = dir.join("out.mp4");
    berms_footage::concat(&parts, &output).unwrap();

    let info = berms_footage::probe(&output).unwrap();
    assert!(
        info.duration.whole_seconds() >= 2,
        "expected both parts, got {:?}",
        info.duration
    );

    std::fs::remove_dir_all(&dir).ok();
}
