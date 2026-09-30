#!/usr/bin/env python3
import argparse
from pathlib import Path
from catalog import ROOT, encoded, snapshot

parser = argparse.ArgumentParser(description='Package immutable approved catalog assets; never publishes.')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--base-url', help='Immutable release asset URL prefix')
parser.add_argument('--root', type=Path, default=ROOT)
parser.add_argument('--write-bundled-baselines', action='store_true')
args = parser.parse_args()
manifest, packages = snapshot(args.root, args.base_url)
args.output.mkdir(parents=True, exist_ok=True)
for name, data in packages.items():
    (args.output / name).write_bytes(data)
(args.output / 'catalog-manifest.json').write_bytes(encoded(manifest))
if args.write_bundled_baselines:
    (args.root / 'Berms/Resources/trail-baselines.json').write_bytes(encoded(manifest))
print(manifest['revision'])
