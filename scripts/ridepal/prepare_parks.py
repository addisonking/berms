#!/usr/bin/env python3
"""Turn the RidePal park exports into manifest-ready resort entries.

Input:  a directory of <park>.geojson files (export_all_parks.py output)
Output: parks-prepared.json — one entry per park with bounds, namespace,
        aliases, counts, and any features whose geometry belongs to another
        park. Nothing here ships as-is; the chosen entries are moved into
        Berms/Resources/resorts.json with their geojson.

Usage: python3 prepare_parks.py <parks-dir> [output.json]
"""

import collections
import glob
import json
import math
import os
import re
import statistics
import sys

MARGIN_METERS = 400.0
SUSPECT_KILOMETERS = 50.0
NAME_SUFFIX = re.compile(r"\s+[—-]\s+RidePal trail vectors$", re.IGNORECASE)


def haversine(a, b):
    radius = 6371000.0
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(h))


def median(values):
    return statistics.median(values) if values else 0.0


def feature_points(feature):
    geometry = feature["geometry"]
    coordinates = geometry["coordinates"]
    lines = [coordinates] if geometry["type"] == "LineString" else coordinates
    return [point for line in lines for point in line]


def feature_center(feature):
    points = feature_points(feature)
    return (median([p[1] for p in points]), median([p[0] for p in points]))


def is_plain(slug, slugs):
    """A slug without the "<other-slug>-<digits>" suffix RidePal adds for repeats."""
    return not any(
        slug != other
        and slug.startswith(other + "-")
        and slug.rsplit("-", 1)[-1].isdigit()
        for other in slugs
    )


def aliases_for(features):
    """Collapse identical centerlines onto the rated plain slug."""
    groups = collections.defaultdict(list)
    for feature in features:
        groups[tuple(map(tuple, feature_points(feature)))].append(feature)
    aliases = {}
    for members in groups.values():
        if len(members) < 2:
            continue
        slugs = [m["properties"]["slug"] for m in members]
        if len({m["properties"].get("name") for m in members}) != 1:
            continue
        rated = [m for m in members if m["properties"].get("difficultyLabel")]
        plain = [m for m in members if is_plain(m["properties"]["slug"], slugs)]
        canonical = (
            next((m for m in rated if m in plain), None)
            or (rated[0] if rated else (plain[0] if plain else members[0]))
        )
        for member in members:
            slug = member["properties"]["slug"]
            if slug != canonical["properties"]["slug"]:
                aliases[slug] = canonical["properties"]["slug"]
    return dict(sorted(aliases.items()))


def region_for(features):
    for feature in features:
        url = feature["properties"].get("ridepalUrl") or ""
        match = re.search(r"/trails/([a-z-]+)/([a-z-]+)/([a-z0-9-]+)/", url)
        if match:
            title = lambda value: " ".join(w.capitalize() for w in value.split("-"))
            return f"{title(match.group(3))}, {title(match.group(2))}"
    return None


def describe(park, document):
    features = document["features"]
    centers = [(f["properties"]["slug"],) + feature_center(f) for f in features]
    center_latitude = median([c[1] for c in centers])
    center_longitude = median([c[2] for c in centers])
    center = (center_latitude, center_longitude)

    suspects = []
    clean = []
    for feature, (slug, latitude, longitude) in zip(features, centers):
        distance = haversine(center, (latitude, longitude))
        if distance > SUSPECT_KILOMETERS * 1000:
            suspects.append({"slug": slug, "distanceKm": round(distance / 1000)})
        else:
            clean.append(feature)

    radius = 0.0
    for feature in clean:
        for point in feature_points(feature):
            radius = max(radius, haversine(center, (point[1], point[0])))
    radius = math.ceil((radius + MARGIN_METERS) / 50) * 50

    rated = sum(1 for f in features if f["properties"].get("difficultyLabel"))
    return {
        "id": park,
        "name": NAME_SUFFIX.sub("", document.get("name") or park),
        "region": region_for(features),
        "resource": f"{park}-ridepal-trails-with-metadata",
        "resourceFile": f"{park}-ridepal-trails-with-metadata.geojson",
        "version": f"{park}-ridepal-v1",
        "namespaces": {"stableIDNamespace": f"berms:ridepal:{park}", "catalogID": f"{park}-ridepal"},
        "bounds": {
            "center": {
                "latitude": round(center_latitude, 4),
                "longitude": round(center_longitude, 4),
            },
            "radiusMeters": radius,
        },
        "counts": {
            "features": len(features),
            "rated": rated,
            "unrated": len(features) - rated,
            "aliases": len(aliases_for(features)),
        },
        "aliases": aliases_for(features),
        "suspectFeatures": suspects,
        "needsReexport": bool(suspects),
    }


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ridepal-investigate/parks"
    destination = sys.argv[2] if len(sys.argv) > 2 else "scripts/ridepal/parks-prepared.json"

    parks = []
    for path in sorted(glob.glob(os.path.join(source, "*.geojson"))):
        park = os.path.basename(path)[: -len(".geojson")]
        entry = describe(park, json.load(open(path)))
        parks.append(entry)

    namespaces = [p["namespaces"]["stableIDNamespace"] for p in parks]
    assert len(set(namespaces)) == len(namespaces), "two parks share a stable ID namespace"
    assert "berms:ridepal" not in namespaces, "berms:ridepal is reserved for Mountain Creek"

    output = {
        "_note": (
            "Generated by prepare_parks.py from the RidePal park exports. Bounds are the median "
            "trail center with radius = farthest clean point + 400 m, rounded up to 50 m. Namespaces "
            "are berms:ridepal:<park>; never reuse bare berms:ridepal (Mountain Creek legacy). "
            "suspectFeatures have geometry from another park: the batch exporter resolved colliding "
            "slugs to the first park that published them, so those trails need a re-export before "
            "bundling."
        ),
        "parks": parks,
    }
    json.dump(output, open(destination, "w"), indent=2)

    suspects = sum(len(p["suspectFeatures"]) for p in parks)
    print(
        f"{len(parks)} parks, {sum(p['counts']['features'] for p in parks)} features, "
        f"{sum(p['counts']['aliases'] for p in parks)} aliases, "
        f"{sum(p['counts']['unrated'] for p in parks)} unrated, "
        f"{suspects} suspect features in {sum(1 for p in parks if p['needsReexport'])} parks"
    )
    print(f"wrote {destination}")


if __name__ == "__main__":
    main()
