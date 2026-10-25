#!/usr/bin/env python3
"""Stream a command under one inherited deadline; reap only its owned session."""
import argparse
import math
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class Interrupted(Exception):
    pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--package", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout <= 0: parser.error("positive timeout and command required")
    environment = dict(os.environ); environment.pop("RQDATAC2_CONF", None)
    deadline = time.monotonic() + args.timeout
    try:
        if inherited := environment.get("PHOTOSYNC_VALIDATION_DEADLINE"):
            value = float(inherited)
            if not math.isfinite(value): raise ValueError("nonfinite deadline")
            deadline = min(deadline, value)
    except ValueError:
        print("Invalid inherited deadline", file=sys.stderr); return 2
    if deadline <= time.monotonic():
        print("Overall deadline already expired", file=sys.stderr); return 124
    environment["PHOTOSYNC_VALIDATION_DEADLINE"] = str(deadline)
    budget_file = None
    if args.package:
        environment["PHOTOSYNC_PACKAGE_PARENT"] = str(os.getpid())
        descriptor, name = tempfile.mkstemp(prefix="photosync-owned-deadline-")
        os.close(descriptor); budget_file = Path(name); budget_file.write_text(str(deadline))
        environment["PHOTOSYNC_PACKAGE_DEADLINE_FILE"] = str(budget_file)
    def interrupted(signum, frame): raise Interrupted(signum)
    signal.signal(signal.SIGTERM, interrupted); signal.signal(signal.SIGINT, interrupted)
    process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        while True:
            if budget_file is not None:
                try:
                    shortened = float(budget_file.read_text())
                    if math.isfinite(shortened): deadline = min(deadline, shortened)
                except (OSError, ValueError): pass  # A concurrent short write cannot extend the deadline.
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise subprocess.TimeoutExpired(command, args.timeout)
            try: return process.wait(timeout=min(0.2, remaining))
            except subprocess.TimeoutExpired: pass
    except subprocess.TimeoutExpired:
        print("Owned command exceeded its overall time budget", file=sys.stderr); return 124
    except Interrupted:
        return 130
    finally:
        if process.poll() is None:
            signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.signal(signal.SIGINT, signal.SIG_IGN)
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            # The child may be propagating cancellation to its own separately
            # owned sessions (validator -> xctest / native runner -> QA app).
            try: process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                try: os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                process.wait(timeout=1)
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        if budget_file is not None: budget_file.unlink(missing_ok=True)


if __name__ == "__main__": raise SystemExit(main())
