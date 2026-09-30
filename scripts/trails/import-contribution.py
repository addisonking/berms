#!/usr/bin/env python3
"""Validate everything before producing reviewable source changes."""
import argparse
import base64
import fcntl
import copy
import datetime
import html
import json
import math
import os
import tempfile
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from catalog import ROOT, baseline, digest, encoded, geometry, identifier, source_catalogs, stable_id, validate_feature


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('invalid timestamp')
    date = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if date.tzinfo is None:
        raise ValueError('timestamps must include UTC offset')
    return date


def read_archive(path):
    with zipfile.ZipFile(path) as archive:
        if sum(item.file_size for item in archive.infolist()) > 100_000_000:
            raise ValueError('oversized archive')
        files = {}
        for item in archive.infolist():
            name = item.filename
            parts = PurePosixPath(name).parts
            if name.startswith('/') or '..' in parts or '\\' in name or item.file_size > 50_000_000:
                raise ValueError('unsafe archive path or oversized payload')
            if item.is_dir():
                continue
            # NSFileCoordinator wraps the exported directory in one top-level folder.
            if len(parts) > 1 and parts[0] != 'passes':
                name = '/'.join(parts[1:])
            if name in files:
                raise ValueError('duplicate archive path')
            files[name] = archive.read(item)
        if sum(map(len, files.values())) > 100_000_000:
            raise ValueError('oversized archive')
    contribution = json.loads(files.pop('contribution.json'))
    if type(contribution['schemaVersion']) is not int or contribution['schemaVersion'] != 1:
        raise ValueError('unsupported contribution schema')
    if not isinstance(contribution['id'], str) or str(uuid.UUID(contribution['id'])).upper() != contribution['id']:
        raise ValueError('contribution UUID must be canonical uppercase')
    timestamp(contribution['createdAt'])
    if not contribution['baseRevision'] or len(contribution['baseChecksum']) != 64:
        raise ValueError('missing baseline revision/checksum')
    if contribution.get('provenance') != 'developerGPS':
        raise ValueError('unsupported provenance')
    if not contribution['operations']:
        raise ValueError('no operations')
    passes = {}
    for item in contribution['passes']:
        pid = item['id']
        if not isinstance(pid, str) or str(uuid.UUID(pid)).upper() != pid:
            raise ValueError('pass UUID must be canonical uppercase')
        if pid in passes:
            raise ValueError('duplicate pass ID')
        name = item['samplesFile']
        if name != f'passes/{pid}.json':
            raise ValueError('invalid sample path')
        data = files.pop(name)
        if digest(data) != item['checksum']:
            raise ValueError('sample checksum mismatch')
        samples = json.loads(data)
        if not isinstance(samples, list) or not samples:
            raise ValueError('pass contains no GPS evidence')
        start, end = timestamp(item['startedAt']), timestamp(item['endedAt'])
        if end < start or item['direction'] not in ('forward', 'reverse', 'unknown'):
            raise ValueError('invalid pass interval/direction')
        previous = start
        for sample in samples:
            when = timestamp(sample['timestamp'])
            if not previous <= when <= end:
                raise ValueError('out-of-order or out-of-interval sample')
            previous = when
            if 'timestampSeconds' in sample:
                seconds = sample['timestampSeconds']
                if not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or abs(seconds - when.timestamp()) > .001:
                    raise ValueError('inconsistent precise timestamp')
            geometry({'type': 'LineString', 'coordinates': [[sample['longitude'], sample['latitude']]] * 2})
            for key in ('horizontalAccuracy', 'verticalAccuracy', 'altitude', 'speed', 'course'):
                value = sample[key]
                if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float))
                                          or not math.isfinite(value)):
                    raise ValueError('invalid sample quality field')
                if key in ('horizontalAccuracy', 'verticalAccuracy', 'speed', 'course') and value is not None and value < 0:
                    raise ValueError('unavailable quality must be null')
            if sample['course'] is not None and sample['course'] >= 360:
                raise ValueError('invalid course')
        for gap in item['gaps']:
            if not start <= timestamp(gap['startedAt']) <= timestamp(gap['endedAt']) <= end:
                raise ValueError('invalid gap')
        exclusions = item['exclusions']
        if len(set(exclusions)) != len(exclusions) or any(type(i) is not int or i < 0 or i >= len(samples) for i in exclusions):
            raise ValueError('invalid exclusions')
        passes[pid] = (item, samples)
    if files:
        raise ValueError('unexpected archive payloads')
    return contribution, passes


