import fcntl
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest


WORKTREE_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = WORKTREE_ROOT / "scripts" / "cleanup-non-candidate-records.py"
PRODUCTION_SNAPSHOT = WORKTREE_ROOT.parent.parent / "work" / "Beta2" / "production-snapshot.sqlite"


class CleanupNonCandidateRecordsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.database = self.root / "fixture.sqlite"
        self.create_database(self.database)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_default_dry_run_counts_only_matching_classification_and_extension_pairs(self) -> None:
        home = self.root / "home"
        default_database = self.default_database(home)
        default_database.parent.mkdir(parents=True)
        shutil.copyfile(self.database, default_database)
        before = self.snapshots(default_database)

        result = self.run_script(home=home)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run: 2 matching non-candidate records", result.stdout)
        self.assertEqual(self.snapshots(default_database), before)
        self.assertFalse(self.instance_lock(home).exists())

    def test_apply_deletes_only_matching_rows_preserves_protected_records_and_creates_backup(self) -> None:
        before = self.snapshots(self.database)
        backup = self.root / "before.sqlite"

        result = self.run_script("--database", str(self.database), "--apply", "--backup", str(backup))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Deleted 2 matching non-candidate records", result.stdout)
        self.assertIn(str(backup), result.stdout)
        self.assertTrue(backup.is_file())
        self.assertEqual(self.count_candidates(self.database), 0)
        self.assertEqual(self.count_candidates(backup), 2)
        self.assertEqual(self.protected_snapshots(self.database), self.protected_from(before))
        self.assertEqual(self.protected_snapshots(backup), self.protected_from(before))
        self.assertEqual(self.integrity_check(backup), "ok")
        self.assertEqual(
            self.non_media_paths(self.database),
            {
                "bad/raw-with-xmp.xmp",
                "bad/sidecar-with-arw.arw",
                "raw/other.cr2",
                "sidecar/other.aae",
                "unsupported/looks-raw.arw",
            },
        )

        repeat_backup = self.root / "repeat.sqlite"
        repeat = self.run_script("--database", str(self.database), "--apply", "--backup", str(repeat_backup))

        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertIn("Deleted 0 matching non-candidate records", repeat.stdout)
        self.assertTrue(repeat_backup.is_file())
        self.assertEqual(self.count_candidates(self.database), 0)

    def test_apply_rolls_back_when_delete_fails(self) -> None:
        before = self.snapshots(self.database)
        with sqlite3.connect(self.database) as connection:
            connection.execute(
                """
                CREATE TRIGGER reject_non_media_cleanup
                BEFORE DELETE ON non_media_skip
                WHEN OLD.disposition = 'raw' AND lower(OLD.relative_path) LIKE '%.arw'
                BEGIN
                    SELECT RAISE(ABORT, 'fixture refuses cleanup');
                END
                """
            )
        backup = self.root / "failed-before.sqlite"

        result = self.run_script("--database", str(self.database), "--apply", "--backup", str(backup))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture refuses cleanup", result.stderr)
        self.assertTrue(backup.is_file())
        self.assertEqual(self.snapshots(self.database), before)
        self.assertEqual(self.integrity_check(self.database), "ok")

    def test_live_database_hardlink_cannot_bypass_the_application_lock(self) -> None:
        home = self.root / "home"
        live_database = self.default_database(home)
        live_database.parent.mkdir(parents=True)
        shutil.copyfile(self.database, live_database)
        hardlink = self.root / "same-live-database.sqlite"
        os.link(live_database, hardlink)
        self.assert_live_alias_is_blocked(home, live_database, hardlink)

    def test_live_database_symlink_cannot_bypass_the_application_lock(self) -> None:
        home = self.root / "home"
        live_database = self.default_database(home)
        live_database.parent.mkdir(parents=True)
        shutil.copyfile(self.database, live_database)
        symlink = self.root / "same-live-database-symlink.sqlite"
        symlink.symlink_to(live_database)
        self.assert_live_alias_is_blocked(home, live_database, symlink)

    def test_explicit_missing_default_path_still_requires_the_application_lock(self) -> None:
        home = self.root / "home"
        default_database = self.default_database(home)
        lock_path = self.instance_lock(home)
        lock_path.parent.mkdir(parents=True)
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result = self.run_script(
                "--database",
                str(default_database),
                "--apply",
                "--backup",
                str(self.root / "must-not-exist.sqlite"),
                home=home,
            )
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PhotosYNC instance lock", result.stderr)
        self.assertFalse((self.root / "must-not-exist.sqlite").exists())

    def assert_live_alias_is_blocked(self, home: Path, live_database: Path, alias: Path) -> None:
        lock_path = self.instance_lock(home)
        lock_path.parent.mkdir(parents=True)
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            result = self.run_script(
                "--database",
                str(alias),
                "--apply",
                "--backup",
                str(self.root / "must-not-exist.sqlite"),
                home=home,
            )
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PhotosYNC instance lock", result.stderr)
        self.assertEqual(self.count_candidates(live_database), 2)
        self.assertFalse((self.root / "must-not-exist.sqlite").exists())

    def test_production_snapshot_is_only_used_after_copying_to_a_temporary_database(self) -> None:
        if not PRODUCTION_SNAPSHOT.is_file():
            self.skipTest("The permitted production snapshot is not present.")
        source_stat = PRODUCTION_SNAPSHOT.stat()
        copied_database = self.root / "production-snapshot-copy.sqlite"
        shutil.copyfile(PRODUCTION_SNAPSHOT, copied_database)
        backup = self.root / "production-snapshot-copy-before.sqlite"

        result = self.run_script("--database", str(copied_database), "--apply", "--backup", str(backup))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(backup.is_file())
        self.assertEqual(PRODUCTION_SNAPSHOT.stat(), source_stat)
        self.assertEqual(self.integrity_check(copied_database), "ok")
        self.assertEqual(self.integrity_check(backup), "ok")

    def run_script(self, *arguments: str, home: Path | None = None) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if home is not None:
            environment["HOME"] = str(home)
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=WORKTREE_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def create_database(self, path: Path) -> None:
        with sqlite3.connect(path) as connection:
            connection.executescript(
                """
                PRAGMA foreign_keys = ON;
                CREATE TABLE source (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    enabled INTEGER NOT NULL,
                    removed INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE file_record (
                    id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL REFERENCES source(id),
                    state TEXT NOT NULL,
                    success_id TEXT,
                    success_metadata_json TEXT,
                    succeeded_at REAL
                );
                CREATE TABLE match_evidence (
                    file_id TEXT NOT NULL REFERENCES file_record(id),
                    candidate_key TEXT NOT NULL,
                    candidate_json TEXT NOT NULL,
                    PRIMARY KEY(file_id, candidate_key)
                );
                CREATE TABLE non_media_skip (
                    source_id TEXT NOT NULL REFERENCES source(id),
                    relative_path TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    modified_ns INTEGER NOT NULL,
                    disposition TEXT NOT NULL,
                    state TEXT NOT NULL,
                    skip_reason TEXT NOT NULL,
                    PRIMARY KEY(source_id, relative_path)
                );
                """
            )
            connection.execute("INSERT INTO source (id, path, enabled, removed) VALUES ('source-1', '/fixture', 1, 0)")
            connection.execute(
                """
                INSERT INTO file_record (id, source_id, state, success_id, success_metadata_json, succeeded_at)
                VALUES ('imported-1', 'source-1', 'imported', 'photos-id-1', '{"filename":"kept.jpg"}', 1.0)
                """
            )
            connection.execute(
                """
                INSERT INTO match_evidence (file_id, candidate_key, candidate_json)
                VALUES ('imported-1', 'photos:kept', '{"filename":"kept.jpg"}')
                """
            )
            records = [
                ("raw/camera.arw", "raw"),
                ("sidecar/edit.XMP", "sidecar"),
                ("raw/other.cr2", "raw"),
                ("sidecar/other.aae", "sidecar"),
                ("bad/raw-with-xmp.xmp", "raw"),
                ("bad/sidecar-with-arw.arw", "sidecar"),
                ("unsupported/looks-raw.arw", "unsupported"),
            ]
            connection.executemany(
                """
                INSERT INTO non_media_skip
                    (source_id, relative_path, size, modified_ns, disposition, state, skip_reason)
                VALUES ('source-1', ?, 1, 1, ?, 'skipped', 'unsupportedFormat')
                """,
                records,
            )

    def default_database(self, home: Path) -> Path:
        return home / "Library" / "Application Support" / "PhotoSync" / "sync.sqlite"

    def instance_lock(self, home: Path) -> Path:
        return (
            home
            / "Library"
            / "Application Support"
            / "PhotoSync Instance Locks"
            / "com.example.PhotoSync"
            / "instance.lock"
        )

    def count_candidates(self, database: Path) -> int:
        with sqlite3.connect(database) as connection:
            return connection.execute(
                """
                SELECT COUNT(*) FROM non_media_skip
                WHERE state = 'skipped' AND (
                    (disposition = 'raw' AND lower(relative_path) LIKE '%.arw') OR
                    (disposition = 'sidecar' AND lower(relative_path) LIKE '%.xmp')
                )
                """
            ).fetchone()[0]

    def non_media_paths(self, database: Path) -> set[str]:
        with sqlite3.connect(database) as connection:
            return {row[0] for row in connection.execute("SELECT relative_path FROM non_media_skip")}

    def snapshots(self, database: Path) -> dict[str, list[tuple[object, ...]]]:
        with sqlite3.connect(database) as connection:
            return {
                "source": connection.execute("SELECT * FROM source ORDER BY id").fetchall(),
                "file_record": connection.execute("SELECT * FROM file_record ORDER BY id").fetchall(),
                "match_evidence": connection.execute(
                    "SELECT * FROM match_evidence ORDER BY file_id, candidate_key"
                ).fetchall(),
                "successful_imports": connection.execute(
                    """
                    SELECT id, source_id, state, success_id, success_metadata_json, succeeded_at
                    FROM file_record WHERE success_id IS NOT NULL ORDER BY id
                    """
                ).fetchall(),
                "non_media_skip": connection.execute(
                    "SELECT * FROM non_media_skip ORDER BY source_id, relative_path"
                ).fetchall(),
            }

    def protected_snapshots(self, database: Path) -> dict[str, list[tuple[object, ...]]]:
        snapshots = self.snapshots(database)
        return self.protected_from(snapshots)

    def protected_from(self, snapshots: dict[str, list[tuple[object, ...]]]) -> dict[str, list[tuple[object, ...]]]:
        return {name: snapshots[name] for name in ("source", "file_record", "match_evidence", "successful_imports")}

    def integrity_check(self, database: Path) -> str:
        with sqlite3.connect(database) as connection:
            return connection.execute("PRAGMA integrity_check").fetchone()[0]


if __name__ == "__main__":
    unittest.main()
