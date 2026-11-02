#!/usr/bin/env python3
"""Derive adapter pins and test fixture from the app's fixed manifest/assets.

Usage: python tool/generate_bundled_glyph_pins.py APP_BUNDLE_DIRECTORY [--check]
No network access; --check is read-only. A new digest requires deliberate source
review in both app and adapter, never accepts new runtime manifest authority.
"""
import argparse
import base64
import gzip
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = root / 'packages/maplibre_platform_interface/lib/src/offline/bundled_glyph_seeds.dart'
fixture = root / 'packages/maplibre/test/fixtures/varela-v1'
raw = (args.bundle / 'manifest.json').read_bytes()
digest = hashlib.sha256(raw).hexdigest()
code = source.read_text()
assert re.search(r"static const manifestSha256\s*=\s*'" + digest + r"';", code), 'Manifest version mismatch: review source pin explicitly first'
manifest = json.loads(raw)
assert manifest['id'] == 'varela-v1'
expected = {f'{stack}/{start}-{start+255}.pbf' for stack in ('Varela Round Regular', 'Open Sans Bold') for start in range(0,65536,256)}
assert len(manifest['resources']) == 512
payload = {}
pins = []
total = 0
for entry in manifest['resources']:
    relative = entry['path']
    assert relative in expected, 'Unexpected/duplicate fixed path'
    expected.remove(relative)
    data = (args.bundle / relative).read_bytes()
    assert len(data) == entry['bytes'] and 0 < len(data) <= 256*1024
    assert hashlib.sha256(data).hexdigest() == entry['sha256']
    total += len(data)
    payload[relative] = base64.b64encode(data).decode()
    pins.append("  %s: (%d, '%s'),\n" % (repr(relative), len(data), entry['sha256']))
assert not expected and total <= 1024*1024
marker = 'const _varelaV1 = <String, (int, String)>{\n'
expected_source = code.split(marker)[0] + marker + ''.join(pins) + '};\n// dart format on\n'
artifacts = {
    source: expected_source.encode(),
    fixture / 'resources.json.gz': gzip.compress(json.dumps(payload,separators=(',',':')).encode(),mtime=0),
    fixture / 'manifest.json': raw,
    **{fixture / name: (args.bundle / name).read_bytes() for name in ['OFL.txt', 'OpenSans-LICENSE.txt']},
}
for path, data in artifacts.items():
    if args.check:
        assert path.read_bytes() == data, f'Generated artifact mismatch: {path}'
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
print(f'Verified {len(payload)} resources / {total} bytes / manifest {digest}')
