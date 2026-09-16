#!/usr/bin/env python3
"""Register one job keychain without discarding the user's existing search paths."""

from pathlib import Path
import shlex
import subprocess
import sys


def search_paths(text):
    paths = []
    for line in text.splitlines():
        if not line.strip():
            continue
        values = shlex.split(line)
        if len(values) != 1:
            raise ValueError("Malformed keychain search-list entry")
        value = values[0]
        if not Path(value).is_absolute() or any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("Keychain paths must be absolute and contain no control characters")
        paths.append(value)
    if not paths or not any(Path(path).is_file() for path in paths):
        raise ValueError("No existing keychain is reachable; repair the user's search list first")
    return paths


def command(*args):
    return subprocess.check_output(args, text=True)


def register_keychain(keychain, execute=command):
    target = Path(keychain)
    if (
        not target.is_absolute() or not target.is_file()
        or any(ord(character) < 32 or ord(character) == 127 for character in keychain)
    ):
        raise ValueError("The job keychain must already exist at an absolute path")
    target = target.resolve()
    for _ in range(3):
        current = search_paths(execute("security", "list-keychains", "-d", "user"))
        if any(Path(path).resolve() == target for path in current):
            return
        execute("security", "list-keychains", "-d", "user", "-s", *current, str(target))
        observed = search_paths(execute("security", "list-keychains", "-d", "user"))
        if any(Path(path).resolve() == target for path in observed):
            return
    raise RuntimeError("Concurrent search-list changes prevented job-keychain registration")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise ValueError("Usage: keychain-search.py /absolute/job.keychain-db")
    register_keychain(sys.argv[1])
    print("Job signing keychain is registered; existing search paths were preserved.")
