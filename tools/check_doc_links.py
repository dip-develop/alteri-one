#!/usr/bin/env python3
"""Check documentation integrity for the AlteriOne specification.

Two checks, both cheap enough to run on every change:

  check_doc_links.py             relative links and anchors resolve
  check_doc_links.py --orphans   every markdown file is reachable from docs/README.md

Exit code 0 on success, 1 on any finding. No third-party dependencies, because this has to
run in CI before any Dart tooling exists.

Anchor slugs follow GitHub's algorithm: lowercase, drop punctuation other than hyphens,
collapse whitespace to hyphens. Headings containing em dashes therefore generate
ambiguous slugs, which is why none of them carry a number whose slug is linked.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
CODE_FENCE_RE = re.compile(r"^\s*(```|~~~)")
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:")


def find_markdown(root: str) -> list[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {".git", ".dart_tool", "build"}]
        for name in filenames:
            if name.endswith(".md"):
                out.append(os.path.join(dirpath, name))
    return sorted(out)


def strip_code(lines: list[str]) -> list[str]:
    """Drop fenced code blocks, where '#' is a comment, not a heading."""
    out, in_fence = [], False
    for line in lines:
        if CODE_FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return out


def slugify(text: str) -> str:
    text = re.sub(r"`", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text.strip())


def anchors(path: str) -> set[str]:
    out = set()
    with open(path, encoding="utf-8") as handle:
        for line in strip_code(handle.read().split("\n")):
            match = HEADING_RE.match(line)
            if match:
                out.add(slugify(match.group(2)))
    return out


def check_links(root: str, files: list[str]) -> list[str]:
    anchor_map = {path: anchors(path) for path in files}
    findings = []
    for path in files:
        with open(path, encoding="utf-8") as handle:
            for lineno, line in enumerate(handle, 1):
                if CODE_FENCE_RE.match(line):
                    continue
                for target in LINK_RE.findall(line):
                    if target.startswith(EXTERNAL_PREFIXES):
                        continue
                    target_path, _, fragment = target.partition("#")
                    resolved = (
                        path
                        if target_path == ""
                        else os.path.normpath(os.path.join(os.path.dirname(path), target_path))
                    )
                    where = f"{os.path.relpath(path, root)}:{lineno}"
                    if not os.path.exists(resolved):
                        findings.append(f"{where}  {target}  [missing file]")
                    elif fragment and resolved.endswith(".md"):
                        if fragment.lower() not in anchor_map.get(resolved, set()):
                            findings.append(f"{where}  {target}  [missing anchor]")
    return findings


def check_orphans(root: str, files: list[str]) -> list[str]:
    """Every markdown file must be reachable by following links from an entry point.

    Reachability is transitive: docs/decisions/0005-*.md is linked from
    docs/decisions/README.md, which is itself linked from docs/README.md. Checking only
    direct links would report every such file as an orphan.
    """
    entries = [
        os.path.join(root, "docs", "README.md"),
        os.path.join(root, "README.md"),
    ]
    entries = [e for e in entries if os.path.exists(e)]
    if not entries:
        return ["no entry point found; cannot compute reachability"]

    known = set(files)
    seen: set[str] = set()
    queue = list(entries)

    while queue:
        path = queue.pop()
        if path in seen:
            continue
        seen.add(path)
        if path not in known:
            continue
        with open(path, encoding="utf-8") as handle:
            lines = strip_code(handle.read().split("\n"))
        base = os.path.dirname(path)
        for line in lines:
            for target in LINK_RE.findall(line):
                target_path = target.partition("#")[0]
                if not target_path or target_path.startswith(EXTERNAL_PREFIXES):
                    continue
                resolved = os.path.normpath(os.path.join(base, target_path))
                if resolved in known and resolved not in seen:
                    queue.append(resolved)

    return [
        f"{os.path.relpath(path, root)}  [unreachable from any entry point]"
        for path in sorted(known - seen)
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orphans", action="store_true", help="also check reachability")
    parser.add_argument("--root", default=".", help="repository root")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    files = find_markdown(root)
    if not files:
        print("no markdown files found", file=sys.stderr)
        return 1

    findings = check_links(root, files)
    if args.orphans:
        findings += check_orphans(root, files)

    if findings:
        label = "documentation" if args.orphans else "link"
        print(f"{len(findings)} {label} finding(s):", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1

    mode = "links and reachability" if args.orphans else "links and anchors"
    print(f"OK: {mode} verified across {len(files)} markdown files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
