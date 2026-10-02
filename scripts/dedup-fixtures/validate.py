#!/usr/bin/env python3
"""Validate corpus integrity, metadata hygiene and recorded approvals, not model accuracy."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct

from PIL import Image
from build import case_fingerprint, frozen_expectations

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / 'Tests/Fixtures/AdvancedDedup'
SYNTHETIC_EXIF = {
    270: 'PhotosYNC fictional metadata fixture',
    305: 'PhotosYNC Fixture Builder',
    315: 'Fictional Test Photographer',
    306: '2020:01:01 12:00:00',
}
SAFE_DISPLAY_P3_PROFILES = {
    '20789fdbea9835251a4f0796c8bf45cbd964896044886540da21ffc7457af0ab',
    '7e1c7ec53e8ea35fed3e169dee62115ac045f26c7bc256fab16a5c26c29eacbd',
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def jpeg_segments(data: bytes) -> tuple[list[tuple[int, bytes]], bytes]:
    require(data[:2] == b'\xff\xd8', 'Missing JPEG SOI')
    segments = []
    offset = 2
    while offset < len(data):
        require(data[offset] == 0xff, 'Invalid JPEG marker')
        marker = data[offset+1]
        size = int.from_bytes(data[offset+2:offset+4], 'big')
        require(size >= 2 and offset+2+size <= len(data), 'Invalid JPEG length')
        if marker == 0xda:
            return segments, data[offset:]
        segments.append((marker, data[offset+4:offset+2+size]))
        offset += size+2
    raise ValueError('Missing JPEG scan')


def validate(directory: Path, require_approved: bool = False) -> dict:
    manifest = json.loads((directory / 'manifest.json').read_text())
    content_hash = manifest.pop('content_sha256')
    require(hashlib.sha256(json.dumps(manifest, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest() == content_hash, 'Manifest content hash mismatch')
    require(manifest['schema_version'] == 1, 'Unexpected schema')
    require(manifest['purpose'] == 'public_regression_not_threshold_calibration', 'Dataset purpose changed')
    images = {i['id']: i for i in manifest['images']}
    sources = {s['id']: s for s in manifest['sources']}
    cases = manifest['cases']
    contributions_path = directory / 'contributions.json'
    contributions = json.loads(contributions_path.read_text()) if contributions_path.exists() else {'cases': [], 'images': [], 'sources': []}
    contributed_cases = {c['id']: c for c in contributions['cases']}
    require(not contributed_cases or set(contributed_cases) == {'N051', 'N052', 'N053'}, 'Unexpected contribution IDs')
    require(all(images.get(i['id']) == i for i in contributions['images']), 'Contribution image records differ')
    require(all(sources.get(s['id']) == s for s in contributions['sources']), 'Contribution source records differ')
    require(len(images) == len(manifest['images']), 'Duplicate image IDs')
    require(len(sources) == len(manifest['sources']), 'Duplicate source IDs')
    require(len({c['id'] for c in cases}) == len(cases), 'Duplicate case IDs')
    require(Counter(c['group'] for c in cases) == {'positive': 11, 'negative': 20 + len(contributed_cases), 'boundary': 10}, 'Unexpected case matrix')
    require('N025' not in {c['id'] for c in cases}, 'Rejected easy negative N025 must stay removed')
    require(not {'B015', 'B017', 'B019'} & {c['id'] for c in cases}, 'Rotation decisions are deferred')
    require(len(sources) == 30 + len(contributions['sources']), 'Unexpected source families')
    paths = set()
    pixels = {}
    scans = {}
    for image_id, item in images.items():
        relative = Path(item['file'])
        require(not relative.is_absolute() and '..' not in relative.parts, f'Unsafe file path: {image_id}')
        path = directory / relative
        require(path.resolve().is_relative_to(directory.resolve()), f'Escaping symlink: {image_id}')
        require(item['file'] not in paths, f'Repeated path: {image_id}')
        paths.add(item['file'])
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == item['sha256'], f'Hash mismatch: {image_id}')
        require(len(data) == item['bytes'], f'Size mismatch: {image_id}')
        require(item['source_id'] in sources, f'Missing provenance: {image_id}')
        with Image.open(path) as image:
            image.load()
            require(list(image.size) == [item['width'], item['height']], f'Dimension mismatch: {image_id}')
            require(image.mode == 'RGB', f'Unexpected color mode: {image_id}')
            exif = dict(image.getexif())
            profile = image.info.get('icc_profile')
            if profile:
                require(item['transform']['kind'] == 'user-metadata-stripped' and
                        hashlib.sha256(profile).hexdigest() in SAFE_DISPLAY_P3_PROFILES,
                        'Unreviewed ICC profile: ' + image_id)
            expected_exif = SYNTHETIC_EXIF if item['transform']['kind'] == 'metadata' else {}
            require(exif == expected_exif, f'Unexpected EXIF: {image_id}: {exif.keys()}')
            pixels[image_id] = hashlib.sha256(image.tobytes()).hexdigest()
        if path.suffix == '.jpg':
            segments, scan = jpeg_segments(data)
            for marker, payload in segments:
                if 0xe0 <= marker <= 0xef or marker == 0xfe:
                    require(marker == 0xe0 or (marker == 0xe1 and expected_exif) or
                            (marker == 0xe2 and profile and payload.startswith(b'ICC_PROFILE\0')),
                            f'Unexpected JPEG metadata block: {image_id}')
                    if marker == 0xe0:
                        require(payload.startswith(b'JFIF\0'), f'Non-JFIF APP0: {image_id}')
                    elif marker == 0xe1:
                        require(payload.startswith(b'Exif\0\0'), f'Non-EXIF APP1: {image_id}')
            scans[image_id] = hashlib.sha256(scan).hexdigest()
        elif path.suffix == '.png':
            require(data[:8] == b'\x89PNG\r\n\x1a\n', 'Missing PNG signature')
            offset = 8
            while offset < len(data):
                size = struct.unpack('>I', data[offset:offset+4])[0]
                kind = data[offset+4:offset+8]
                require(kind in (b'IHDR', b'IDAT', b'IEND'), f'Unexpected PNG metadata chunk: {image_id}: {kind!r}')
                offset += size + 12
            require(offset == len(data), f'Trailing PNG data: {image_id}')
        else:
            raise ValueError('Unexpected image format')
    require(paths == {p.relative_to(directory).as_posix() for p in (directory/'images').rglob('*') if p.is_file()},
            'Unlisted image files')
    for source in sources.values():
        if source['id'].startswith('user-'):
            require(source in contributions['sources'] and source['license'] == 'User-provided; redistribution license unspecified'
                    and source['distribution_status'] == 'local_testing_only', 'Missing contribution license boundary')
        else:
            require(source['license'] in ('CC0-1.0', 'Public domain'), 'Unapproved license: ' + source['id'])
        require(bool(source.get('license_evidence')) and bool(source.get('author')), 'Missing license/author evidence')
        if source.get('download_url'):
            require(source['source_url'].startswith('https://commons.wikimedia.org/wiki/File:'), 'Missing file page')
            require(len(source['original_sha256']) == 64, 'Missing original hash')
    used = set()
    for case in cases:
        ids = [case['query']] + case['candidates']
        require(all(i in images for i in ids), 'Dangling image reference: ' + case['id'])
        require(len(case['candidates']) > 0, 'Empty candidate gallery')
        require(case['proposed']['relation'] in ('same_photo','different_photo','derived_photo'), 'Bad relation')
        require(case['proposed']['action'] in ('skip','import'), 'Bad action')
        if case['id'] in contributed_cases:
            require(case == contributed_cases[case['id']] and case['review_status'] == 'approved'
                    and case['expected']['content_result'] == 'not_duplicate'
                    and case['expected']['action'] == 'import'
                    and case['expected']['relation'] in ('derived_photo', 'different_photo')
                    and case['approval'].get('basis') == 'explicit_user_message'
                    and case['approval'].get('date') == '2026-10-02'
                    and case['approval']['instruction'] == '新增三组用例，都判不重',
                    'User contribution must retain explicit approved non-duplicate label')
        else:
            require(case['review_status'] == 'pending' and case['expected'] is None,
                    'Initial corpus must not silently promote proposed labels to ground truth')
        require(all(sources[images[i]['source_id']]['split_group'] == case['split_group'] for i in ids),
                'Related photos straddle split groups')
        used.update(ids)
        query, candidate = images[case['query']], images[case['candidates'][0]]
        kind = query['transform']['kind']
        if kind in ('metadata', 'renamed', 'png') and case['group'] == 'positive':
            require(pixels[query['id']] == pixels[candidate['id']], 'Lossless variant changed pixels')
        if kind == 'metadata':
            require(scans[query['id']] == scans[candidate['id']], 'Metadata-only variant changed JPEG scan')
        if kind == 'renamed':
            require(query['sha256'] == candidate['sha256'], 'Rename changed bytes')
        if case['group'] == 'negative':
            require(pixels[query['id']] != pixels[candidate['id']], 'Negative is pixel-identical')
        if case['group'] == 'positive':
            require(all(a <= b for a,b in zip(sorted((query['width'],query['height'])),
                                              sorted((candidate['width'],candidate['height'])))), 'Positive query larger than target')
    require(used == set(images), 'Unused images')
    require(not any(i['transform']['kind'] in ('negative-q55', 'negative-small') for i in images.values()),
            'Content negatives must not repeat compression/size variants')
    variant_counts = Counter(i['transform']['kind'] for i in images.values())
    require([c['id'] for c in cases if images[c['query']]['transform']['kind'] == 'synthetic-status'] == ['N032'],
            'Repeated READY to HOLD edits must be represented only by N032')
    require(variant_counts['renamed'] == 1 and variant_counts['metadata'] == 1,
            'Rename and metadata-only cases must each appear once')
    migration = manifest.get('review_migration')
    if migration:
        case_map = {c['id']: c for c in cases}
        for predecessor in [migration, *migration.get('fallbacks', [])]:
            require(predecessor['from_dataset_id'] == manifest['dataset_id'], 'Migration dataset mismatch')
            for case_id, fingerprint in predecessor['unchanged_cases'].items():
                require(case_id in case_map and case_fingerprint(case_map[case_id], images) == fingerprint,
                        'Review migration references changed case: ' + case_id)
    positive_kinds = Counter(images[c['query']]['transform']['kind'] for c in cases if c['group'] == 'positive')
    require(positive_kinds == {'renamed':1, 'metadata':1, 'jpeg-q45':3, 'half':3, 'png':3},
            'Unexpected representative positive cases')
    review_html = (directory/'review.html').read_text()
    embedded = re.search(r'    const manifest = (.*);\n', review_html)
    require(embedded is not None, 'Missing review data')
    require(json.loads(embedded.group(1)) == {**manifest, 'content_sha256': content_hash},
            'Review HTML is stale or differs from manifest; regenerate it before review')
    frozen = frozen_expectations(directory, {**manifest, 'content_sha256': content_hash})
    frozen_embedded = re.search(r'    const frozen = (.*);\n', review_html)
    require(frozen_embedded is not None and json.loads(frozen_embedded.group(1)) == frozen,
            'Review HTML has stale frozen expectations')
    if require_approved and frozen is None:
        raise ValueError('Dataset is pending human review for remaining cases; the whole dataset is not fully approved.')
    return {'cases': len(cases), 'groups': dict(Counter(c['group'] for c in cases)),
            'images': len(images), 'source_families': len(sources),
            'split_groups': len({s['split_group'] for s in sources.values()}),
            'image_bytes': sum(i['bytes'] for i in images.values()),
            'metadata': 'synthetic EXIF whitelist and reviewed Display P3 profiles only',
            'labels': f'{len(cases)} approved and frozen' if frozen else f'{len(contributed_cases)} explicitly approved contributions; remaining manifest labels pending',
            'fixture_version': frozen['fixture_version'] if frozen else None,
            'integrity': 'passed'}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, default=DEFAULT)
    parser.add_argument('--require-approved', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.dataset, args.require_approved), ensure_ascii=False, indent=2))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f'Validation failed: {error}\n')


if __name__ == '__main__':
    main()
