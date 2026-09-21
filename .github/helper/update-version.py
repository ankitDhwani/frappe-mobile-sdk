#!/usr/bin/env python3
"""
Bump Flutter package versions for semantic-release.

Updates:
- `pubspec.yaml` version -> <nextRelease.version>
- `example/pubspec.yaml` version -> <nextRelease.version>-dev for a stable
  release, or <nextRelease.version> verbatim when the release is already a
  prerelease. See `example_version_for`.
- `example/pubspec.lock`, the `frappe_mobile_sdk` entry's recorded version ->
  <nextRelease.version>. See `update_example_lock_sdk_version`.
"""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]


def update_file_version(path: pathlib.Path, new_version: str) -> bool:
    content = path.read_text(encoding="utf-8")

    # Matches: version: 1.2.3 or version: 1.2.3-dev
    # Captures the key + whitespace so we preserve formatting.
    pattern = re.compile(r"^(version:\s*)([^\r\n#]+)$", re.MULTILINE)
    if not pattern.search(content):
        raise RuntimeError(f"Could not find `version:` in {path}")

    updated = pattern.sub(rf"\g<1>{new_version}", content)
    if updated != content:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


def example_version_for(new_version: str) -> str:
    """Version to stamp on the (unpublished) example app.

    For a stable release the example trails it: `2.1.0` -> `2.1.0-dev`, which
    sorts BELOW `2.1.0` and so reads as "a dev build on the way to 2.1.0".

    That suffix inverts on a prerelease and must not be applied there. Measured
    with `pub_semver`, every way of appending a marker to `2.0.0-beta.4` sorts
    ABOVE it -- `-dev` and `.dev` because they add a prerelease identifier, and
    `+dev` because pub (unlike SemVer 2.0 section 10) ranks build metadata
    rather than ignoring it. So there is no suffix that keeps the "trails the
    release" meaning, and the example would instead claim to be newer than the
    SDK it ships with.

    The example sets `publish_to: none`, so nothing resolves against this and
    the cost is only that a reader is misled. Using the release version verbatim
    is what the hand-cut `2.0.0-beta.3` release already did, so this also makes
    the helper agree with the tree it is bumping.
    """
    core, _, build = new_version.partition("+")
    if "-" in core:
        return new_version
    # `-dev` is a prerelease marker and must precede any build metadata:
    # `3.0.0+7` -> `3.0.0-dev+7`, never `3.0.0+7-dev` (which would read as the
    # build being called `7-dev`). semantic-release does not emit build
    # metadata, so this is belt-and-braces rather than a path we exercise.
    return f"{core}-dev+{build}" if build else f"{core}-dev"


def update_example_lock_sdk_version(path: pathlib.Path, new_version: str) -> bool:
    """Keep `example/pubspec.lock`'s record of the SDK in step with the bump.

    The example resolves the SDK through a `path: ..` override, and pub records
    the resolved version of a path source in the lockfile. Nothing in the
    release run re-resolves, so without this the lock keeps naming the PREVIOUS
    release forever -- it sat at `2.0.0-beta.2` through the whole beta.3 cycle.

    Cosmetic in the sense that a path source resolves by path and never by the
    recorded version, so no build reads it. It is still worth writing, because a
    lockfile that disagrees with the pubspec beside it is read as a mistake by
    whoever finds it next.

    Edited textually rather than through a YAML round-trip on purpose: rewriting
    the file would reorder and reformat 400-odd entries, burying a one-line
    change in noise no reviewer can check. Returns False if the entry is absent
    (the override was removed, or the lockfile is not there), so this never
    fails a release over a file that is not load-bearing.
    """
    if not path.exists():
        return False

    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    try:
        start = next(i for i, ln in enumerate(lines) if ln.rstrip() == "  frappe_mobile_sdk:")
    except StopIteration:
        return False

    # Scan the entry's own indented body only: the next line at column 2 starts
    # the following package, and running past it would rewrite ITS version.
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if line.strip() and not line.startswith("    "):
            break
        if line.startswith("    version:"):
            replacement = f'    version: "{new_version}"\n'
            if lines[i] == replacement:
                return False
            lines[i] = replacement
            path.write_text("".join(lines), encoding="utf-8")
            return True
    return False


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python .github/helper/update-version.py <new_version>")
        sys.exit(1)

    new_version = sys.argv[1].strip()
    if not new_version:
        raise RuntimeError("New version is empty")

    pubspec = ROOT / "pubspec.yaml"
    example_pubspec = ROOT / "example" / "pubspec.yaml"

    changed_any = False

    changed_any |= update_file_version(pubspec, new_version)

    example_version = example_version_for(new_version)
    changed_any |= update_file_version(example_pubspec, example_version)

    # The lock records the SDK itself (path source), so it takes the SDK's
    # version, not the example's `-dev` one.
    changed_any |= update_example_lock_sdk_version(
        ROOT / "example" / "pubspec.lock", new_version
    )

    if changed_any:
        print(f"Bumped versions to {new_version}")
    else:
        print("Versions already up to date")


if __name__ == "__main__":
    main()