def prepare(path, root):
    if (root / 'trail-data' / JOURNAL_NAME).exists():
        raise ValueError('pending import requires recovery; rerun with --apply')
    contribution, passes = read_archive(path)
    _, catalogs = source_catalogs(root)
    catalog, source, collection = catalogs[contribution['catalogID']]
    ledger_path = root / 'trail-data/ledger.json'
    ledger = json.loads(ledger_path.read_bytes()) if ledger_path.exists() else {}
    fingerprint = digest(encoded({'contribution': contribution, 'samples': {k: v[1] for k, v in passes.items()}}))
    cid = contribution['id']
    if cid in ledger:
        if ledger[cid] != fingerprint:
            raise ValueError('contribution ID already applied with different content; create an explicit superseding contribution')
        evidence_path = root / 'trail-data/evidence' / (cid + '.json')
        if not evidence_path.exists() or digest(encoded(json.loads(evidence_path.read_bytes()))) != fingerprint:
            raise ValueError('contribution ledger has missing or inconsistent evidence; restore the reviewed files')
        return {'status': 'duplicate', 'contributionID': cid}, {}
    features = {f['properties']['slug']: f for f in collection['features']}
    conflicts, changes, seen, used = [], [], set(), set()
    for operation in contribution['operations']:
        slug = identifier(operation['slug'])
        canonical_slug = catalog.get('aliases', {}).get(slug, slug)
        if canonical_slug in seen:
            raise ValueError('duplicate operation target')
        seen.add(canonical_slug)
        if operation['trailID'].upper() != stable_id(catalog['stableIDNamespace'], canonical_slug):
            raise ValueError('stable trail ID mismatch')
        kind = operation['kind']
        if kind not in ('addTrail', 'corroborateTrail', 'editTrail'):
            raise ValueError('unsupported operation')
        current = features.get(canonical_slug)
        approved = copy.deepcopy(current)
        old = operation.get('baseline')
        old_hash = operation.get('baselineHash')
        if old is not None and baseline(old) != old_hash:
            raise ValueError('baseline hash mismatch')
        pids = operation['passIDs']
        if not pids or len(set(pids)) != len(pids) or any(pid not in passes for pid in pids):
            raise ValueError('invalid operation passes')
        used.update(pids)
        proposal = operation.get('proposed')
        if kind == 'addTrail':
            if not slug.startswith('survey-'):
                raise ValueError('new trails need an immutable survey-UUID slug')
            if slug != 'survey-' + str(uuid.UUID(slug.removeprefix('survey-'))):
                raise ValueError('new slug UUID must be canonical lowercase')
            if old is not None or old_hash is not None or current is not None:
                conflicts.append(f'{slug}: addition already exists or has a baseline')
        elif current is None:
            conflicts.append(f'{slug}: missing/retired target needs resolution')
        elif old is None or old_hash is None:
            raise ValueError('existing target needs baseline values and hash')
        elif kind == 'editTrail' and baseline(current) != old_hash:
            conflicts.append(f'{slug}: overlapping catalog edit')
        if kind == 'corroborateTrail':
            if proposal is not None:
                raise ValueError('corroboration cannot propose geometry')
        else:
            if not proposal or proposal.get('type') != 'Feature' or proposal['properties']['slug'] != canonical_slug:
                raise ValueError('invalid proposed feature or slug rename')
            validate_feature(proposal)
            if kind == 'addTrail':
                selected = operation.get('selectedPassID')
                if selected not in pids:
                    raise ValueError('addition needs selected pass')
                item, samples = passes[selected]
                if item['gaps']:
                    raise ValueError('selected addition pass contains gaps; split it first')
                coordinates = [[s['longitude'], s['latitude']] for i, s in enumerate(samples)
                               if i not in item['exclusions']]
                if proposal['geometry'] != {'type': 'LineString', 'coordinates': coordinates}:
                    raise ValueError('addition geometry must match selected pass after exclusions')
            merged = copy.deepcopy(current or proposal)
            merged['properties'].update(proposal['properties'])
            merged['geometry'] = proposal['geometry']
            if current is None:
                collection['features'].append(merged)
            else:
                current.clear()
                current.update(merged)
        changes.append({'slug': canonical_slug, 'kind': kind, 'passes': len(pids),
                        'samples': sum(len(passes[p][1]) for p in pids),
                        'gaps': sum(len(passes[p][0]['gaps']) for p in pids),
                        'exclusions': sum(len(passes[p][0]['exclusions']) for p in pids),
                        'baseline': old, 'approved': approved, 'proposed': proposal,
                        'passDetails': [passes[p][0] for p in pids],
                         'interruptions': [passes[p][0].get('interruption') for p in pids if passes[p][0].get('interruption')],
                        'quality': {'horizontalAccuracyMeters': [s['horizontalAccuracy'] for p in pids for s in passes[p][1]
                                                                  if s['horizontalAccuracy'] is not None]},
                        'traces': [passes[p][1] for p in pids]})
    if used != set(passes):
        raise ValueError('unrelated pass payload')
    # Pass IDs are immutable across contributions too.
    for evidence_path in (root / 'trail-data/evidence').glob('*.json'):
        previous = json.loads(evidence_path.read_bytes())
        if set(passes) & set(previous['samples']):
            raise ValueError('pass ID already applied')
    summary = {'status': 'conflict' if conflicts else 'ready', 'contributionID': cid,
               'baseRevision': contribution['baseRevision'], 'conflicts': conflicts, 'changes': changes}
    if conflicts:
        return summary, {}
    ledger[cid] = fingerprint
    writes = {root / 'trail-data/evidence' / (cid + '.json'): encoded(
                  {'contribution': contribution, 'samples': {k: v[1] for k, v in passes.items()}})}
    if any(c['kind'] != 'corroborateTrail' for c in changes):
        writes[source] = encoded(collection)
    writes[ledger_path] = encoded(ledger)
    return summary, writes


