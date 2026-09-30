# developer trail surveys

Debug builds expose Settings → Developer → Trail surveys. Normal Track controls and ride processing are unchanged. A ride and survey share raw Core Location fixes through independent leases. Pausing or finishing one consumer leaves the other running; only the last lease stops location tasks/sessions. Survey-only capture acquires a background activity session while foregrounded. Ride motion sensors, filtering, altitude fusion, segments, watch state, and Live Activities remain owned by the ride.

Choose the park explicitly, then an existing trail or a new name/difficulty. Start only at the trail entrance; Pause at the exit and Resume for another independent pass. Dismissing Settings leaves capture running. Save ends capture and keeps the draft. Relaunch marks interrupted drafts for review; Resume starts a new pass, never bridges a gap. GPS gaps over 60 seconds also split passes. Permission revocation and stream errors interrupt the survey and appear here, while the ride retains its own state and diagnostics.

Trail catalog → open a trail → Style lets you choose Unknown, Free Ride, or Tech when you know its classification. The current source maps contain no style metadata, so unclassified trails show Unknown. Older Free Ride defaults remain stored but need confirmation once; existing Tech labels are retained. Style choices are local to this device and survive catalog refreshes; they do not edit the published GeoJSON or survey exports.

Drafts use atomic metadata snapshots and serial append-only raw-fix files in Application Support/Trail surveys. Writes run off the ride's sensor path; background entry checkpoints pending writes. They are neither RideDays nor TrailPasses and cannot enter normal matching. The recorder keeps only metadata/counts in memory. Recovery runs off the recording actor when developer tools open, recounts complete sample records, and ignores an incomplete trailing write. An unreadable draft is left intact with an error message while healthy drafts continue loading. Idle background cleanup does not initialize or load the survey store.

Open a saved draft to edit its name/note, select a geometry pass, or change an existing trail's operation from Append evidence to Propose edit. Pass details allow direction and zero-based exclusion indices. Raw excluded fixes remain in the evidence; they are omitted from the proposed line. Metadata edits retain the baseline line. Enable Replace approved line to propose geometry; a new/replacement line uses one explicitly selected pass. ZIP assembly runs off the ride's main actor. Sharing is available only for the current content version; editing any pass invalidates the previous ZIP. Empty captures cannot export evidence, and empty placeholder passes are omitted from otherwise valid exports. Existing-trail metadata edits preserve the approved difficulty, including unrated values and manifest overrides, unless explicitly changed. No averaging or confidence score is generated. A corroboration export has no geometry proposal. Prepare export, then Share survey ZIP using the system sheet. Only this trail's bounded survey passes and baseline travel; no ride logs, Health data, or unrelated ride locations are included.

The contribution ID remains fixed across exports. Content version increases on edits/new passes; exported version makes subsequent changes visible. After a contribution has been applied, an altered export with that ID is rejected. Resolve it with the maintainer rather than treating changed evidence as a new independent observation. Retain the original export during review. New independent field surveys receive new IDs and passes.

## review and apply

```sh
python3 scripts/trails/import-contribution.py ~/Downloads/Survey-ID-v1.zip --preview /tmp/trail-review
open /tmp/trail-review/index.html
cat /tmp/trail-review/summary.txt
python3 scripts/trails/import-contribution.py ~/Downloads/Survey-ID-v1.zip --apply
```

Preview does not mutate sources. If an earlier apply was interrupted, preview asks you to rerun `--apply` to recover that transaction first. It validates schema, UUIDs/stable trail IDs, checksums, safe ZIP paths, coordinates, quality fields, intervals, direction, gaps, exclusions, and duplicate passes/targets. The plain offline SVG viewer distinguishes baseline (solid), proposal (dashed), and each raw pass (dotted). Summary JSON includes interruptions, exclusions/counts, exact baseline/proposal and quality observations. These are observations, not confidence probabilities. Raw traces are shown separately from the reviewed proposed line.

`--apply` accepts the entire validated contribution after review. Each phone export targets one trail; for v1 a multi-operation archive applies only when its whole set is conflict-free. No partial apply or silent conflict resolution. An unchanged affected feature can apply despite unrelated catalog changes. Corroboration can append against a newer still-existing target. A missing target or overlapping edit returns a conflict and writes nothing. Alias targets resolve to the canonical slug/ID. An addition must match its selected pass after exclusions. Same contribution/same content is a no-op; same ID/different content is an error. Previously applied pass IDs cannot be relabeled as new evidence.

Canonical GeoJSON stays in Berms/Resources. Reviewed raw evidence and a fingerprint ledger go in trail-data/evidence and trail-data/ledger.json. Corroboration only writes these evidence files. Metadata edits preserve unknown existing properties and top-level attribution; display renames preserve slugs and IDs. MultiLineString boundaries stay intact. Apply stages every output before replacing files, retains before-images in `trail-data/.pending-import.json`, and writes the completion ledger last. A subsequent `--apply` rolls back an incomplete transaction or finalizes one whose outputs all completed. Normal errors recover immediately. Recovery checks file hashes and refuses to overwrite intervening manual edits. Keep the pending journal until recovery finishes; after success it is removed. Do not commit a pending journal or `.survey-*` staging files.

Review the normal git diff, source attribution, independent passes, approach/exclusion choices, and any proposed geometry. Regenerate bundled baselines when canonical GeoJSON changes:

```sh
python3 scripts/trails/package-catalogs.py --output /tmp/trail-assets --write-bundled-baselines
python3 scripts/trails/test-contributions.py
```

Then use an ordinary branch/commit/PR workflow. These tools never create branches, commits, pushes, PRs, or uploads. Check in changed GeoJSON, evidence/ledger, and regenerated trail-baselines.json together. Do not include scratch review output.

## catalog snapshots

