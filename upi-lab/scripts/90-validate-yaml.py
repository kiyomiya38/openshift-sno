#!/usr/bin/env python3
"""Validate non-Ansible YAML and reject duplicate mapping keys."""

from __future__ import annotations

import sys
from pathlib import Path

import yaml


LAB_ROOT = Path(__file__).resolve().parents[1]


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate keys."""


def construct_unique_mapping(
    loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[object, object]:
    mapping: dict[object, object] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_unique_mapping
)


def target_files() -> list[Path]:
    candidates = [
        *LAB_ROOT.glob("configs/*.yaml"),
        *LAB_ROOT.glob("configs/*.yml"),
        *LAB_ROOT.glob("manifests/**/*.yaml"),
        *LAB_ROOT.glob("manifests/**/*.yml"),
    ]
    return sorted(set(candidates))


def main() -> int:
    errors: list[str] = []
    files = target_files()
    for path in files:
        try:
            with path.open(encoding="utf-8") as stream:
                list(yaml.load_all(stream, Loader=UniqueKeyLoader))
        except (OSError, yaml.YAMLError, TypeError) as error:
            errors.append(f"{path.relative_to(LAB_ROOT).as_posix()}: {error}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"YAML validation FAILED: {len(errors)} error(s).", file=sys.stderr)
        return 1

    print(f"YAML validation PASSED: {len(files)} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
