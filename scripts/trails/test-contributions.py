#!/usr/bin/env python3
import copy
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile
from pathlib import Path
from catalog import ROOT, baseline, digest, encoded, snapshot, source_catalogs, stable_id

spec = importlib.util.spec_from_file_location('importer', Path(__file__).with_name('import-contribution.py'))
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class Contributions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / 'Berms/Resources', self.root / 'Berms/Resources')
        self.manifest, _ = snapshot(self.root)
        _, catalogs = source_catalogs(self.root)
        self.catalog, self.source, self.collection = catalogs['mountain-creek-resort']
        self.feature = copy.deepcopy(next(f for f in self.collection['features']
                                        if f['properties']['slug'] not in self.catalog['aliases']))
        self.pid = '11111111-1111-4111-8111-111111111111'
        self.cid = '22222222-2222-4222-8222-222222222222'
        self.samples = [dict(timestamp=f'2026-09-29T12:00:0{i}.000Z', latitude=41.18+i*.0001,
                             longitude=-74.50, altitude=None, horizontalAccuracy=5.0,
                             verticalAccuracy=None, speed=None, course=None) for i in range(3)]
        self.contribution = dict(schemaVersion=1, id=self.cid, createdAt='2026-09-29T12:00:00Z',
                                 catalogID=self.catalog['id'], baseRevision=self.manifest['revision'],
                                 baseChecksum=self.manifest['resorts'][0]['catalogs'][0]['checksum'],
                                 provenance='developerGPS', contentVersion=1,
                                 operations=[], passes=[dict(id=self.pid, startedAt=self.samples[0]['timestamp'],
                                  endedAt=self.samples[-1]['timestamp'], direction='reverse', gaps=[], exclusions=[],
                                  samplesFile=f'passes/{self.pid}.json', checksum=digest(encoded(self.samples)))])
        self.operation('corroborateTrail')

    def operation(self, kind):
        slug = self.feature['properties']['slug']
        old = copy.deepcopy(self.feature)
        proposed = None
        if kind == 'addTrail':
            slug = 'survey-33333333-3333-4333-8333-333333333333'
            old = None
            proposed = dict(type='Feature', properties=dict(slug=slug, name='Fixture trail', difficulty='blue'),
                            geometry=dict(type='LineString', coordinates=[[s['longitude'],s['latitude']] for s in self.samples]))
        elif kind == 'editTrail':
            proposed = copy.deepcopy(old)
            proposed['properties']['name'] = 'Renamed trail'
        self.contribution['operations'] = [dict(kind=kind, slug=slug,
            trailID=stable_id(self.catalog['stableIDNamespace'], slug), baseline=old,
            baselineHash=baseline(old) if old else None, proposed=proposed,
            passIDs=[self.pid], selectedPassID=self.pid)]

    def archive(self, extra=None):
        path = self.root / 'phone.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('contribution.json', encoded(self.contribution))
            archive.writestr(f'passes/{self.pid}.json', encoded(self.samples))
            if extra:
                archive.writestr(*extra)
        return path

    def prepare(self):
        return importer.prepare(self.archive(), self.root)

    def test_pinned_phone_export_fixture(self):
        fixture = Path(__file__).with_name('fixtures') / 'phone-v1'
        archive_path = self.root / 'swift-fixture.zip'
        with zipfile.ZipFile(archive_path, 'w') as archive:
            for path in sorted(fixture.rglob('*.json')):
                archive.write(path, str(path.relative_to(fixture)))
        summary, writes = importer.prepare(archive_path, self.root)
        self.assertEqual(summary['status'], 'ready')
        importer.apply(writes)
        collection = json.loads(self.source.read_bytes())
        added = collection['features'][-1]
        contribution = json.loads((fixture / 'contribution.json').read_bytes())
        self.assertEqual(stable_id(self.catalog['stableIDNamespace'], added['properties']['slug']),
                         contribution['operations'][0]['trailID'])
        self.assertEqual(len(added['geometry']['coordinates']), 2)

    def test_corroboration_does_not_change_geometry_and_is_idempotent(self):
        before = self.source.read_bytes()
        summary, writes = self.prepare()
        self.assertEqual(summary['status'], 'ready')
        importer.apply(writes)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(self.prepare(), ({'status':'duplicate','contributionID':self.cid}, {}))
        self.contribution['contentVersion'] += 1
        with self.assertRaisesRegex(ValueError, 'different content'):
            self.prepare()

    def test_add_roundtrip_stable_identity_and_deterministic_package(self):
        self.operation('addTrail')
        summary, writes = self.prepare()
        importer.apply(writes)
        added = json.loads(self.source.read_bytes())['features'][-1]
        self.assertEqual(added['properties']['slug'], self.contribution['operations'][0]['slug'])
        self.assertEqual(snapshot(self.root), snapshot(self.root))
        self.assertEqual(added['geometry']['coordinates'], [[s['longitude'], s['latitude']] for s in self.samples])
        preview = self.root / 'review'
        importer.preview(summary, preview)
        self.assertTrue((preview / 'index.html').exists())
        evidence = json.loads((self.root / f'trail-data/evidence/{self.cid}.json').read_bytes())
        self.assertIsNone(evidence['samples'][self.pid][0]['verticalAccuracy'])
        self.assertEqual(evidence['contribution']['passes'][0]['direction'], 'reverse')

    def test_overlap_conflicts_but_unrelated_changes_do_not(self):
        self.operation('editTrail')
        collection = json.loads(self.source.read_bytes())
        collection['features'][-1]['properties']['unrelated'] = 'preserved'
        self.source.write_bytes(encoded(collection))
        self.assertEqual(self.prepare()[0]['status'], 'ready')
        collection['features'][0]['properties']['name'] = 'Other maintainer edit'
        self.source.write_bytes(encoded(collection))
        summary, writes = self.prepare()
        self.assertEqual(summary['status'], 'conflict')
        self.assertFalse(writes)
        self.operation('corroborateTrail')
        self.assertEqual(self.prepare()[0]['status'], 'ready')

    def test_metadata_edit_keeps_unknown_fields_and_multiline_boundaries(self):
        self.operation('editTrail')
        operation = self.contribution['operations'][0]
        original = copy.deepcopy(operation['proposed'])
        original['properties']['unknownAttribution'] = 'credit'
        original['geometry'] = dict(type='MultiLineString', coordinates=[[[0,0],[1,1]],[[2,2],[3,3]]])
        self.collection['features'][0] = original
        self.source.write_bytes(encoded(self.collection))
        operation['baseline'] = copy.deepcopy(original)
        operation['baselineHash'] = baseline(original)
        operation['proposed'] = copy.deepcopy(original)
        del operation['proposed']['properties']['unknownAttribution']
        operation['proposed']['properties']['name'] = 'Rename'
        _, writes = self.prepare()
        importer.apply(writes)
        current = json.loads(self.source.read_bytes())['features'][0]
        self.assertEqual(current['properties']['unknownAttribution'], 'credit')
        self.assertEqual(current['geometry'], original['geometry'])
        self.assertEqual(current['properties']['slug'], original['properties']['slug'])

    def test_checksum_bad_paths_quality_duplicate_ids_leave_source_untouched(self):
        before = self.source.read_bytes()
        self.samples[0]['horizontalAccuracy'] = -1
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.prepare()
        self.contribution['passes'][0]['checksum'] = digest(encoded(self.samples))
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            self.prepare()
        self.samples[0]['horizontalAccuracy'] = None
        self.contribution['passes'][0]['checksum'] = digest(encoded(self.samples))
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            importer.prepare(self.archive(('../escape', 'x')), self.root)
        self.contribution['passes'].append(copy.deepcopy(self.contribution['passes'][0]))
        with self.assertRaisesRegex(ValueError, 'duplicate pass'):
            self.prepare()
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse((self.root / 'trail-data').exists())

    def test_alias_resolves_to_canonical_id(self):
        retired, canonical = next(iter(self.catalog['aliases'].items()))
        feature = next(f for f in self.collection['features'] if f['properties']['slug'] == canonical)
        self.feature = copy.deepcopy(feature)
        self.operation('corroborateTrail')
        self.contribution['operations'][0]['slug'] = retired
        self.assertEqual(self.prepare()[0]['changes'][0]['slug'], canonical)

    def test_deleted_target_conflicts(self):
        slug = self.feature['properties']['slug']
        self.collection['features'] = [f for f in self.collection['features'] if f['properties']['slug'] != slug]
        self.source.write_bytes(encoded(self.collection))
        self.assertEqual(self.prepare()[0]['status'], 'conflict')

    def test_gap_and_exclusions_are_validated(self):
        self.operation('addTrail')
        self.contribution['passes'][0]['exclusions'] = [99]
        with self.assertRaisesRegex(ValueError, 'exclusions'):
            self.prepare()
        self.contribution['passes'][0]['exclusions'] = []
        self.contribution['passes'][0]['gaps'] = [dict(startedAt=self.samples[0]['timestamp'], endedAt=self.samples[1]['timestamp'])]
        with self.assertRaisesRegex(ValueError, 'gaps'):
            self.prepare()

    def test_failed_replace_rolls_back_all_source_bytes(self):
        self.operation('addTrail')
        _, writes = self.prepare()
        original = self.source.read_bytes()
        real_replace = importer.os.replace
        calls = 0
        def broken_replace(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('simulated disk failure')
            real_replace(source, destination)
        with patch.object(importer.os, 'replace', broken_replace):
            with self.assertRaisesRegex(OSError, 'disk failure'):
                importer.apply(writes)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertFalse((self.root / 'trail-data/ledger.json').exists())
        self.assertFalse(list((self.root / 'trail-data/evidence').glob('*.json')))

    def test_coordinate_quality_and_pass_intervals_reject_bad_values(self):
        for key, value in [('horizontalAccuracy', float('inf')), ('course', 360), ('speed', -1), ('timestamp', '2025-01-01T00:00:00Z')]:
            with self.subTest(key=key):
                samples = copy.deepcopy(self.samples)
                if key == 'horizontalAccuracy':
                    # JSON standard itself refuses nonfinite values.
                    with self.assertRaises(ValueError):
                        encoded([dict(samples[0], **{key:value})])
                    continue
                self.samples[0][key] = value
                self.contribution['passes'][0]['checksum'] = digest(encoded(self.samples))
                with self.assertRaises(ValueError):
                    self.prepare()
                self.samples = samples

    def test_invalid_proposed_metadata_leaves_sources_untouched(self):
        self.operation('editTrail')
        before = self.source.read_bytes()
        for key, value in [('name', '   '), ('name', 3), ('difficulty', 42), ('difficultyLabel', True)]:
            with self.subTest(key=key):
                proposal = copy.deepcopy(self.contribution['operations'][0]['proposed'])
                self.contribution['operations'][0]['proposed']['properties'][key] = value
                with self.assertRaises(ValueError):
                    self.prepare()
                self.contribution['operations'][0]['proposed'] = proposal
        self.assertEqual(self.source.read_bytes(), before)

    def test_abrupt_exit_at_each_replace_recovers_without_false_duplicate(self):
        self.operation('addTrail')
        original = self.source.read_bytes()
        for stop_at in (1, 2, 3):
            summary, writes = self.prepare()
            self.assertEqual(summary['status'], 'ready')
            child = os.fork()
            if child == 0:
                real_replace = importer.os.replace
                calls = 0
                def interrupted_replace(source, destination):
                    nonlocal calls
                    real_replace(source, destination)
                    calls += 1
                    if calls == stop_at:
                        os._exit(77)
                importer.os.replace = interrupted_replace
                importer.apply(writes)
                os._exit(0)
            _, status = os.waitpid(child, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 77)
            with self.assertRaisesRegex(ValueError, 'pending import'):
                self.prepare()
            importer.recover_pending(self.root)
            if stop_at < 3:
                self.assertEqual(self.source.read_bytes(), original)
                self.assertEqual(self.prepare()[0]['status'], 'ready')
                self.assertFalse((self.root / 'trail-data/ledger.json').exists())
            else:
                self.assertEqual(self.prepare()[0]['status'], 'duplicate')
                self.assertNotEqual(self.source.read_bytes(), original)
            self.assertFalse((self.root / 'trail-data' / importer.JOURNAL_NAME).exists())

    def test_recovery_does_not_overwrite_manual_changes(self):
        self.operation('addTrail')
        _, writes = self.prepare()
        child = os.fork()
        if child == 0:
            real_replace = importer.os.replace
            def interrupted_replace(source, destination):
                real_replace(source, destination)
                os._exit(77)
            importer.os.replace = interrupted_replace
            importer.apply(writes)
            os._exit(0)
        os.waitpid(child, 0)
        edited = self.source.read_bytes() + b'\n'
        self.source.write_bytes(edited)
        with self.assertRaisesRegex(ValueError, 'manual change'):
            importer.recover_pending(self.root)
        self.assertEqual(self.source.read_bytes(), edited)

    def test_missing_evidence_is_not_reported_as_successful_duplicate(self):
        _, writes = self.prepare()
        importer.apply(writes)
        (self.root / f'trail-data/evidence/{self.cid}.json').unlink()
        with self.assertRaisesRegex(ValueError, 'missing or inconsistent evidence'):
            self.prepare()

    def test_empty_pass_is_not_accepted_as_supporting_evidence(self):
        self.samples = []
        self.contribution['passes'][0]['checksum'] = digest(encoded(self.samples))
        with self.assertRaisesRegex(ValueError, 'no GPS evidence'):
            self.prepare()

    def test_schema_and_out_of_range_coordinates(self):
        self.contribution['schemaVersion'] = 2
        with self.assertRaisesRegex(ValueError, 'schema'):
            self.prepare()
        self.contribution['schemaVersion'] = 1
        self.samples[0]['latitude'] = 91
        self.contribution['passes'][0]['checksum'] = digest(encoded(self.samples))
        with self.assertRaisesRegex(ValueError, 'outside earth'):
            self.prepare()


if __name__ == '__main__':
    unittest.main()
