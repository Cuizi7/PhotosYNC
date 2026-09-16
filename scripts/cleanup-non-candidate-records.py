#!/usr/bin/env python3
"""Remove obsolete ARW/XMP attribute-only records from a PhotosYNC SQLite copy.

The default target is the live PhotosYNC database. It is dry-run only unless
``--apply`` and an explicit backup path are supplied. An explicit ``--database``
path supports work on an isolated copy; aliases of the live database still take
the application's instance lock before any write.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import sqlite3
import sys
from typing import Iterator, Sequence


APPLICATION_IDENTIFIER = "com.example.PhotoSync"
APPLICATION_SUPPORT_COMPONENTS = ("Library", "Application Support")
DATABASE_COMPONENTS = (*APPLICATION_SUPPORT_COMPONENTS, "PhotoSync", "sync.sqlite")
LOCK_COMPONENTS = (
    *APPLICATION_SUPPORT_COMPONENTS,
    "PhotoSync Instance Locks",
    APPLICATION_IDENTIFIER,
    "instance.lock",
)

COUNT_MATCHES_SQL = """
SELECT
    COALESCE(SUM(CASE
        WHEN disposition = 'raw' AND lower(relative_path) LIKE '%.arw' THEN 1
        ELSE 0
    END), 0),
    COALESCE(SUM(CASE
        WHEN disposition = 'sidecar' AND lower(relative_path) LIKE '%.xmp' THEN 1
        ELSE 0
    END), 0)
