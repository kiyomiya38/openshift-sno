#!/usr/bin/env python3
"""Validate the committed Mermaid sources and rendered diagram artifacts."""

from __future__ import annotations

import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


LAB_ROOT = Path(__file__).resolve().parent.parent
DIAGRAM_ROOT = LAB_ROOT / "diagrams"
EXPECTED = (
    "01-architecture-overview",
    "02-network-az-layout",
    "03-communication-flows",
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


for base_name in EXPECTED:
    mermaid_path = DIAGRAM_ROOT / f"{base_name}.mmd"
    svg_path = DIAGRAM_ROOT / f"{base_name}.svg"
    png_path = DIAGRAM_ROOT / f"{base_name}.png"

    for path in (mermaid_path, svg_path, png_path):
        if not path.is_file() or path.stat().st_size == 0:
            fail(f"Required diagram artifact is missing or empty: {path.relative_to(LAB_ROOT)}")

    source = mermaid_path.read_text(encoding="utf-8")
    if not source.startswith(("flowchart ", "sequenceDiagram")):
        fail(f"Unexpected Mermaid diagram type: {mermaid_path.relative_to(LAB_ROOT)}")

    try:
        svg_root = ET.parse(svg_path).getroot()
    except ET.ParseError as error:
        fail(f"Invalid SVG XML in {svg_path.relative_to(LAB_ROOT)}: {error}")
    if not svg_root.tag.endswith("svg"):
        fail(f"Rendered SVG has an unexpected root element: {svg_path.relative_to(LAB_ROOT)}")

    with png_path.open("rb") as png_file:
        header = png_file.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        fail(f"Rendered PNG has an invalid header: {png_path.relative_to(LAB_ROOT)}")
    width, height = struct.unpack(">II", header[16:24])
    if width < 2000 or height < 1000 or width <= height:
        fail(
            f"Rendered PNG is not a high-resolution landscape image: "
            f"{png_path.relative_to(LAB_ROOT)} ({width}x{height})"
        )

print(f"Diagram validation PASSED: {len(EXPECTED)} Mermaid/SVG/PNG set(s).")
