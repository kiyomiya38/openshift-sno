#!/usr/bin/env python3
"""Offline Markdown structure and repository-local link validation."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


LAB_ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_PARTS = {".git", ".terraform", "artifacts", "dist", "logs"}
LINK_RE = re.compile(r"!?(?:\[[^\]]*\])\(([^)]+)\)")
SCRIPT_RE = re.compile(r"(?<![\w/])(scripts/[A-Za-z0-9_.\-/]+\.sh)(?![\w/])")
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")
WINDOWS_ABSOLUTE_RE = re.compile(r"^[A-Za-z]:[\\/]")


def markdown_files() -> list[Path]:
    return sorted(
        path
        for path in LAB_ROOT.rglob("*.md")
        if not EXCLUDED_PARTS.intersection(path.relative_to(LAB_ROOT).parts)
    )


def normalize_link(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        return target[1 : target.index(">")]
    # A quoted title can follow a path. Repository paths in this project do
    # not contain unescaped spaces, so splitting here is deliberately strict.
    return target.split(maxsplit=1)[0]


def validate_file(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    relative = path.relative_to(LAB_ROOT).as_posix()

    open_fence: tuple[str, int, int] | None = None
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = FENCE_RE.match(line)
        if not match:
            continue
        marker = match.group(1)
        if open_fence is None:
            open_fence = (marker[0], len(marker), line_number)
        elif marker[0] == open_fence[0] and len(marker) >= open_fence[1]:
            open_fence = None

    if open_fence is not None:
        errors.append(f"{relative}:{open_fence[2]}: unclosed Markdown fence")

    for match in LINK_RE.finditer(text):
        target = normalize_link(match.group(1))
        if not target or target.startswith(("#", "https://", "http://", "mailto:", "data:")):
            continue
        if target.startswith("file+") or WINDOWS_ABSOLUTE_RE.match(target):
            line_number = text.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line_number}: non-portable link: {target}")
            continue

        parsed = urlsplit(target)
        if parsed.scheme:
            continue
        local_path = unquote(parsed.path).replace("\\", "/")
        if not local_path:
            continue
        candidate = (LAB_ROOT / local_path.lstrip("/")) if local_path.startswith("/") else (path.parent / local_path)
        if not candidate.resolve().exists():
            line_number = text.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line_number}: missing local link target: {target}")

    for match in SCRIPT_RE.finditer(text):
        script_path = LAB_ROOT / match.group(1)
        if not script_path.is_file():
            line_number = text.count("\n", 0, match.start()) + 1
            errors.append(f"{relative}:{line_number}: missing referenced script: {match.group(1)}")

    return errors


def main() -> int:
    files = markdown_files()
    errors = [error for path in files for error in validate_file(path)]
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Markdown validation FAILED: {len(errors)} error(s).", file=sys.stderr)
        return 1

    print(f"Markdown validation PASSED: {len(files)} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
