import importlib.util
import json
import http.client
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw


SCRIPT = Path(__file__).resolve().parents[1] / "UIReview/run-native-scenes.py"


class NativeSceneRunnerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "native scene gate must exist")
        spec = importlib.util.spec_from_file_location("native_scene_gate", SCRIPT)
        self.gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.gate)
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_direction_negative_controls_do_not_accept_auto_corrected_text(self):
        upright = Image.new("RGB", (90, 30), "white")
        draw = ImageDraw.Draw(upright)
        for x in (5, 30, 55):
            draw.rectangle((x, 3, x + 4, 25), fill="red")
            draw.rectangle((x, 3, x + 18, 7), fill="red")
            draw.rectangle((x, 12, x + 12, 15), fill="red")
        self.assertTrue(self.gate.upright_match(upright, upright)["passed"])
        for operation in (Image.Transpose.FLIP_TOP_BOTTOM, Image.Transpose.ROTATE_180):
            self.assertFalse(self.gate.upright_match(upright.transpose(operation), upright)["passed"])

    def test_black_or_missing_red_pixels_cannot_pass_orientation(self):
        with self.assertRaisesRegex(ValueError, "red"):
            self.gate.red_lines(Image.new("RGB", (100, 100), "black"))

    def test_review_requires_current_identity_every_frame_and_explicit_verdict(self):
        frame = self.root / "current.png"; frame.write_bytes(b"fixture-image")
        manifest = {"runID":"r", "sourceManifestSHA256":"s", "binarySHA256":"b", "scenarioManifestSHA256":"m",
                    "reviewDeadline":4102444800, "frames":[{"file":frame.name,"sha256":self.gate.digest(frame)}]}
        decisions = {k:manifest[k] for k in self.gate.IDENTITY_FIELDS}
        decisions["frames"] = [{"file":frame.name,"sha256":self.gate.digest(frame),"reviewer":"reviewer","verdict":"pass","comment":"Viewed actual pixels"}]
        self.gate.validate_review(manifest, decisions, self.root)
        for field in self.gate.IDENTITY_FIELDS:
            bad = dict(decisions); bad[field] = "old"
            with self.assertRaises(ValueError): self.gate.validate_review(manifest, bad, self.root)
        for entries in ([], decisions["frames"] * 2, [dict(decisions["frames"][0], verdict="pending")]):
            with self.assertRaises(ValueError): self.gate.validate_review(manifest, dict(decisions, frames=entries), self.root)
        frame.write_bytes(b"changed pixels")
        with self.assertRaises(ValueError): self.gate.validate_review(manifest, decisions, self.root)

    def test_expired_review_and_symlink_capture_are_refused(self):
        outside = self.root / "outside.png"; outside.write_bytes(b"pixels")
        (self.root / "alias.png").symlink_to(outside)
        with self.assertRaises(ValueError): self.gate.regular_child(self.root, "alias.png")
        with self.assertRaises(ValueError): self.gate.regular_child(self.root, "../outside.png")
        manifest = dict.fromkeys(self.gate.IDENTITY_FIELDS, "identity")
        manifest.update(reviewDeadline=1, frames=[])
        with self.assertRaisesRegex(ValueError, "expired"):
            self.gate.validate_review(manifest, dict(manifest), self.root)

    def test_matrix_needs_real_settings_menu_and_hover_without_fallback(self):
        matrix = {"scenarios":[{"id":"U01","steps":["tasksMixed"]}], "appearances":["light"], "requiredMenuFrames":["U01/tasksMixed"]}
        rows = [{"step":"U01/tasksMixed", "appearance":"light", "windowKind":"Settings", "actions":["occluded-window-input-refused"]},
                {"step":"U01/tasksMixed/menu", "appearance":"light", "windowKind":"MenuBarExtra"}]
        self.gate.validate_matrix(rows, matrix)
        with self.assertRaises(ValueError): self.gate.validate_matrix(rows[:1], matrix)
        with self.assertRaises(ValueError): self.gate.validate_matrix(rows * 2, matrix)
        with self.assertRaises(ValueError): self.gate.validate_matrix([dict(rows[0], windowKind="NSHostingView"), rows[1]], matrix)

    def test_hover_requires_positive_hover_evidence_not_just_a_popover_image(self):
        matrix = {"scenarios":[{"id":"U04","steps":["hover-visualIndex"]}], "appearances":["light"], "requiredMenuFrames":[]}
        row = {"step":"U04/hover-visualIndex", "appearance":"light", "windowKind":"Popover",
               "actions":["occluded-window-input-refused", "target-window-hover"], "hoverOpened":True}
        self.gate.validate_matrix([row], matrix)
        for bad in (dict(row, hoverOpened=False), {key:value for key,value in row.items() if key != 'hoverOpened'},
                    dict(row, actions=['occluded-window-input-refused', 'native-press-fallback'])):
            with self.assertRaisesRegex(ValueError, 'hover'):
                self.gate.validate_matrix([bad], matrix)

    def test_xcuitest_configuration_binds_only_the_qa_app_and_owned_run(self):
        template = {"PhotoSyncNativeSceneUITests":{"IsUITestBundle":True,"TestHostPath":"__TESTROOT__/Debug/Runner.app","EnvironmentVariables":{}}}
        result = self.gate.configure_xctestrun(template, products=self.root / "products", output=self.root,
            app=self.root / "QA.app", bundle_id="local.photosync.native-review.run", matrix=self.root / "matrix.json", settings_only=False,
            reply_url='http://127.0.0.1:12345/reply', reply_token='test-token')
        target = result["PhotoSyncNativeSceneUITests"]
        self.assertEqual(target["TestHostPath"], str(self.root / "products/Debug/Runner.app"))
        self.assertEqual(target["UITargetAppPath"], str(self.root / "QA.app"))
        self.assertEqual(target["EnvironmentVariables"]["PHOTOSYNC_NATIVE_OUTPUT"], str(self.root))
        with self.assertRaises(ValueError):
            self.gate.configure_xctestrun(template, products=self.root, output=self.root, app=self.root / "QA.app",
                bundle_id="com.example.PhotoSync", matrix=self.root / "matrix.json", settings_only=False,
                reply_url='http://127.0.0.1:12345/reply', reply_token='test-token')

    def test_ui_build_or_zero_tests_cannot_pass_as_xcuitest_execution(self):
        good = "Test Case '-[PhotoSyncNativeSceneUITests.NativeSceneUITests testNativeScenes]' passed (1 second).\nExecuted 1 test, with 0 failures\n** TEST EXECUTE SUCCEEDED **\n"
        self.gate.validate_xcuitest_log(good)
        for bad in ("** TEST BUILD SUCCEEDED **", good.replace("1 test", "0 tests"), good.replace("passed", "skipped"), good.replace("SUCCEEDED", "FAILED")):
            with self.assertRaises(ValueError): self.gate.validate_xcuitest_log(bad)

    def test_cleanup_matches_exact_owned_executables(self):
        rows = "12 /tmp/owned/QA.app/Contents/MacOS/QA\n13 /tmp/other/QA.app/Contents/MacOS/QA\n14 /tmp/owned/Runner.app/Contents/MacOS/Runner\n"
        self.assertEqual(self.gate.owned_app_pids(rows, {Path('/tmp/owned/QA.app/Contents/MacOS/QA'), Path('/tmp/owned/Runner.app/Contents/MacOS/Runner')}), [12,14])

    def test_unattended_scheme_does_not_include_ui_automation(self):
        schemes = SCRIPT.parents[2] / 'PhotoSync.xcodeproj/xcshareddata/xcschemes'
        def targets(name):
            tree = ET.parse(schemes / (name + '.xcscheme'))
            return [element.attrib['BlueprintName'] for element in tree.findall('.//Testables/TestableReference/BuildableReference')]
        self.assertEqual(targets('PhotoSync'), ['PhotoSyncCoreTests'])
        self.assertEqual(targets('PhotoSyncNativeSceneQA'), ['PhotoSyncNativeSceneUITests'])
        project = (SCRIPT.parents[2] / 'PhotoSync.xcodeproj/project.pbxproj').read_text()
        self.assertRegex(project, r'targets = \(000000000000000000000601,', 'The original app remains the default project target')

    def test_sandbox_reply_channel_only_accepts_current_request_and_token(self):
        request = self.root / 'native-input-request.json'
        request.write_text(json.dumps({'id':'current'}))
        with self.gate.NativeReplyServer(self.root) as server:
            def send(body, token):
                connection = http.client.HTTPConnection('127.0.0.1', server.port, timeout=2)
                try:
                    connection.request('POST','/reply',json.dumps(body),{'X-Photosync-QA-Token':token})
                    response = connection.getresponse(); response.read(); return response.status
                finally: connection.close()
            self.assertEqual(send({'id':'current','success':True},'wrong'),403)
            self.assertFalse((self.root/'native-input-result.json').exists())
            self.assertEqual(send({'id':'stale','success':True},server.token),409)
            self.assertEqual(send({'id':'current','success':True,'path':'../outside'},server.token),400)
            self.assertEqual(send({'id':'current','success':True},server.token),204)
            self.assertEqual(json.loads((self.root/'native-input-result.json').read_text()),{'id':'current','success':True})

    def test_executed_core_change_cannot_be_replaced_by_a_post_run_copy(self):
        app=self.root/'QA.app';binary=app/'Contents/MacOS/QA';core=app/'Contents/Frameworks/PhotoSyncCore.framework/PhotoSyncCore'
        binary.parent.mkdir(parents=True);core.parent.mkdir(parents=True)
        binary.write_bytes(b'unchanged app');core.write_bytes(b'original embedded core')
        expected={'binarySHA256':self.gate.digest(binary),'coreFrameworkSHA256':self.gate.digest(core)}
        self.gate.require_native_identity(app,'QA',expected)
        core.write_bytes(b'updated core during run')
        with self.assertRaisesRegex(ValueError,'identity'):
            self.gate.require_native_identity(app,'QA',expected)


if __name__ == "__main__":
    unittest.main()
