#!/usr/bin/env python3
"""Tool tests use only freshly drawn images, never downloaded or personal photos."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from PIL import Image, ImageDraw

from build import build, case_fingerprint, render_review, reviewed_expectations
from validate import validate


def rehash_manifest(directory: Path, data: dict) -> None:
    data.pop('content_sha256', None)
    data['content_sha256'] = hashlib.sha256(json.dumps(
        data, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    (directory/'manifest.json').write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n')


class FixtureValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = tempfile.TemporaryDirectory(prefix='photosync-corpus-tools-')
        root = Path(cls.root.name)
        cls.baseline = root/'baseline'
        cache = root/'cache'
        cache.mkdir()
        sources = []
        for n in range(20):
            source_id = f'unit-{n:02d}'
            image = Image.new('RGB', (192,128), (40+n*7,110+n*3,160-n*4))
            ImageDraw.Draw(image).rectangle((n+2,10,n+50,70), fill=(210,80+n*3,20))
            image.save(cache/(source_id+'.original'), format='PNG')
            sources.append({'id': source_id, 'title': 'Synthetic unit test image',
                            'source_url': None, 'download_url': None,
                            'author': 'Unit test', 'license': 'Public domain' if n < 4 else 'CC0-1.0',
                            'license_basis': 'Unit-test public-domain declaration' if n < 4 else 'CC0-1.0',
                            'license_evidence': 'Freshly drawn by this unit test.',
                            'pair_title': f'Unit pair {n//2}', 'negative_reason': 'Different synthetic pixels.'})
        source_path = root/'sources.json'
        source_path.write_text(json.dumps(sources))
        build(source_path, cache, cls.baseline)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.root.cleanup()

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix='photosync-corpus-check-')
        self.directory = Path(self.temp.name)/'dataset'
        shutil.copytree(self.baseline, self.directory)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_complete_synthetic_build_passes_integrity_but_not_human_approval(self) -> None:
        result = validate(self.directory)
        self.assertEqual(result['cases'], 41)
        self.assertEqual(result['groups'], {'positive':11,'negative':20,'boundary':10})
        with self.assertRaisesRegex(ValueError, 'pending human review'):
            validate(self.directory, require_approved=True)

    def test_stale_review_rejected_even_with_valid_new_manifest_hash(self) -> None:
        data = json.loads((self.directory/'manifest.json').read_text())
        data['cases'][0]['reason'] = 'Changed after HTML rendering'
        rehash_manifest(self.directory, data)
        with self.assertRaisesRegex(ValueError, 'Review HTML is stale'):
            validate(self.directory)
        render_review(self.directory)
        self.assertEqual(validate(self.directory)['integrity'], 'passed')

    def test_freeze_binds_complete_review_and_survives_rebuild(self) -> None:
        manifest = json.loads((self.directory / 'manifest.json').read_text())
        review = {key: manifest[key] for key in ('dataset_id', 'version', 'content_sha256')}
        review.update(review_schema_version=2, review_scope='content_only', cases=[])
        for item in manifest['cases']:
            label = item['proposed']
            duplicate = label['relation'] == 'same_photo' or (label['relation'] == 'derived_photo' and label['action'] == 'skip')
            review['cases'].append({key: item[key] for key in ('id', 'group', 'query', 'candidates')} | {
                **label, 'content_result': 'duplicate' if duplicate else 'not_duplicate',
                'review_status': 'approved', 'reviewed_at': '2026-10-02T02:00:00Z', 'notes': ''})
        review_bytes = json.dumps(review).encode()
        frozen = reviewed_expectations(manifest, review_bytes)
        (self.directory / 'human-review.json').write_bytes(review_bytes)
        (self.directory / 'expected-results.json').write_text(json.dumps(frozen))
        render_review(self.directory)
        self.assertEqual(validate(self.directory, require_approved=True)['labels'], '41 approved and frozen')
        inputs = Path(self.temp.name) / 'frozen-inputs'
        inputs.mkdir()
        shutil.copyfile(Path(self.root.name) / 'sources.json', inputs / 'sources.json')
        for name in ('human-review.json', 'expected-results.json'):
            shutil.copyfile(self.directory / name, inputs / name)
        rebuilt = Path(self.temp.name) / 'frozen-rebuilt'
        build(inputs / 'sources.json', Path(self.root.name) / 'cache', rebuilt)
        self.assertEqual(validate(rebuilt, require_approved=True)['labels'], '41 approved and frozen')
        frozen['cases'][0]['expected']['action'] = 'import'
        (self.directory / 'expected-results.json').write_text(json.dumps(frozen))
        with self.assertRaisesRegex(ValueError, 'Frozen expectations differ'):
            validate(self.directory, require_approved=True)
        for failure in ('wrong_hash', 'missing_case', 'duplicate_id', 'pending', 'wrong_reference', 'wrong_result'):
            bad = json.loads(review_bytes)
            if failure == 'wrong_hash': bad['content_sha256'] = '0' * 64
            if failure == 'missing_case': bad['cases'].pop()
            if failure == 'duplicate_id': bad['cases'].append(bad['cases'][0])
            if failure == 'pending': bad['cases'][0]['review_status'] = 'pending'
            if failure == 'wrong_reference': bad['cases'][0]['query'] = 'unreviewed-image'
            if failure == 'wrong_result': bad['cases'][0]['content_result'] = 'not_duplicate'
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                reviewed_expectations(manifest, json.dumps(bad).encode())

    def test_explicit_user_contributions_preserve_approved_labels(self) -> None:
        inputs = Path(self.temp.name) / 'inputs'
        inputs.mkdir()
        shutil.copyfile(Path(self.root.name) / 'sources.json', inputs / 'sources.json')
        baseline = json.loads((self.baseline / 'manifest.json').read_text())
        originals = [i for i in baseline['images'] if i['transform']['kind'] == 'sanitized_baseline'][:6]
        contributions = {'sources': [], 'images': [], 'cases': []}
        for n, original in enumerate(originals):
            source_id = f'user-test-{n}'
            relative = f'images/{source_id}.jpg'
            path = inputs / relative
            path.parent.mkdir(exist_ok=True)
            shutil.copyfile(self.baseline / original['file'], path)
            contributions['images'].append({**original, 'id': source_id, 'file': relative,
                'source_id': source_id, 'family_id': source_id, 'transform': {'kind': 'user-metadata-stripped'}})
            contributions['sources'].append({'id': source_id, 'author': 'Synthetic test author',
                'license': 'User-provided; redistribution license unspecified',
                'license_evidence': 'Synthetic test contribution', 'distribution_status': 'local_testing_only',
                'split_group': f'test-contribution-{n//2}'})
            if n % 2:
                label = {'relation': 'different_photo', 'action': 'import'}
                contributions['cases'].append({'id': f'N{51+n//2:03d}', 'group': 'negative',
                    'title': 'Synthetic user contribution', 'reason': 'Different test images',
                    'query': source_id, 'candidates': [f'user-test-{n-1}'], 'proposed': label,
                    'expected': {'content_result': 'not_duplicate', **label}, 'review_status': 'approved',
                    'approval': {'date': '2026-10-02', 'basis': 'explicit_user_message',
                                 'instruction': '新增三组用例，都判不重'},
                    'split_group': f'test-contribution-{n//2}'})
        (inputs / 'contributions.json').write_text(json.dumps(contributions))
        output = Path(self.temp.name) / 'with-contributions'
        build(inputs / 'sources.json', Path(self.root.name) / 'cache', output)
        self.assertEqual(validate(output)['cases'], 44)
        actual = json.loads((output / 'manifest.json').read_text())
        self.assertEqual(actual['cases'][-3:], contributions['cases'])
        actual['cases'][-1]['expected']['action'] = 'skip'
        rehash_manifest(output, actual)
        render_review(output)
        with self.assertRaisesRegex(ValueError, 'explicit approved non-duplicate'):
            validate(output)
        for field, value in (('basis', 'model_prediction'), ('date', None)):
            with self.subTest(approval_field=field):
                actual['cases'][-1] = json.loads(json.dumps(contributions['cases'][-1]))
                actual['cases'][-1]['approval'][field] = value
                (output / 'contributions.json').write_text(json.dumps({**contributions,
                    'cases': actual['cases'][-3:]}))
                rehash_manifest(output, actual)
                render_review(output)
                with self.assertRaisesRegex(ValueError, 'explicit approved non-duplicate'):
                    validate(output)

    def test_private_exif_rejected_after_image_and_manifest_hashes_are_updated(self) -> None:
        data = json.loads((self.directory/'manifest.json').read_text())
        item = data['images'][0]
        path = self.directory/item['file']
        with Image.open(path) as image:
            copy = image.copy()
        exif = Image.Exif()
        exif[315] = 'Unexpected personal identity'
        copy.save(path, quality=92, exif=exif)
        item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        item['bytes'] = path.stat().st_size
        rehash_manifest(self.directory, data)
        render_review(self.directory)
        with self.assertRaisesRegex(ValueError, 'Unexpected EXIF'):
            validate(self.directory)

    def test_changed_case_cannot_inherit_previous_human_review(self) -> None:
        original = (self.directory/'manifest.json').read_text()
        for fallback in (False, True):
            with self.subTest(fallback=fallback):
                data = json.loads(original)
                first = data['cases'][0]
                predecessor = {
                    'from_dataset_id': data['dataset_id'], 'from_version': 'old',
                    'from_content_sha256': 'a'*64,
                    'unchanged_cases': {first['id']: case_fingerprint(first, {i['id']:i for i in data['images']})}}
                data['review_migration'] = ({**predecessor, 'unchanged_cases': {}, 'fallbacks':[predecessor]}
                                            if fallback else predecessor)
                rehash_manifest(self.directory, data)
                render_review(self.directory)
                self.assertEqual(validate(self.directory)['integrity'], 'passed')
                first['proposed']['action'] = 'import'
                rehash_manifest(self.directory, data)
                render_review(self.directory)
                with self.assertRaisesRegex(ValueError, 'migration references changed case'):
                    validate(self.directory)

    def test_changed_image_bytes_are_rejected(self) -> None:
        data = json.loads((self.directory/'manifest.json').read_text())
        path = self.directory/data['images'][0]['file']
        path.write_bytes(path.read_bytes()+b'tampered')
        with self.assertRaisesRegex(ValueError, 'Hash mismatch'):
            validate(self.directory)


if __name__ == '__main__':
    unittest.main()
