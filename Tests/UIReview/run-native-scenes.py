#!/usr/bin/env python3
"""Bounded native Settings/MenuBarExtra capture and explicit per-frame review.

This is not a screenshot generator that stamps itself approved. The same process
waits for a separately recorded, current-run review before returning success.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import secrets
import signal
import subprocess
import sys
import time
import threading
from urllib.parse import urlsplit
import uuid

from PIL import Image, ImageChops, ImageStat

IDENTITY_FIELDS = ("runID", "sourceManifestSHA256", "binarySHA256", "scenarioManifestSHA256")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular_child(root: Path, name: str) -> Path:
    path = root / name
    if Path(name).is_absolute() or ".." in Path(name).parts or path.is_symlink() or not path.is_file():
        raise ValueError("Capture must be a regular child file")
    if path.resolve().parent != root.resolve():
        raise ValueError("Capture escaped output directory")
    return path


def red_mask(image: Image.Image) -> Image.Image:
    result = Image.new("L", image.size)
    result.putdata([255 if r > 90 and g < r * 0.73 and b < r * 0.73 else 0 for r, g, b in image.convert("RGB").get_flattened_data()])
    return result


def red_lines(image: Image.Image) -> list[Image.Image]:
    mask = red_mask(image)
    if mask.getbbox() is None:
        raise ValueError("No red text pixels")
    intervals, start, last = [], None, None
    for y in range(mask.height):
        if mask.crop((0, y, mask.width, y + 1)).getbbox():
            if start is None: start = y
            if last is not None and y - last > 3:
                intervals.append((start, last + 1)); start = y
            last = y
    if start is not None: intervals.append((start, last + 1))
    result = []
    for top, bottom in intervals:
        if bottom - top < 5: continue
        line = image.crop((0, top, image.width, bottom))
        box = red_mask(line).getbbox()
        if box and box[2] - box[0] > 30: result.append(line.crop(box))
    if not result: raise ValueError("No red text lines")
    return result


def upright_match(image: Image.Image, reference: Image.Image) -> dict:
    actual, expected = red_mask(image), red_mask(reference)
    if not actual.getbbox() or not expected.getbbox(): raise ValueError("No red orientation evidence")
    actual = actual.crop(actual.getbbox()).resize((512, 48), Image.Resampling.BILINEAR)
    expected = expected.crop(expected.getbbox()).resize((512, 48), Image.Resampling.BILINEAR)
    scores = []
    for variant in (expected, expected.transpose(Image.Transpose.FLIP_TOP_BOTTOM), expected.transpose(Image.Transpose.ROTATE_180)):
        scores.append(ImageStat.Stat(ImageChops.difference(actual, variant)).mean[0] / 255)
    # Compare geometry, not OCR's auto-corrected recognized string. The reference
    # comes from independent AppKit attributed-text drawing on this same machine.
    return {"passed": scores[0] + 0.015 < min(scores[1:]), "uprightError": scores[0], "invertedErrors": scores[1:]}


def validate_matrix(frames: list[dict], matrix: dict, *, settings_only: bool = False) -> None:
    expected = {(s["id"] + "/" + step, appearance, "Popover" if step.startswith("hover-") else "Settings")
                for s in matrix["scenarios"] for step in s["steps"] for appearance in matrix["appearances"]}
    if not settings_only:
        expected |= {(step + "/menu", appearance, "MenuBarExtra") for step in matrix["requiredMenuFrames"] for appearance in matrix["appearances"]}
    actual = [(row["step"], row["appearance"], row["windowKind"]) for row in frames]
    if len(actual) != len(expected) or set(actual) != expected:
        raise ValueError("Missing, duplicate or wrong-kind native scene frames")
    if not settings_only and any(row.get("hoverOpened") is not True or "target-window-hover" not in row.get("actions", [])
                                 for row in frames if row["windowKind"] == "Popover"):
        raise ValueError("Native popovers require positive hover evidence")
    if not settings_only and not any("occluded-window-input-refused" in row.get("actions", []) for row in frames):
        raise ValueError("Native input isolation needs its real occlusion negative control")


def validate_review(manifest: dict, decisions: dict, root: Path, *, check_deadline: bool = True) -> None:
    if check_deadline and time.time() > manifest["reviewDeadline"]: raise ValueError("Native review deadline expired")
    if any(decisions.get(key) != manifest.get(key) for key in IDENTITY_FIELDS):
        raise ValueError("Stale native review identity")
    expected = {row["file"]: row["sha256"] for row in manifest["frames"]}
    rows = decisions.get("frames", [])
    if len(rows) != len(expected) or {row.get("file") for row in rows} != set(expected):
        raise ValueError("Missing or duplicate frame review")
    for row in rows:
        name = row["file"]
        if row.get("verdict") != "pass" or not row.get("reviewer", "").strip() or not row.get("comment", "").strip():
            raise ValueError("Every frame needs a reviewer, explicit pass and observation")
        if row.get("sha256") != expected[name] or digest(regular_child(root, name)) != expected[name]:
            raise ValueError("Reviewed pixels changed")


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def write(path: Path, value) -> None:
    temporary = path.with_name('.' + path.name + '.tmp-' + str(uuid.uuid4()))
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def normalized(text: str) -> str:
    return re.sub(r"[\s,，。.:：()（）‘’“”]", "", text).lower()


def inspect_frames(root: Path, frames: list[dict]) -> None:
    for row in frames:
        if row.get("requestedFocus") and row["windowKind"] == "Settings" and not row.get("appActive"):
            raise ValueError("Foreground UI evidence was actually captured in background")
        path = regular_child(root, row["file"])
        image = Image.open(path).convert("RGB")
        if min(image.size) < 40 or max(ImageStat.Stat(image).stddev) < 3:
            raise ValueError("Empty/black native pixels")
        actual = normalized("".join(row["text"]))
        if not all(normalized(text) in actual for text in row["expectedText"]):
            raise ValueError(f"Native copy mismatch: {row['file']}: {row['text']}")
        widths = [bar["width"] for bar in row.get("taskBars", [])]
        if widths and (min(widths) < 200 or max(widths) - min(widths) > 1):
            raise ValueError("Task tracks must have equal native widths")
        references = row.get("orientationReferences", [])
        if references:
            lines = red_lines(image)
            # Window title's red traffic-light button is too narrow to count.
            if len(lines) != len(references): raise ValueError(f"Unexpected red-text line count: {row['file']}")
            row["orientation"] = [upright_match(line, Image.open(regular_child(root, ref))) for line, ref in zip(lines, references)]
            if not all(result["passed"] for result in row["orientation"]): raise ValueError(f"Text orientation not proved: {row['file']}")
        row["sha256"] = digest(path)


class NativeReplyServer:
    """The sandboxed UI runner sends replies here; it never writes the checkout."""
    def __init__(self, output: Path):
        self.output = output
        self.token = secrets.token_urlsafe(32)
        self.server = None

    def __enter__(self):
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup(); self.connection.settimeout(1)

            def log_message(self, format, *args): pass

            def do_POST(self):
                if self.path != '/reply': self.send_error(404); return
                if not hmac.compare_digest(self.headers.get('X-Photosync-QA-Token', ''), owner.token):
                    self.send_error(403); return
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                    if not 0 < length <= 8192: raise ValueError('Invalid reply length')
                    reply = json.loads(self.rfile.read(length))
                    if (not isinstance(reply, dict) or set(reply) - {'id','success','reason'}
                            or not isinstance(reply.get('id'), str) or type(reply.get('success')) is not bool
                            or ('reason' in reply and (not isinstance(reply['reason'], str) or len(reply['reason']) > 4096))):
                        raise ValueError('Invalid reply')
                    current = json.loads((owner.output / 'native-input-request.json').read_text())
                    if reply['id'] != current.get('id'): self.send_error(409); return
                    write(owner.output / 'native-input-result.json', reply)
                except (OSError, ValueError): self.send_error(400); return
                self.send_response(204); self.end_headers()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        self.url = f'http://127.0.0.1:{self.port}/reply'
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval':0.05}, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *args):
        if self.server is not None:
            self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=1)


def configure_xctestrun(template: dict, *, products: Path, output: Path, app: Path, bundle_id: str,
                        matrix: Path, settings_only: bool, reply_url: str, reply_token: str) -> dict:
    if not bundle_id.startswith('local.photosync.native-review.'):
        raise ValueError('UI testing may only launch the isolated QA identity')
    address = urlsplit(reply_url)
    if address.scheme != 'http' or address.hostname != '127.0.0.1' or address.path != '/reply' or address.port is None or not reply_token:
        raise ValueError('UI replies must use this run\'s loopback channel')
    def resolve(value):
        if isinstance(value, str): return value.replace('__TESTROOT__', str(products))
        if isinstance(value, list): return [resolve(item) for item in value]
        if isinstance(value, dict): return {key:resolve(item) for key,item in value.items()}
        return value
    result = resolve(template)
    targets = [key for key in result if not key.startswith('__')]
    if targets != ['PhotoSyncNativeSceneUITests'] or result[targets[0]].get('IsUITestBundle') is not True:
        raise ValueError('Unexpected Xcode UI test configuration')
    target = result[targets[0]]
    target['UITargetAppPath'] = str(app)
    target.setdefault('EnvironmentVariables', {}).update(
        PHOTOSYNC_NATIVE_OUTPUT=str(output), PHOTOSYNC_NATIVE_MATRIX=str(matrix),
        PHOTOSYNC_NATIVE_APP_ID=bundle_id, PHOTOSYNC_NATIVE_APP_PATH=str(app),
        PHOTOSYNC_NATIVE_REPLY_URL=reply_url, PHOTOSYNC_NATIVE_REPLY_TOKEN=reply_token,
        PHOTOSYNC_NATIVE_SETTINGS_ONLY='1' if settings_only else '0')
    target['TestTimeoutsEnabled'] = True
    target['DefaultTestExecutionTimeAllowance'] = 240
    return result


def validate_xcuitest_log(log: str) -> None:
    passed = re.findall(r"Test Case '-\[PhotoSyncNativeSceneUITests\.NativeSceneUITests testNativeScenes\]' passed", log)
    summaries = re.findall(r'Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures', log)
    if len(passed) != 1 or not summaries or tuple(map(int, summaries[-1])) != (1, 0) or not re.search(r'\*\* TEST(?: EXECUTE)? SUCCEEDED \*\*', log):
        raise ValueError('XCUITest did not complete exactly one passing native scene test')


def owned_app_pids(rows: str, executables: set[Path]) -> list[int]:
    result = []
    for row in rows.splitlines():
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and int(parts[0]) > 1 and Path(parts[1]) in executables:
            result.append(int(parts[0]))
    return result


def native_identity(bundle: Path, executable_name: str) -> dict:
    return {'binarySHA256':digest(bundle / 'Contents/MacOS' / executable_name),
            'coreFrameworkSHA256':digest(bundle / 'Contents/Frameworks/PhotoSyncCore.framework/PhotoSyncCore')}


def require_native_identity(bundle: Path, executable_name: str, expected: dict) -> None:
    if native_identity(bundle, executable_name) != expected:
        raise ValueError('Executed native app/Core identity changed')


def stop_owned_apps(executables: set[Path]) -> None:
    if not executables: return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=0.75)
        pids = owned_app_pids(rows, executables)
        for pid in pids:
            # Each pass takes a fresh snapshot; never match a basename or a
            # remembered PID from a prior run.
            try: os.kill(pid, sig)
            except ProcessLookupError: pass
        if not pids: return
        if sig == signal.SIGTERM: time.sleep(0.3)


def capture(args) -> None:
    repo = Path(__file__).resolve().parents[2]
    output = args.output_dir
    if not output or not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError('Use a new absolute native evidence directory')
    if output.resolve() == repo or repo in output.resolve().parents and repo / 'work' not in output.resolve().parents:
        raise ValueError('Native output must be outside sources or under work/')
    if not args.allow_focus:
        raise ValueError('XCUITest requires explicit --allow-focus, including settings-only diagnostics')
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        raise ValueError('Native timeout must be finite and positive')
    products = args.derived_data / 'Build/Products/Debug'
    core = products / 'PhotoSyncCore.framework'
    if not (core / 'PhotoSyncCore').is_file(): raise ValueError('Current Debug framework is required')
    output.mkdir(parents=True)
    deadline = time.monotonic() + min(args.timeout, 480)
    validator = load_module('photosync_native_source', repo / 'scripts/validate.py')
    validator.install_cancellation_handlers()
    source = validator.build_source_manifest(repo).digest
    run_id = str(uuid.uuid4())
    owner = {'runID':run_id, 'active':True, 'expiresAt':time.time() + 480}
    write(output / 'native-owner.json', owner)
    bundle_id = 'local.photosync.native-review.' + run_id
    bundle = output / 'PhotosYNC Native Review.app'
    matrix_path = repo / 'Tests/UIReview/native-scenarios.json'
    matrix = json.loads(matrix_path.read_text())
    if args.matrix == 'smoke':
        matrix['scenarios'] = [{'id':'U01', 'steps':['taskVisualUnknown', 'tasksMixed']}]
        matrix['appearances'] = ['light']
        matrix['requiredMenuFrames'] = ['U01/tasksMixed']
        matrix_path = output / 'smoke-matrix.json'
        write(matrix_path, matrix)
    input_core_hash = digest(core / 'PhotoSyncCore')
    executables = set()
    lock = args.derived_data / 'native-ui.lock'
    lock_owned = False
    try:
        lock.mkdir(); lock_owned = True
        environment = validator.child_environment()
        def run(command, log, timeout):
            return validator.run_command(command, cwd=repo, environment=environment, log_path=output / log,
                timeout_seconds=timeout, deadline=deadline, label=log)
        run(['xcodebuild', '-project', 'PhotoSync.xcodeproj', '-scheme', 'PhotoSyncNativeSceneQA', '-configuration', 'Debug',
             '-destination', 'platform=macOS', '-derivedDataPath', str(args.derived_data), 'CODE_SIGNING_ALLOWED=YES',
             'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'ENABLE_TESTABILITY=YES', 'ONLY_ACTIVE_ARCH=YES',
             'PHOTOSYNC_NATIVE_BUNDLE_ID=' + bundle_id, 'build-for-testing'], 'build.log', 180)
        built_bundle = products / bundle.name
        info = plistlib.loads((built_bundle / 'Contents/Info.plist').read_bytes())
        executable_name = info['CFBundleExecutable']
        if Path(executable_name).name != executable_name or info['CFBundleIdentifier'] != bundle_id:
            raise ValueError('QA app identity changed during build')
        executable = built_bundle / 'Contents/MacOS' / executable_name
        executed_identity = native_identity(built_bundle, executable_name)
        executables.add(executable)
        configurations = sorted((products.parent).glob('PhotoSyncNativeSceneQA_*.xctestrun'))
        if len(configurations) != 1: raise ValueError('Missing or ambiguous Xcode UI test run file')
        with NativeReplyServer(output) as reply:
            configuration = configure_xctestrun(plistlib.loads(configurations[0].read_bytes()), products=products.parent,
                output=output, app=built_bundle, bundle_id=bundle_id, matrix=matrix_path, settings_only=args.settings_only, reply_url=reply.url, reply_token=reply.token)
            target = configuration['PhotoSyncNativeSceneUITests']
            restarts = sum(scenario['steps'].count('memory-change') for scenario in matrix['scenarios']) * len(matrix['appearances'])
            target['EnvironmentVariables']['PHOTOSYNC_NATIVE_EXPECTED_RESTARTS'] = str(restarts)
            host = Path(target['TestHostPath'])
            host_info = plistlib.loads((host / 'Contents/Info.plist').read_bytes())
            if host_info['CFBundleIdentifier'] != bundle_id + '.uitests.xctrunner': raise ValueError('UI runner identity mismatch')
            executables.add(host / 'Contents/MacOS' / host_info['CFBundleExecutable'])
            runfile = output / 'native.xctestrun'; runfile.write_bytes(plistlib.dumps(configuration))
            owner['expiresAt'] = time.time() + min(270, max(0, deadline - time.monotonic()))
            write(output / 'native-owner.json', owner)
            run(['xcodebuild', 'test-without-building', '-xctestrun', str(runfile), '-destination', 'platform=macOS',
                 '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '240',
                 '-maximum-test-execution-time-allowance', '240', '-only-testing:PhotoSyncNativeSceneUITests/NativeSceneUITests/testNativeScenes',
                 '-resultBundlePath', str(output / 'native.xcresult')], 'xctest.log', 280)
        validate_xcuitest_log((output / 'xctest.log').read_text(errors='replace'))
        observed = json.loads((output / 'native-captures.json').read_text())
        if observed.get('status') != 'captured': raise ValueError('Native scene failed: ' + observed.get('reason', 'unknown'))
        frames = observed['frames']
        validate_matrix(frames, matrix, settings_only=args.settings_only)
        inspect_frames(output, frames)
        # XCUIApplication(bundleIdentifier:) launches Xcode's registered product.
        # Archive a byte-identical evidence copy only after the real run, so a
        # second same-identity app cannot change LaunchServices resolution.
        require_native_identity(built_bundle, executable_name, executed_identity)
        run(['ditto', str(built_bundle), str(bundle)], 'copy.log', 30)
        require_native_identity(bundle, executable_name, executed_identity)
        if validator.build_source_manifest(repo).digest != source: raise ValueError('Sources changed during native capture')
        owner['active'] = False
        write(output / 'native-owner.json', owner)
        stop_owned_apps(executables)
        executables.clear()
        manifest = {'runID':run_id, 'sourceManifestSHA256':source, **executed_identity,
                    'scenarioManifestSHA256':digest(matrix_path), 'inputCoreFrameworkSHA256':input_core_hash,
                    'engine':'xcuitest', 'appExecutable':executable_name, 'uiTestLogSHA256':digest(output / 'xctest.log'),
                    'status':'pending_review', 'scope':'smoke' if args.matrix == 'smoke' else observed['scope'], 'reviewStartedAt':time.time(),
                    'reviewDeadline':time.time() + min(180, max(0, deadline - time.monotonic())), 'frames':frames}
        write(output / 'native-scenes.json', manifest)
        decisions = {key:manifest[key] for key in IDENTITY_FIELDS}
        decisions['frames'] = [{'file':row['file'], 'sha256':row['sha256'], 'reviewer':'', 'verdict':'pending', 'comment':''} for row in frames]
        write(output / 'review-decisions.json', decisions)
        page = '<!doctype html><meta charset="utf-8"><title>Native UI review</title><style>body{font:15px system-ui;margin:20px}img{max-width:600px}figure{display:inline-block;vertical-align:top}figcaption{white-space:pre-wrap}</style>'
        for row in frames:
            page += f'<figure><figcaption>{html.escape(row["step"] + " / " + row["appearance"] + " / " + row["windowKind"])}</figcaption><img src="{html.escape(row["file"])}"></figure>'
        (output / 'index.html').write_text(page)
        print(f"NATIVE_REVIEW_PENDING {output / 'native-scenes.json'}", flush=True)
        print(f"Review actual pixels in {output / 'index.html'}, then submit review-decisions.json using --record-review and --manifest.", flush=True)
        while time.monotonic() < deadline and time.time() <= manifest['reviewDeadline']:
            receipt = output / 'ui-review.json'
            if receipt.is_file():
                validate_review(manifest, json.loads(receipt.read_text()), output)
                manifest['status'] = 'passed'; manifest['review'] = {'file':'ui-review.json', 'sha256':digest(receipt)}
                write(output / 'native-scenes.json', manifest)
                print('Native scene review passed' + (' (focused settings only)' if args.settings_only else ''), flush=True)
                return
            time.sleep(0.2)
        raise TimeoutError('Native review missing within 180 seconds')
    finally:
        owner['active'] = False
        write(output / 'native-owner.json', owner)
        try: stop_owned_apps(executables)
        finally:
            if lock_owned: lock.rmdir()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--matrix", choices=["critical", "smoke"], default="critical")
    parser.add_argument("--allow-focus", action="store_true")
    parser.add_argument("--settings-only", action="store_true")
    parser.add_argument("--timeout", type=float, default=480)
    parser.add_argument("--record-review", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    try:
        if args.record_review:
            if not args.manifest: raise ValueError("--manifest is required")
            manifest, decisions = json.loads(args.manifest.read_text()), json.loads(args.record_review.read_text())
            validate_review(manifest, decisions, args.manifest.parent)
            decisions["reviewedAt"] = time.time()
            write(args.manifest.parent / "ui-review.json", decisions)
        else:
            if not args.derived_data: raise ValueError("--derived-data is required")
            capture(args)
        return 0
    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        if args.output_dir and args.output_dir.is_dir(): write(args.output_dir / "native-failure.json", {"status":"failed", "reason":str(error)})
        print(f"Native scene validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
