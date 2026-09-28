#!/usr/bin/env python3
"""Point the Xcode project at your own Apple team and bundle ids before building."""

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = "Berms.xcodeproj/project.pbxproj"

PRODUCT_SUFFIXES = {
    "Berms": "",
    "BermsWatch": ".watchkitapp",
    "BermsWatchExtension": ".watchkitapp.watchkitextension",
    "BermsLiveActivity": ".liveactivity",
    "BermsTests": ".tests",
    "BermsStudio": ".studio",
}

# (path, plist key, suffix appended to the app bundle id)
PLISTS = (
    ("BermsWatch/Info.plist", "WKCompanionAppBundleIdentifier", ""),
    ("BermsWatchExtension/Info.plist", "WKAppBundleIdentifier", ".watchkitapp"),
)

NAME_PATTERN = re.compile(r"PRODUCT_NAME = ([A-Za-z0-9_]+);")
ID_PATTERN = re.compile(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);")
TEAM_PATTERN = re.compile(r"DEVELOPMENT_TEAM = ([A-Za-z0-9]+);")
TARGET_TEAM_PATTERN = re.compile(r"DevelopmentTeam = ([A-Za-z0-9]+);")


def rewrite_project(text, team, bundle):
    lines = []
    changes = []
    seen = set()
    for line in text.splitlines(keepends=True):
        name = NAME_PATTERN.search(line)
        old = ID_PATTERN.search(line)
        if name and old and name.group(1) in PRODUCT_SUFFIXES:
            seen.add(name.group(1))
            new = bundle + PRODUCT_SUFFIXES[name.group(1)]
            if old.group(1) != new:
                changes.append((f"bundle id for {name.group(1)}", old.group(1), new))
                line = line[: old.start(1)] + new + line[old.end(1) :]
        lines.append(line)

    missing = sorted(set(PRODUCT_SUFFIXES) - seen)
    if missing:
        sys.exit(f"error: no PRODUCT_NAME found for {', '.join(missing)} in {PROJECT}")

    updated = "".join(lines)
    old_teams = set(TEAM_PATTERN.findall(updated))
    if not old_teams:
        sys.exit(f"error: no DEVELOPMENT_TEAM found in {PROJECT}")
    for old_team in sorted(old_teams):
        if old_team != team:
            changes.append(("development team", old_team, team))
    updated = TEAM_PATTERN.sub(f"DEVELOPMENT_TEAM = {team};", updated)

    for old_team in sorted(set(TARGET_TEAM_PATTERN.findall(updated))):
        if old_team != team:
            changes.append(("target development team", old_team, team))
    updated = TARGET_TEAM_PATTERN.sub(f"DevelopmentTeam = {team};", updated)
    return updated, changes


def rewrite_plist(text, key, new_bundle):
    pattern = re.compile(r"(<key>%s</key>\s*<string>)([^<]*)(</string>)" % re.escape(key))
    match = pattern.search(text)
    if not match:
        sys.exit(f"error: {key} not found")
    if match.group(2) == new_bundle:
        return text, None
    return text[: match.start(2)] + new_bundle + text[match.end(2) :], (match.group(2), new_bundle)


def verify(team, bundle):
    text = (ROOT / PROJECT).read_text()
    expected_ids = {bundle + suffix for suffix in PRODUCT_SUFFIXES.values()}
    found_ids = set(ID_PATTERN.findall(text))
    if found_ids != expected_ids:
        sys.exit(f"error: unexpected bundle ids after write: {sorted(found_ids ^ expected_ids)}")
    found_teams = set(TEAM_PATTERN.findall(text)) | set(TARGET_TEAM_PATTERN.findall(text))
    if found_teams != {team}:
        sys.exit(f"error: unexpected development teams after write: {sorted(found_teams)}")
    for relative, key, suffix in PLISTS:
        match = re.search(r"<key>%s</key>\s*<string>([^<]*)</string>" % re.escape(key), (ROOT / relative).read_text())
        if not match or match.group(1) != bundle + suffix:
            sys.exit(f"error: {key} not applied in {relative}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("team", help="your 10-character Apple team id")
    parser.add_argument("bundle", help="app bundle id, for example com.you.berms")
    parser.add_argument("--dry-run", action="store_true", help="show changes without writing them")
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9]{10}", args.team):
        sys.exit("error: team id must be 10 letters or digits")
    if not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", args.bundle):
        sys.exit("error: bundle id must look like com.you.berms")

    updates = {}
    changes = []

    updated, project_changes = rewrite_project((ROOT / PROJECT).read_text(), args.team, args.bundle)
    if project_changes:
        updates[PROJECT] = updated
        changes.append((PROJECT, list(dict.fromkeys(project_changes))))

    for relative, key, suffix in PLISTS:
        updated, change = rewrite_plist((ROOT / relative).read_text(), key, args.bundle + suffix)
        if change:
            updates[relative] = updated
            changes.append((relative, [(key, *change)]))

    if not changes:
        print(f"already configured: team {args.team}, bundle {args.bundle} ({ROOT})")
        return

    for path, path_changes in changes:
        print(path)
        for label, old, new in path_changes:
            print(f"  {label}: {old} -> {new}")

    if args.dry_run:
        print("\ndry run: nothing written")
        return

    for relative, text in updates.items():
        (ROOT / relative).write_text(text)
    verify(args.team, args.bundle)
    print(f"\nconfigured for team {args.team} and bundle {args.bundle}")
    print("next: build for your device, or run ./scripts/test.sh to check signing")


if __name__ == "__main__":
    main()
