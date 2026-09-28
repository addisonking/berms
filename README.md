# berms

a downhill mountain bike tracker built for lift-served bike parks.

the idea is set and forget. start a session in the morning, put your phone away, and let the app track the rest of the day on its own. it splits lift rides from descents, handles lunch and other breaks, and keeps going without needing to be paused, resumed, or corrected. if you're on the lift, it knows.

berms is a focused bike park tracker, not a social network. it does one thing and tries to do it well.

![berms screens: day archive, day summary, runs with trail names, live tracking, and a share card](docs/screenshots/overview.png)

## recording

one session covers the whole day. berms records gps, barometric altitude, motion activity, and device motion continuously in the background while showing a live map of your run, trail overlays, and a floating stats panel with pause, resume, and finish controls.

from that data it separates lift rides from descents, learns where the lifts are, and recognizes the bottom and top of each lift so a slow section or a mid-run stop doesn't get split incorrectly. it also detects jumps — airtime, distance, height, and drop — and rejects the false positives that come from rough trails.

## stats

for each day: distance, descent, lift vertical, riding time, lift time, stopped and paused time, top speed, and jump totals. for each run: distance, vertical, duration, top speed, and jumps. you can correct the automatic split with mark as lift or split a run at a long stop.

## trails

at supported parks, berms matches each run to the trails you actually rode and names the sequence (for example, "trail a → trail b"), handling partial runs, direction, and parallel trails. it works at:

- mountain creek resort, vernon, new jersey
- whistler mountain bike park, whistler, british columbia

trail catalogs are bundled, so identification works offline.

## days

the days tab keeps a day-by-day archive with a month calendar and jump-to-date. each day shows a map, time breakdown, run list, jump summary, and a journal field for notes, plus a post-ride recap and shareable image cards sized for posts, stories, and portraits. days can also be exported as data for backup or for use in bermsstudio.

## apple watch

the watch app mirrors the live session: heart rate, top speed, jump airtime, run count, and phone connection status, with pause, resume, finish, and water lock controls. heart rate is collected through a workout session on the watch and is not written to health as a duplicate workout. a live activity on the lock screen and dynamic island shows the current run and stats, and can pause or resume without opening the app.

![berms watch app controls and live stats](docs/screenshots/watch.png)

## bermsstudio

a separate macos app for post-ride video. drop in gopro clips and a berms day export, and it matches footage to runs by timestamp, lets you trim clips per run, and exports stitched videos or clips renamed by day, run, and trail. requires `ffmpeg` and `ffprobe`.

![bermsstudio session list and run detail](docs/screenshots/studio.png)

## privacy

location, motion, and health data stay on device. there are no accounts, no social features, and no cloud sync.

## development

swiftui and swiftdata, targeting ios 26 with a watchos 26 watch app and a macos 26 studio app. requires xcode.

```sh
./scripts/format.sh   # swift-format with repo config
./scripts/lint.sh     # strict lint, runs in CI
./scripts/test.sh     # XCTest on the iOS Simulator
```

`Settings → About Berms Beta` shows the git commit, local-change status, and build time the app was built from.

## license

mit. see [LICENSE](LICENSE).
