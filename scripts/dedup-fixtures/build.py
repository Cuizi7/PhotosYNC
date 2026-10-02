#!/usr/bin/env python3
"""Build review fixtures from public photos and fixed user contributions.

Only the explicit fetch mode uses the network. Originals stay in an ignored cache;
public source photos are sanitized; fixed user JPEGs retain their reviewed bytes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import time
import urllib.error
import urllib.request

from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps, __version__ as pillow_version

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / 'Tests/Fixtures/AdvancedDedup'
DATASET_ID = 'photosync-advanced-dedup-v1'
VERSION = '2026-10-02-review-7'


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def case_fingerprint(case: dict, images: dict) -> str:
    payload = {'case': case, 'images': [images[i] for i in [case['query']] + case['candidates']]}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def reviewed_expectations(manifest: dict, review_bytes: bytes) -> dict:
    """Derive a complete label set only from an export of this exact corpus."""
    review = json.loads(review_bytes)
    if review.get('review_schema_version') != 2 or review.get('review_scope') != 'content_only':
        raise ValueError('Expected a content-only schema 2 review export')
    for key in ('dataset_id', 'version', 'content_sha256'):
        if review.get(key) != manifest[key]:
            raise ValueError('Review identity mismatch: ' + key)
    by_id = {c['id']: c for c in review['cases']}
    if len(by_id) != len(review['cases']) or set(by_id) != {c['id'] for c in manifest['cases']}:
        raise ValueError('Review must cover every case exactly once')
    cases = []
    for item in manifest['cases']:
        approved = by_id[item['id']]
        if any(approved.get(key) != item[key] for key in ('group', 'query', 'candidates')):
            raise ValueError('Review case reference mismatch: ' + item['id'])
        if approved.get('review_status') != 'approved' or not approved.get('reviewed_at'):
            raise ValueError('Review case is not approved: ' + item['id'])
        relation, action = approved['relation'], approved['action']
        if relation not in ('same_photo', 'different_photo', 'derived_photo') or action not in ('skip', 'import'):
            raise ValueError('Invalid reviewed relation or action: ' + item['id'])
        content_result = 'duplicate' if relation == 'same_photo' or (relation == 'derived_photo' and action == 'skip') else 'not_duplicate'
        if approved['content_result'] != content_result or (content_result == 'not_duplicate' and action != 'import'):
            raise ValueError('Inconsistent reviewed content result: ' + item['id'])
        cases.append({key: item[key] for key in ('id', 'group', 'query', 'candidates')} | {
            'expected': {'content_result': content_result, 'relation': relation, 'action': action},
            'reviewed_at': approved['reviewed_at'], 'notes': approved.get('notes', '')})
    result = {'schema_version': 1, 'fixture_version': '2026-10-02-v1', 'status': 'frozen',
              'dataset_id': manifest['dataset_id'], 'manifest_version': manifest['version'],
              'manifest_content_sha256': manifest['content_sha256'],
              'purpose': 'regression_not_threshold_calibration', 'review_file': 'human-review.json',
              'review_sha256': hashlib.sha256(review_bytes).hexdigest(), 'cases': cases}
    result['content_sha256'] = hashlib.sha256(json.dumps(result, sort_keys=True, ensure_ascii=False,
                                                       separators=(',', ':')).encode()).hexdigest()
    return result


def frozen_expectations(directory: Path, manifest: dict) -> dict | None:
    path = directory / 'expected-results.json'
    if not path.exists():
        return None
    result = json.loads(path.read_text())
    expected = reviewed_expectations(manifest, (directory / 'human-review.json').read_bytes())
    if result != expected:
        raise ValueError('Frozen expectations differ from the bound human review')
    return result


def verify_original(source: dict, path: Path) -> None:
    data = path.read_bytes()
    if source.get('sha1') and hashlib.sha1(data).hexdigest() != source['sha1']:
        raise ValueError('Official source SHA1 mismatch: ' + source['id'])
    if source.get('original_sha256') and hashlib.sha256(data).hexdigest() != source['original_sha256']:
        raise ValueError('Original SHA256 mismatch: ' + source['id'])


def fetch(sources: list[dict], cache: Path) -> None:
    cache.mkdir(parents=True, exist_ok=True)
    for source in sources:
        target = cache / (source['id'] + '.original')
        if target.exists():
            verify_original(source, target)
            continue
        request = urllib.request.Request(source['download_url'], headers={
            'User-Agent': 'PhotosYNC-FixtureResearch/0.2 (public regression fixture preparation)'})
        temporary = target.with_suffix('.part')
        time.sleep(5)
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
                    shutil.copyfileobj(response, output)
                break
            except urllib.error.HTTPError as error:
                if error.code != 429 or attempt == 3:
                    raise
                retry_after = error.headers.get('Retry-After', '')
                delay = max(60 * (attempt+1), int(retry_after) if retry_after.isdigit() else 0)
                print(f'Rate limited: {source["id"]}; waiting {delay}s', flush=True)
                time.sleep(delay)
        verify_original(source, temporary)
        temporary.replace(target)
        print('downloaded', source['id'], target.stat().st_size, flush=True)


def fresh_rgb(image: Image.Image) -> Image.Image:
    # No original info/EXIF/XMP/ICC blocks cross this pixel-only boundary.
    oriented = ImageOps.exif_transpose(image).convert('RGB')
    clean = Image.new('RGB', oriented.size)
    clean.paste(oriented)
    return clean


def synthetic_panel(index: int, change: str = 'base') -> Image.Image:
    image = Image.new('RGB', (1024, 768), '#eef2f6')
    draw = ImageDraw.Draw(image)
    font = lambda size: ImageFont.load_default(size=size)
    titles = ['DEPARTURE BOARD', 'RECIPE CARD', 'WEATHER STATION', 'CAMERA SETTINGS',
              'INVENTORY', 'SENSOR CONSOLE', 'TASK BOARD', 'READING LIST',
              'ENERGY MONITOR', 'TRAINING LOG']
    labels = ['Departure', 'Bake time', 'Humidity', 'Shutter', 'Quantity',
              'Pressure', 'Completed', 'Page', 'Output', 'Distance']
    values = ['10:30', '180 C', '62 %', '1/250', '128', '2.40 bar', '7 / 10', '156', '350 W', '8.5 km']
    changes = ['10:38', '160 C', '82 %', '1/125', '129', '2.90 bar', '8 / 10', '158', '850 W', '6.5 km']
    draw.rectangle((0, 0, 1024, 105), fill='#21344a')
    draw.text((36, 30), titles[index], fill='white', font=font(34))
    draw.text((38, 122), 'FICTIONAL TEST DATA / NO REAL ACCOUNT OR LOCATION', fill='#687688', font=font(16))
    draw.rounded_rectangle((34, 164, 990, 352), radius=14, fill='white')
    draw.text((64, 197), labels[index], fill='#52637a', font=font(24))
    draw.text((64, 243), changes[index] if change == 'value' else values[index], fill='#172a40', font=font(46))
    status = 'HOLD' if change == 'status' else 'READY'
    draw.rounded_rectangle((741, 231, 945, 302), radius=10, fill='#e4ecf3')
    draw.text((775, 253), status, fill='#2d4b69', font=font(25))
    draw.rounded_rectangle((34, 379, 990, 681), radius=14, fill='white')
    draw.text((63, 400), 'RECENT SAMPLE VALUES', fill='#52637a', font=font(18))
    for n in range(12):
        height = 55 + ((n * 31 + index * 19) % 145)
        x = 65 + n * 73
        draw.rectangle((x, 636-height, x+41, 636), fill='#7198b7')
    draw.text((39, 711), f'Fixture panel {index+1:02d}  |  sample series 2020-01-01', fill='#687688', font=font(17))
    return image


def image_path(output: Path, image_id: str, fmt: str = 'jpg') -> Path:
    # Baselines intentionally collide by basename, unlike their source identities.
    if image_id.endswith('-base'):
        return output / 'images' / image_id[:-5] / ('IMG_0001.' + fmt)
    return output / 'images' / (image_id + '.' + fmt)


class Corpus:
    def __init__(self, output: Path, sources: list[dict]):
        self.output = output
        self.sources = sources
        self.images: list[dict] = []
        self.cases: list[dict] = []
        (output / 'images').mkdir(parents=True, exist_ok=True)

    def add_image(self, image_id: str, image: Image.Image, source_id: str,
                  kind: str, *, parameters: dict | None = None, fmt: str = 'jpg',
                  quality: int = 92, exif: bytes | None = None, copy_from: Path | None = None) -> str:
        path = image_path(self.output, image_id, fmt)
        path.parent.mkdir(parents=True, exist_ok=True)
        if copy_from:
            shutil.copyfile(copy_from, path)
        else:
            clean = fresh_rgb(image)
            if fmt == 'png':
                clean.save(path, format='PNG', optimize=False)
            else:
                options = {'quality': quality, 'subsampling': 0, 'optimize': False}
                if exif is not None:
                    options['exif'] = exif
                clean.save(path, format='JPEG', **options)
        with Image.open(path) as result:
            width, height = result.size
        self.images.append({'id': image_id, 'file': path.relative_to(self.output).as_posix(),
                            'source_id': source_id, 'family_id': source_id,
                            'width': width, 'height': height, 'sha256': sha256(path),
                            'bytes': path.stat().st_size,
                            'transform': {'kind': kind, **(parameters or {})}})
        return image_id

    def case(self, group: str, title: str, query: str, candidate: str,
             relation: str, action: str, reason: str, split_group: str, *, case_id: str | None = None) -> None:
        number = 1 + sum(c['group'] == group for c in self.cases)
        prefix = {'positive': 'P', 'negative': 'N', 'boundary': 'B'}[group]
        self.cases.append({'id': case_id or f'{prefix}{number:03d}', 'group': group, 'title': title,
                           'query': query, 'candidates': [candidate], 'reason': reason,
                           'proposed': {'relation': relation, 'action': action},
                           'expected': None, 'review_status': 'pending',
                           'split_group': split_group})


def build(sources_path: Path, cache: Path, output: Path) -> None:
    if (output / 'manifest.json').exists():
        raise ValueError('Output already contains a dataset; use a fresh output directory.')
    sources = json.loads(sources_path.read_text())
    if isinstance(sources, dict):
        sources = sources['sources']
    if len(sources) != 20:
        raise ValueError('This reviewed design requires exactly 20 public source photos.')
    corpus = Corpus(output, sources)
    bases = {}
    for source in sources:
        original = cache / (source['id'] + '.original')
        verify_original(source, original)
        original_hash = sha256(original)
        if source.get('original_sha256') and source['original_sha256'] != original_hash:
            raise ValueError('Original checksum mismatch: ' + source['id'])
        source['original_sha256'] = original_hash
        with Image.open(original) as photo:
            clean = fresh_rgb(photo)
        original_size = list(clean.size)
        crop_box = source.get('baseline_crop_box')
        if crop_box:
            left, top, right, bottom = crop_box
            if not (0 <= left < right <= clean.width and 0 <= top < bottom <= clean.height):
                raise ValueError('Invalid privacy crop: ' + source['id'])
            clean = clean.crop(crop_box)
        clean.thumbnail((1280, 1280), Image.Resampling.LANCZOS)
        corpus.add_image(source['id'] + '-base', clean, source['id'], 'sanitized_baseline',
                         parameters={'original_oriented_size': original_size, 'max_edge': 1280,
                                     'jpeg_quality': 92, 'metadata': 'removed',
                                     'baseline_crop_box': crop_box})
        with Image.open(image_path(output, source['id']+'-base')) as baseline:
            bases[source['id']] = baseline.copy()
    # Each adjacent source pair is a deliberately similar real-photo negative.
    for pair_index in range(10):
        left, right = sources[pair_index*2:pair_index*2+2]
        source_id, other_id = left['id'], right['id']
        base = bases[source_id]
        candidate = source_id + '-base'
        split_group = left.get('split_group', f'photo-pair-{pair_index+1:02d}')
        for source in (left, right):
            source['split_group'] = split_group
        half = base.resize((max(1, base.width//2), max(1, base.height//2)), Image.Resampling.LANCZOS)
        exif = Image.Exif()
        exif[270] = 'PhotosYNC fictional metadata fixture'
        exif[305] = 'PhotosYNC Fixture Builder'
        exif[315] = 'Fictional Test Photographer'
        exif[306] = '2020:01:01 12:00:00'
        original_path = image_path(output, candidate)
        # Insert synthetic EXIF into JPEG without recompressing its scan data.
        metadata_id = source_id + '-metadata'
        metadata_path = output / 'images' / (metadata_id + '.jpg')
        if pair_index == 0:
            data = original_path.read_bytes()
            app1 = exif.tobytes()
            metadata_path.write_bytes(data[:2] + b'\xff\xe1' + (len(app1)+2).to_bytes(2, 'big') + app1 + data[2:])
        variants = [
            ('renamed', base, 'jpg', 92, original_path, '改名，文件字节完全相同'),
            ('metadata', base, 'jpg', 92, metadata_path, '仅增加虚构 EXIF，图像码流不变'),
            ('jpeg-q45', base, 'jpg', 45, None, '重新压缩，质量 45'),
            ('half', half, 'jpg', 90, None, '长宽各缩小到一半'),
            ('png', base, 'png', 92, None, 'JPEG 解码后保存为 PNG')]
        for variant_index, (name, image, fmt, quality, copy, title) in enumerate(variants):
            if pair_index > 0 and name in ('renamed', 'metadata'):
                continue
            if pair_index not in (0, 2, 9) and name in ('jpeg-q45', 'half', 'png'):
                continue
            image_id = source_id + '-' + name
            # Avoid SameFileError for the APP1-only metadata output just created.
            if name == 'metadata':
                saved = metadata_path.read_bytes()
                metadata_path.unlink()
                temporary = cache / (source_id + '-synthetic-metadata.jpg')
                temporary.write_bytes(saved)
                copy = temporary
            corpus.add_image(image_id, image, source_id, name, fmt=fmt, quality=quality,
                             copy_from=copy, parameters={'jpeg_quality': quality} if not copy and fmt=='jpg' else {})
            corpus.case('positive', title, image_id, candidate, 'same_photo', 'skip',
                        '同一原图的副本；图库候选的分辨率不低于待导入图片。', split_group,
                        case_id=f'P{pair_index*5+variant_index+1:03d}')
        # Content negatives need one comparison per pair, not repeated encodings.
        # N025 was rejected as too visually different.
        if pair_index != 8:
            corpus.case('negative', f'真实相似照片：{left["pair_title"]} / base', other_id+'-base', candidate,
                        'different_photo', 'import', left['negative_reason'], split_group,
                        case_id=f'N{pair_index*3+1:03d}')
        if pair_index < 4:
            crop_box = (base.width//4, base.height//4, base.width*3//4, base.height*3//4)
            edited_id = corpus.add_image(source_id+'-crop', base.crop(crop_box), source_id,
                                        'crop', parameters={'box': list(crop_box), 'retained_area': 'approximately 25%'})
            corpus.case('boundary', '明显裁剪：同源但构图发生改变', edited_id, candidate, 'derived_photo', 'import',
                        '仅保留约四分之一画面。建议保留为独立编辑版本；请人工决定这类编辑是否应跳过。', split_group, case_id=f'B{pair_index*2+1:03d}')
        elif pair_index < 7:
            edited_id = corpus.add_image(source_id+'-tone', ImageEnhance.Color(base).enhance(0.15), source_id,
                                        'color-desaturate', parameters={'color_factor': 0.15})
            corpus.case('boundary', '明显调色：近灰度的编辑版本', edited_id, candidate, 'derived_photo', 'import',
                        '来自同一原图但色彩明显改变。建议保留编辑版本，请人工确认。', split_group, case_id=f'B{pair_index*2+1:03d}')
        # Rotation cases B015/B017/B019 are deferred pending a product decision.
        if pair_index in (0, 2, 9):
            corpus.case('boundary', '反向比较：图库小图，来源高清', candidate, source_id+'-half', 'same_photo', 'import',
                        '与缩小正例方向相反：来源两边均更大，按 0.2.0 规则应导入高清版本。', split_group,
                        case_id=f'B{pair_index*2+2:03d}')
    for index in range(10):
        source_id = f'synthetic-{index+1:02d}'
        sources.append({'id': source_id, 'title': f'虚构信息面板 {index+1:02d}',
                        'source_url': None, 'download_url': None, 'author': 'PhotosYNC fixture contributors',
                        'license': 'CC0-1.0', 'license_url': 'https://creativecommons.org/publicdomain/zero/1.0/',
                        'license_evidence': 'Original synthetic artwork created for this corpus; CC0 dedication in LICENSES.md.',
                        'split_group': 'synthetic-panels'})
        candidate = corpus.add_image(source_id+'-base', synthetic_panel(index), source_id, 'synthetic-panel', fmt='png')
        for change_index, change in enumerate(('value', 'status')):
            # All status edits are the same READY -> HOLD change; retain N032.
            if change == 'status' and index != 0:
                continue
            query = corpus.add_image(source_id+'-'+change, synthetic_panel(index, change), source_id,
                                     'synthetic-'+change, fmt='png', parameters={'changed_field': change})
            corpus.case('negative', '相似信息面板：' + ('数值变化' if change=='value' else '状态文字变化'),
                        query, candidate, 'different_photo', 'import',
                        '布局和大部分像素相同，但关键文字不同；是不同内容，不能因整体相似而跳过。', 'synthetic-panels',
                        case_id=f'N{31+index*2+change_index:03d}')
    # Removing N025 and B017 leaves both baselines of this coastal pair unused.
    retired_image_ids = {source['id'] + '-base' for source in sources[16:18]}
    for image_id in retired_image_ids:
        image_path(output, image_id).unlink()
    corpus.images = [image for image in corpus.images if image['id'] not in retired_image_ids]
    # User-supplied cases reuse sanitized, fixed assets; never reread Downloads.
    contributions_path = sources_path.parent / 'contributions.json'
    if contributions_path.exists():
        contributions = json.loads(contributions_path.read_text())
        for item in contributions['images']:
            relative = Path(item['file'])
            if relative.is_absolute() or '..' in relative.parts or relative.parts[0] != 'images':
                raise ValueError('Unsafe contribution image path')
            original = contributions_path.parent / relative
            if sha256(original) != item['sha256']:
                raise ValueError('Contribution checksum mismatch: ' + item['id'])
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
        sources.extend(contributions['sources'])
        corpus.images.extend(contributions['images'])
        corpus.cases.extend(contributions['cases'])
        write_json(output / 'contributions.json', contributions)
    manifest = {'schema_version': 1, 'dataset_id': DATASET_ID, 'version': VERSION,
                'status': 'pending_human_review', 'purpose': 'public_regression_not_threshold_calibration',
                'generator': {'script': 'scripts/dedup-fixtures/build.py', 'pillow': pillow_version,
                              'baseline_max_edge': 1280},
                'notes': ['Proposed labels are not ground truth until human approval.',
                          'Variants in a split_group are dependent; never count them as independent trials.',
                          'No Photos library access, no model scores, no network needed for review; user-supplied attachments are recorded separately.',
                          'This public regression corpus must not be reported as a sealed threshold test set.'],
                'sources': sources, 'images': corpus.images, 'cases': corpus.cases}
    migration_path = sources_path.parent / 'review-migration.json'
    if migration_path.exists():
        migration = json.loads(migration_path.read_text())
        by_id = {c['id']: c for c in corpus.cases}
        by_image = {i['id']: i for i in corpus.images}
        for predecessor in [migration, *migration.get('fallbacks', [])]:
            if predecessor['from_dataset_id'] != DATASET_ID:
                raise ValueError('Review migration belongs to a different dataset')
            for case_id, fingerprint in predecessor['unchanged_cases'].items():
                if case_id not in by_id or case_fingerprint(by_id[case_id], by_image) != fingerprint:
                    raise ValueError('Review migration must not reuse changed case: ' + case_id)
        manifest['review_migration'] = migration
    manifest['content_sha256'] = hashlib.sha256(json.dumps(manifest, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    write_json(output / 'manifest.json', manifest)
    if (sources_path.parent / 'expected-results.json').exists():
        # A rebuild may carry frozen labels only when it reproduced their content.
        frozen_expectations(sources_path.parent, manifest)
        for name in ('expected-results.json', 'human-review.json'):
            shutil.copyfile(sources_path.parent / name, output / name)
    render_review(output)
    print(json.dumps({'images': len(corpus.images), 'cases': len(corpus.cases),
                      'image_bytes': sum(i['bytes'] for i in corpus.images)}, indent=2))


def render_review(output: Path) -> None:
    manifest = json.loads((output / 'manifest.json').read_text())
    template = (ROOT / 'scripts/dedup-review-template.html').read_text()
    payload = json.dumps(manifest, ensure_ascii=False).replace('<', '\\u003c').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    if template.count('__MANIFEST_JSON__') != 1:
        raise ValueError('Review template must contain exactly one data placeholder')
    frozen = json.dumps(frozen_expectations(output, manifest), ensure_ascii=False).replace('<', '\\u003c').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    if template.count('__FROZEN_JSON__') != 1:
        raise ValueError('Review template must contain exactly one frozen-label placeholder')
    (output / 'review.html').write_text(template.replace('__MANIFEST_JSON__', payload).replace('__FROZEN_JSON__', frozen))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['fetch', 'build', 'review', 'freeze'])
    parser.add_argument('--reviews', type=Path, help='Human export to freeze; required in freeze mode')
    parser.add_argument('--sources', type=Path, default=DEFAULT_OUTPUT / 'sources.json')
    parser.add_argument('--cache', type=Path, default=ROOT / 'work/dedup-fixtures-originals')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if args.mode == 'fetch':
        data = json.loads(args.sources.read_text())
        fetch(data['sources'] if isinstance(data, dict) else data, args.cache)
    elif args.mode == 'build':
        build(args.sources, args.cache, args.output)
    elif args.mode == 'freeze':
        if not args.reviews:
            parser.error('--reviews is required in freeze mode')
        if any((args.output / name).exists() for name in ('expected-results.json', 'human-review.json')):
            parser.error('Frozen files already exist; create a new fixture version instead of overwriting them')
        from validate import validate
        validate(args.output)
        manifest = json.loads((args.output / 'manifest.json').read_text())
        review_bytes = args.reviews.read_bytes()
        frozen = reviewed_expectations(manifest, review_bytes)
        (args.output / 'human-review.json').write_bytes(review_bytes)
        write_json(args.output / 'expected-results.json', frozen)
        render_review(args.output)
        print(json.dumps(validate(args.output, require_approved=True), ensure_ascii=False, indent=2))
    else:
        render_review(args.output)


if __name__ == '__main__':
    main()
