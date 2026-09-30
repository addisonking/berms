"""Shared, deterministic catalog and contribution primitives (stdlib only)."""
import hashlib
import json
import math
import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def canonical(value):
    # Normalize integral floats so Swift's JSON serialization round-trips baselines.
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError('non-finite number')
        return int(value) if value.is_integer() else value
    if isinstance(value, list):
        return [canonical(v) for v in value]
    if isinstance(value, dict):
        return {k: canonical(v) for k, v in value.items()}
    return value


def encoded(value):
    return (json.dumps(canonical(value), sort_keys=True, ensure_ascii=False,
                       separators=(',', ':'), allow_nan=False) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def baseline(feature):
    return digest(encoded(feature))


def stable_id(namespace, slug):
    data = bytearray(hashlib.sha256(f'{namespace}:{slug}'.encode()).digest()[:16])
    data[6] = (data[6] & 15) | 80
    data[8] = (data[8] & 63) | 128
    return str(uuid.UUID(bytes=bytes(data))).upper()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,127}', value):
        raise ValueError(f'invalid identifier: {value!r}')
    return value


def geometry(value):
    if value.get('type') not in ('LineString', 'MultiLineString'):
        raise ValueError('expected line geometry')
    lines = [value['coordinates']] if value['type'] == 'LineString' else value['coordinates']
    if not lines:
        raise ValueError('empty geometry')
    for line in lines:
        if len(line) < 2:
            raise ValueError('a line needs two points')
        for point in line:
            if len(point) not in (2, 3) or not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                                                 and math.isfinite(v) for v in point):
                raise ValueError('invalid coordinate')
            if not -180 <= point[0] <= 180 or not -90 <= point[1] <= 90:
                raise ValueError('coordinate outside earth')


def source_catalogs(root=ROOT):
    manifest = json.loads((root / 'Berms/Resources/resorts.json').read_bytes())
    result = {}
    namespaces = set()
    for resort in manifest['resorts']:
        for catalog in resort['catalogs']:
            identifier(catalog['id'])
            if catalog['id'] in result or catalog['stableIDNamespace'] in namespaces:
                raise ValueError('ambiguous catalog ID or namespace')
            namespaces.add(catalog['stableIDNamespace'])
            path = root / 'Berms/Resources' / (identifier(catalog['resource']) + '.geojson')
            collection = json.loads(path.read_bytes())
            if collection.get('type') != 'FeatureCollection':
                raise ValueError('invalid source collection')
            slugs = set()
            for feature in collection['features']:
                slug = identifier(feature['properties']['slug'])
                if slug in slugs:
                    raise ValueError('ambiguous duplicate source trail')
                slugs.add(slug)
                geometry(feature['geometry'])
            aliases = catalog.get('aliases', {})
            if any(target not in slugs or target in aliases for target in aliases.values()):
                raise ValueError('missing or ambiguous canonical alias target')
            result[catalog['id']] = (catalog, path, collection)
    return manifest, result


def snapshot(root=ROOT, base_url=None):
    manifest, catalogs = source_catalogs(root)
    packages = {}
    for catalog, path, collection in catalogs.values():
        data = path.read_bytes()
        checksum = digest(data)
        catalog['checksum'] = checksum
        catalog['version'] = checksum
        catalog['trailHashes'] = {f['properties']['slug']: baseline(f) for f in collection['features']
                                  if f['properties'].get('slug') not in catalog.get('aliases', {})}
        filename = catalog['id'] + '.geojson'
        catalog['url'] = (base_url.rstrip('/') + '/' + filename) if base_url else filename
        packages[filename] = data
    manifest['revision'] = digest(encoded(manifest))
    return manifest, packages