def preview(summary, directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'summary.json').write_bytes(encoded(summary))
    lines = [f"{summary['status']}: {summary['contributionID']}"] + summary.get('conflicts', [])
    for change in summary.get('changes', []):
        lines.append(f"{change['kind']} {change['slug']}: {change['passes']} independent passes, "
                     f"{change['samples']} fixes, {change['gaps']} gaps, {change['exclusions']} excluded")
    (directory / 'summary.txt').write_text('\n'.join(lines) + '\n')
    # A static, offline SVG per operation; separate polylines never bridge gaps.
    output = ['<!doctype html><meta charset="utf-8"><title>Trail survey review</title>',
              '<h1>Trail survey review</h1><p>Approved: solid. Proposed: dashed. GPS passes: dotted. Quality is observational.</p>']
    for change in summary.get('changes', []):
        paths = []
        for key, dash in [('approved', ''), ('proposed', '8 4')]:
            feature = change[key]
            if feature:
                g = feature['geometry']
                for line in ([g['coordinates']] if g['type'] == 'LineString' else g['coordinates']):
                    paths.append((line, dash))
        for detail, trace in zip(change['passDetails'], change['traces']):
            chunks = [[]]
            previous = None
            for sample in trace:
                when = timestamp(sample['timestamp'])
                gap = previous is not None and (when - previous).total_seconds() > 60
                if previous is not None:
                    gap = gap or any(previous <= timestamp(g['startedAt']) <= when or
                                     previous <= timestamp(g['endedAt']) <= when for g in detail['gaps'])
                if gap:
                    chunks.append([])
                chunks[-1].append([sample['longitude'], sample['latitude']])
                previous = when
            paths.extend((chunk, '1 5') for chunk in chunks if chunk)
        points = [p for line, _ in paths for p in line]
        if not points:
            continue
        xmin, xmax = min(p[0] for p in points), max(p[0] for p in points)
        ymin, ymax = min(p[1] for p in points), max(p[1] for p in points)
        output.append(f"<h2>{html.escape(change['slug'])}</h2><svg viewBox='0 0 800 500' style='max-width:800px;width:100%'>")
        for line, dash in paths:
            coords = ' '.join(f'{20+760*(p[0]-xmin)/max(xmax-xmin,1e-9):.2f},{480-460*(p[1]-ymin)/max(ymax-ymin,1e-9):.2f}' for p in line)
            output.append(f"<polyline points='{coords}' fill='none' stroke='currentColor' stroke-width='2' stroke-dasharray='{dash}'/>")
        output.append('</svg>')
        output.append('<p>' + html.escape(f"{change['passes']} independent passes; {change['samples']} fixes; "
                                          f"{change['exclusions']} excluded. Interruptions: {change['interruptions']}") + '</p>')
    (directory / 'index.html').write_text('\n'.join(output))


