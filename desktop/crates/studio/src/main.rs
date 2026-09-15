mod align;
mod app;
mod format;
mod library;
mod run_list;
mod stitch;
#[cfg(test)]
mod test_data;
mod view;

use gpui_kit::component::Root;
use gpui_kit::{AppContext as _, WindowOptions, px, size};

fn main() {
    let mut args = std::env::args().skip(1);
    if let Some(flag) = args.next()
        && flag == "--scan"
    {
        let folder = args.next().unwrap_or_else(|| {
            eprintln!("usage: berms-studio --scan <folder>");
            std::process::exit(2);
        });
        scan(&folder);
        return;
    }

    let mut args = std::env::args().skip(1);
    if let Some(flag) = args.next()
        && flag == "--import"
    {
        let paths: Vec<std::path::PathBuf> = args.map(std::path::PathBuf::from).collect();
        if paths.is_empty() {
            eprintln!("usage: berms-studio --import <file.jsonl>...");
            std::process::exit(2);
        }
        import(&paths);
        return;
    }

    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .run(|cx| {
            gpui_kit::init(cx);

            cx.spawn(async move |cx| {
                let options = WindowOptions {
                    window_min_size: Some(size(px(900.), px(600.))),
                    ..Default::default()
                };
                cx.open_window(options, |window, cx| {
                    let studio = cx.new(|cx| app::Studio::new(window, cx));
                    cx.new(|cx| Root::new(studio, window, cx))
                })
                .expect("failed to open window");
            })
            .detach();
        });
}

fn scan(folder: &str) {
    match berms_footage::scan_and_probe(std::path::Path::new(folder)) {
        Ok(clips) => {
            for clip in clips {
                println!(
                    "{:<24} {:>10}  {}",
                    clip.name,
                    format::clock(clip.recorded_at),
                    format::duration(clip.duration)
                );
            }
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

fn import(paths: &[std::path::PathBuf]) {
    let export = match berms_logs::load_days(paths) {
        Ok(export) => export,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    };

    for day in export.days() {
        println!(
            "{}  {} runs  {}",
            day.id,
            day.run_count(),
            format::day_label(day.started_at)
        );
        for run in day.runs() {
            println!(
                "    {:<28} {:>10}  {} points, {} jumps",
                run.title(),
                format::clock_range(run.started_at, run.ended_at),
                run.route.len(),
                run.jumps.len()
            );
        }
    }
}