FROM non_media_skip
WHERE state = 'skipped'
"""

DELETE_MATCHES_SQL = """
DELETE FROM non_media_skip
WHERE state = 'skipped' AND (
    (disposition = 'raw' AND lower(relative_path) LIKE '%.arw') OR
    (disposition = 'sidecar' AND lower(relative_path) LIKE '%.xmp')
)
"""


class CleanupError(RuntimeError):
    """A refusal or verification failure that must not expose a traceback."""


@dataclass(frozen=True)
class MatchCounts:
    arw: int
    xmp: int

    @property
    def total(self) -> int:
        return self.arw + self.xmp


@dataclass(frozen=True)
class QueryFingerprint:
    rows: int
    digest: str


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argument_parser()
    args = parser.parse_args(arguments)
    if args.backup is not None and not args.apply:
        parser.error("--backup requires --apply.")
    if args.apply and args.backup is None:
        parser.error("--apply requires --backup PATH so a consistent pre-cleanup copy is retained.")

    default_database = live_database_path()
    database = expanded_path(args.database) if args.database is not None else default_database
    backup = expanded_path(args.backup) if args.backup is not None else None

    try:
        if not args.apply:
            counts = dry_run(database)
            print(format_dry_run(counts, database))
            return 0

        assert backup is not None
        result = apply_cleanup(
            database=database,
            backup=backup,
            requires_live_lock=targets_live_database(
                database=database,
                default_database=default_database,
                is_default_target=args.database is None,
            ),
        )
        print(f"Backup created with SQLite backup API: {backup}")
        print(
            "Deleted "
            f"{result.counts.total} matching non-candidate records "
            f"(ARW: {result.counts.arw}, XMP: {result.counts.xmp})."
        )
        print(
            "Verification passed: source, file_record, match_evidence, and successful import "
            "relationships are unchanged; integrity_check and foreign_key_check are clean."
        )
        return 0
    except (CleanupError, OSError, sqlite3.Error) as error:
        print(f"Cleanup refused: {error}", file=sys.stderr)
        return 1


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Remove only obsolete non_media_skip records whose stored disposition and path suffix "
            "both identify .arw or .xmp files."
        )
    )
    parser.add_argument(
        "--database",
        type=Path,
        help=(
            "SQLite target. Use an explicit copied database for isolated cleanup. A symlink or "
            "hardlink to the live default database still requires the PhotosYNC instance lock."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Delete matching records after creating and verifying a SQLite backup.",
    )
    parser.add_argument(
        "--backup",
        type=Path,
        help="New path for the pre-cleanup SQLite backup. Required with --apply.",
    )
    return parser


def expanded_path(path: Path) -> Path:
    return Path(os.path.abspath(os.path.expanduser(os.fspath(path))))


def live_database_path() -> Path:
    return Path.home().joinpath(*DATABASE_COMPONENTS)


def live_lock_path() -> Path:
    return Path.home().joinpath(*LOCK_COMPONENTS)


def targets_live_database(
    *, database: Path, default_database: Path, is_default_target: bool
) -> bool:
    if is_default_target or normalized_path(database) == normalized_path(default_database):
        return True
    try:
        return os.path.samefile(database, default_database)
    except OSError:
        return False


def normalized_path(path: Path) -> str:
    return os.path.normcase(os.path.abspath(os.fspath(path)))


def dry_run(database: Path) -> MatchCounts:
    with open_database(database, mode="ro") as connection:
        return matching_counts(connection)


def format_dry_run(counts: MatchCounts, database: Path) -> str:
    return (
        f"Dry run: {counts.total} matching non-candidate records "
        f"(ARW: {counts.arw}, XMP: {counts.xmp}) in {database}.\n"
        "No database changes were made. Re-run with --apply --backup PATH to clean this target."
    )


@dataclass(frozen=True)
class ApplyResult:
    counts: MatchCounts


def apply_cleanup(*, database: Path, backup: Path, requires_live_lock: bool) -> ApplyResult:
    with live_lock_if_required(requires_live_lock):
        with open_database(database, mode="rw", isolation_level=None) as connection:
            before = protected_fingerprints(connection)
            create_consistent_backup(connection, backup)
            verify_database(backup)
            counts = delete_matches_and_verify(connection, before)
    return ApplyResult(counts=counts)


@contextmanager
def live_lock_if_required(required: bool) -> Iterator[None]:
    if not required:
        yield
        return

    lock_path = live_lock_path()
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise CleanupError(
            f"Could not prepare the PhotosYNC instance lock directory at {lock_path.parent}: {error.strerror}."
        ) from error

    flags = os.O_CREAT | os.O_RDWR
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise CleanupError(
            f"Could not open the PhotosYNC instance lock at {lock_path}: {error.strerror}."
        ) from error

    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise CleanupError(
                    "The PhotosYNC instance lock is held. Quit PhotosYNC before cleaning the live database."
                ) from error
            raise CleanupError(
                f"Could not acquire the PhotosYNC instance lock at {lock_path}: {error.strerror}."
            ) from error
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


@contextmanager
def open_database(database: Path, *, mode: str, isolation_level: str | None = "DEFERRED") -> Iterator[sqlite3.Connection]:
    try:
        connection = sqlite3.connect(database_uri(database, mode), uri=True, isolation_level=isolation_level)
    except sqlite3.Error as error:
        raise CleanupError(f"Could not open database {database} in {mode} mode: {error}.") from error
    try:
        yield connection
    finally:
        connection.close()


def database_uri(database: Path, mode: str) -> str:
    return f"{database.as_uri()}?mode={mode}"


def matching_counts(connection: sqlite3.Connection) -> MatchCounts:
    row = connection.execute(COUNT_MATCHES_SQL).fetchone()
    if row is None:
        raise CleanupError("Could not count matching non-candidate records.")
    return MatchCounts(arw=int(row[0]), xmp=int(row[1]))


def create_consistent_backup(source: sqlite3.Connection, backup: Path) -> None:
    if os.path.lexists(backup):
        raise CleanupError(f"Backup path already exists: {backup}.")
    if not backup.parent.is_dir():
        raise CleanupError(f"Backup directory does not exist: {backup.parent}.")

    descriptor: int | None = None
    destination: sqlite3.Connection | None = None
    created = False
    try:
        descriptor = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        created = True
        os.close(descriptor)
        descriptor = None
        destination = sqlite3.connect(database_uri(backup, mode="rw"), uri=True)
        source.backup(destination)
    except (OSError, sqlite3.Error) as error:
        if descriptor is not None:
            os.close(descriptor)
        if destination is not None:
            destination.close()
        if created:
            try:
                backup.unlink()
            except OSError:
                pass
        raise CleanupError(f"Could not create a consistent SQLite backup at {backup}: {error}.") from error
    else:
        assert destination is not None
        destination.close()


def delete_matches_and_verify(
    connection: sqlite3.Connection, before: dict[str, QueryFingerprint]
) -> MatchCounts:
    transaction_started = False
    try:
        connection.execute("BEGIN IMMEDIATE")
        transaction_started = True
        counts = matching_counts(connection)
        deleted = connection.execute(DELETE_MATCHES_SQL).rowcount
        if deleted != counts.total:
            raise CleanupError(
                "The cleanup delete count did not match the classified ARW/XMP count; "
                "the transaction will be rolled back."
            )
        after = protected_fingerprints(connection)
        if after != before:
            raise CleanupError("Protected records changed during cleanup; the transaction will be rolled back.")
        verify_connection(connection)
        connection.execute("COMMIT")
        transaction_started = False
        return counts
    except Exception as error:
        if transaction_started:
            try:
                connection.execute("ROLLBACK")
            except sqlite3.Error as rollback_error:
                raise CleanupError(
                    f"Cleanup failed ({error}) and the SQLite rollback also failed ({rollback_error})."
                ) from rollback_error
        if isinstance(error, CleanupError):
            raise
        raise CleanupError(f"Cleanup transaction was rolled back: {error}.") from error


def protected_fingerprints(connection: sqlite3.Connection) -> dict[str, QueryFingerprint]:
    return {
        "source": fingerprint_query(connection, "SELECT * FROM source ORDER BY rowid"),
        "file_record": fingerprint_query(connection, "SELECT * FROM file_record ORDER BY rowid"),
        "match_evidence": fingerprint_query(connection, "SELECT * FROM match_evidence ORDER BY rowid"),
        "successful_import_relationships": fingerprint_query(
            connection,
            """
            SELECT id, source_id, state, success_id, success_metadata_json, succeeded_at
            FROM file_record
            WHERE success_id IS NOT NULL
            ORDER BY id
            """,
        ),
    }


def fingerprint_query(connection: sqlite3.Connection, query: str) -> QueryFingerprint:
    cursor = connection.execute(query)
    digest = hashlib.sha256()
    for column in cursor.description:
        update_digest_value(digest, column[0])
    rows = 0
    for row in cursor:
        digest.update(b"R")
        for value in row:
            update_digest_value(digest, value)
        rows += 1
    return QueryFingerprint(rows=rows, digest=digest.hexdigest())


def update_digest_value(digest, value: object) -> None:
    if value is None:
        digest.update(b"N")
        return
    if isinstance(value, bytes):
        digest.update(b"B")
        update_digest_bytes(digest, value)
        return
    if isinstance(value, str):
        digest.update(b"T")
        update_digest_bytes(digest, value.encode("utf-8"))
        return
    if isinstance(value, int):
        digest.update(b"I")
        update_digest_bytes(digest, str(value).encode("ascii"))
        return
    if isinstance(value, float):
        digest.update(b"F")
        update_digest_bytes(digest, value.hex().encode("ascii"))
        return
    raise CleanupError(f"Unsupported SQLite value type while verifying protected records: {type(value).__name__}.")


def update_digest_bytes(digest, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def verify_database(database: Path) -> None:
    with open_database(database, mode="ro") as connection:
        verify_connection(connection)


def verify_connection(connection: sqlite3.Connection) -> None:
    integrity_rows = [row[0] for row in connection.execute("PRAGMA integrity_check")]
    if integrity_rows != ["ok"]:
        raise CleanupError(f"SQLite integrity_check failed: {integrity_rows!r}.")
    foreign_key_rows = connection.execute("PRAGMA foreign_key_check").fetchall()
    if foreign_key_rows:
        raise CleanupError(f"SQLite foreign_key_check failed: {foreign_key_rows!r}.")


if __name__ == "__main__":
    raise SystemExit(main())