JOURNAL_NAME = '.pending-import.json'


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_staged(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.survey-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise
    return Path(name)


def recover_transaction(root, journal, entries):
    changes = []
    for entry in entries:
        relative = PurePosixPath(entry['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('invalid import recovery path')
        allowed = str(relative) == 'trail-data/ledger.json' or (
            str(relative).startswith('trail-data/evidence/') and relative.suffix == '.json') or (
            str(relative).startswith('Berms/Resources/') and relative.suffix == '.geojson')
        if not allowed:
            raise ValueError('invalid import recovery target')
        path = root / str(relative)
        before = base64.b64decode(entry['before'], validate=True) if entry['before'] is not None else None
        current = path.read_bytes() if path.exists() else None
        current_hash = digest(current) if current is not None else None
        before_hash = digest(before) if before is not None else None
        if current_hash not in (before_hash, entry['afterHash']):
            raise ValueError(f'pending import overlaps a manual change: {relative}')
        changes.append((path, before, current_hash == entry['afterHash']))
    complete = all(item[2] for item in changes)
    if not complete:
        for path, before, _ in changes:
            if before is None:
                path.unlink(missing_ok=True)
            else:
                temp = write_staged(path, before)
                try:
                    os.replace(temp, path)
                finally:
                    temp.unlink(missing_ok=True)
            sync_directory(path.parent)
    for entry in entries:
        staged = entry.get('staged')
        if staged:
            temp = root / staged
            if temp.parent == (root / entry['path']).parent and temp.name.startswith('.survey-'):
                temp.unlink(missing_ok=True)
    journal.unlink()
    sync_directory(journal.parent)


def recover_pending(root):
    root = root.resolve()
    journal = root / 'trail-data' / JOURNAL_NAME
    if not journal.exists():
        return
    with journal.open('rb') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('another contribution import is still running') from None
        record = json.load(stream)
        if record.get('schemaVersion') != 1:
            raise ValueError('unsupported import recovery format')
        recover_transaction(root, journal, record['entries'])


def apply(writes):
    if not writes:
        return
    ledger = next(path for path in writes if path.name == 'ledger.json' and path.parent.name == 'trail-data')
    root = ledger.parent.parent.resolve()
    journal = root / 'trail-data' / JOURNAL_NAME
    staged, entries = {}, []
    journal_stream = None
    linked = False
    try:
        for path, data in writes.items():
            path = path.resolve()
            before = path.read_bytes() if path.exists() else None
            temp = write_staged(path, data)
            staged[path] = temp
            entries.append({'path': str(path.relative_to(root)), 'before': base64.b64encode(before).decode() if before is not None else None,
                            'afterHash': digest(data), 'staged': str(temp.relative_to(root))})
        journal_temp = write_staged(journal, encoded({'schemaVersion': 1, 'entries': entries}))
        try:
            journal_stream = journal_temp.open('rb')
            fcntl.flock(journal_stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                os.link(journal_temp, journal)
            except FileExistsError:
                raise ValueError('pending import requires recovery; rerun with --apply') from None
            linked = True
            sync_directory(journal.parent)
        finally:
            journal_temp.unlink(missing_ok=True)
        for path, temp in staged.items():
            os.replace(temp, path)
            sync_directory(path.parent)
        journal.unlink()
        linked = False
        sync_directory(journal.parent)
    except BaseException:
        if linked:
            recover_transaction(root, journal, entries)
        raise
    finally:
        if journal_stream:
            journal_stream.close()
        for temp in staged.values():
            temp.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--root', type=Path, default=ROOT)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--preview', type=Path)
    group.add_argument('--apply', action='store_true', help='Accept all validated proposals after reviewing preview')
    args = parser.parse_args()
    try:
        if args.apply:
            recover_pending(args.root)
        summary, writes = prepare(args.archive, args.root)
        if args.preview:
            preview(summary, args.preview)
        elif summary['status'] == 'ready':
            apply(writes)
        print(summary['status'])
        if summary['status'] == 'conflict':
            raise SystemExit(2)
    except (ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        parser.exit(1, f'error: {error}\n')