```sh
python3 scripts/trails/package-catalogs.py --output /tmp/trail-assets \
  --base-url https://github.com/addisonking/berms/releases/download/IMMUTABLE-SNAPSHOT-TAG
```

Packaging is deterministic and offline. Catalog checksums cover exact GeoJSON bytes; per-feature hashes cover the documented canonical representation. Manifest revision is independent of app/build identity and includes package URLs. Attribution is retained in the original GeoJSON packages. Snapshots carry the complete resort index, namespaces, aliases, per-trail hashes, and schema version. Studio continues loading bundled resources.

After approval/merge, the manually dispatched **Publish trail catalogs** workflow on main creates an immutable snapshot release with GeoJSON and manifest assets, then updates only the discovery manifest on the dedicated `trail-catalog-latest` release. Discovery URL:

`https://github.com/addisonking/berms/releases/download/trail-catalog-latest/catalog-manifest.json`

Publication uses the workflow's GitHub token; the app contains no credentials. The workflow must be explicitly run by a maintainer; implementation/testing does not publish anything. Existing snapshot assets are never overwritten. The discovery endpoint is separate from app releases.

Settings → Update trail catalogs performs an explicit HTTPS refresh; no polling, account, or automatic upload. Refresh checks for recording/capture before downloading and again before activation. Downloads stay in memory until every package validates. Activation writes an immutable snapshot directory and atomically swaps its pointer, applies all approved geometries in one SwiftData save, and restores the previous pointer on an import failure. Failed/incomplete downloads do not touch the active revision. Downloaded files work offline and take precedence at future launches. Startup validates the complete active snapshot; a damaged snapshot falls back to the retained previous revision, then the bundled baseline if neither download is valid. The index and package files always come from the same revision. Bundled catalogs remain the fresh-install fallback.

Approved geometry is stored separately on existing stable Trail IDs. Refresh replaces that geometry without creating seed passes, changing legacy passes, or rewriting ride records. Matcher routes retain multiline boundaries; missing previously approved features lose their active geometry while their records/passes remain. Averaging and bundled diagnostic repair cannot restore an old line over the approved geometry. Catalog descriptor reads are cached, so normal GPS processing does no manifest disk I/O.

To roll back, use a previous immutable manifest URL with the developer/test refresh entry point, or replace the discovery asset with that known-good manifest and explicitly refresh Settings. Source rollback uses ordinary reviewed git changes and a new snapshot. Local immutable snapshot directories are retained for diagnosis. Never erase the ride database to repair catalog data.

## verification

```sh
python3 scripts/trails/test-contributions.py
python3 scripts/test-build-identity.py
./scripts/lint.sh
./scripts/test.sh
```

XCTest covers the real ride processor with injected shared GPS, identical off/on ride totals and watch states, both start orders, independent pause/finish, idle background cleanup, survey gaps/errors/recovery, quality/exclusions/direction, repeated export identity, approved updates with legacy passes, multiline matching, and activation/checksum/schema failure preservation. One existing watch availability test can skip on the phone simulator.

`TrailSurveyTests.testRawQualityRecoveryBoundariesAndRepeatExport` writes a synthetic actual phone ZIP to `/tmp/berms-phone-survey-fixture.zip`. To repeat the complete roundtrip, copy Berms/Resources into `/tmp/berms-survey-roundtrip/Berms/Resources`, preview/apply with `--root /tmp/berms-survey-roundtrip`, then package to `/tmp/berms-survey-roundtrip/packages`. Write the exported operation's trailID to `/tmp/berms-survey-roundtrip/trail-id.txt` and run `TrailSurveyTests.testRepositoryRoundTripFixtureImportsWithPhoneIdentity`. It imports the generated snapshot with the original phone identity and exclusions. Without these temporary artifacts that optional roundtrip test skips. A pinned real Swift export is also checked into scripts/trails/fixtures/phone-v1 for deterministic Python contract coverage.

Use isolated DerivedData and stable Xcode. The iPhone 17 Pro / iOS 26.4 simulator checks included light/dark appearance, largest Dynamic Type, Increased Contrast, semantic accessibility labels, and navigation with Reduce Motion enabled. Replacement switches were inspected on/off in both appearances; accessibility settings were restored. The offline HTML viewer was loaded and its SVG/text inspected through the collaborative browser; browser screenshot automation failed. A full VoiceOver navigation pass, smallest-phone/landscape layouts, and physical locked/background capture, permission changes, battery use, and indicator cleanup remain device validation. Synthetic tests do not establish GPS improvement or power behavior.

Release references: [manual workflows](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow), [release creation](https://cli.github.com/manual/gh_release_create), [asset upload](https://cli.github.com/manual/gh_release_upload). Native UI authority: [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/) and [iOS 27 design resources](https://developer.apple.com/design/resources/).

Local verification on 2026-09-30: 161 XCTest cases, zero failures, one existing watch-availability skip; 12 Python cases; Swift lint, six build-identity cases, watch lifecycle checks, Debug/Release simulator builds and Studio build passed. The paired-device build timed out: Xcode reported development services unavailable/device unlock required, and a missing account credential warning. No device app was installed, and no field/background/power test or publication was performed.

Review hardening verification: all eight reported software findings were addressed. 169 XCTest cases passed with zero failures and one existing watch availability skip; 17 Python cases passed, including abrupt subprocess termination after each output replacement and protection of intervening manual edits. The current phone ZIP completed repo preview/apply/package and phone import with matching IDs. Debug/Release simulator and Studio builds, Swift lint, build identity, and watch lifecycle checks passed. AXe confirmed corrupt-draft isolation and that pass edits invalidate sharing; light/dark, largest text size, and Reduce Motion were checked. Full VoiceOver navigation and physical locked/background GPS/power validation remain device checks. No publication was performed.
