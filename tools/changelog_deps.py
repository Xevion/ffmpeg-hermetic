#!/usr/bin/env python3
"""Prints the CHANGELOG's library section from the MANIFEST.json of two sets of bundles.

usage: tools/changelog_deps.py [--old BUNDLE...] --new BUNDLE...

Each BUNDLE is a bundle directory, its MANIFEST.json, or its .tar.zst. The sources of every
bundle in a set are merged, so passing both an LGPL and a GPL bundle covers every library.
Without --old, the whole new set is printed as one table (a first release); with it, only
what was added, updated or removed.
"""
import argparse
import json
import pathlib
import subprocess
import sys


def manifest(path: pathlib.Path) -> dict:
    if path.is_dir():
        path = path / "MANIFEST.json"
    if path.name.endswith(".tar.zst"):
        data = subprocess.run(
            ["tar", "--zstd", "-xOf", str(path), "--wildcards", "*/MANIFEST.json"],
            check=True, capture_output=True,
        ).stdout
        return json.loads(data)
    return json.loads(path.read_text())


def sources(paths: list[str]) -> dict[str, dict]:
    merged: dict[str, dict] = {}
    by_variant: dict[str, dict[str, str]] = {}
    for p in paths:
        m = manifest(pathlib.Path(p))
        for s in m["sources"]:
            seen = merged.get(s["name"])
            if seen and seen["version"] != s["version"]:
                sys.exit(f"{s['name']}: {seen['version']} and {s['version']} in one set")
            merged[s["name"]] = s
            by_variant.setdefault(s["name"], {})[m["variant"]] = s["license"]
    for name, licenses in by_variant.items():
        if len(set(licenses.values())) > 1:
            merged[name] = merged[name] | {"license": ", ".join(f"{v}: {lic}" for v, lic in sorted(licenses.items(), reverse=True))}
    return merged


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--old", nargs="+", default=[])
    ap.add_argument("--new", nargs="+", required=True)
    args = ap.parse_args()
    new = sources(args.new)

    if not args.old:
        print("| Library | Version | License |\n| --- | --- | --- |")
        for name in sorted(new, key=str.lower):
            print(f"| {name} | {new[name]['version']} | {new[name]['license']} |")
        return

    old = sources(args.old)
    sections = {
        "Added": [f"- {n} {new[n]['version']}" for n in sorted(new.keys() - old.keys(), key=str.lower)],
        "Updated": [
            f"- {n} {old[n]['version']} -> {new[n]['version']}"
            for n in sorted(new.keys() & old.keys(), key=str.lower)
            if old[n]["version"] != new[n]["version"]
        ],
        "Rebuilt from a different source": [
            f"- {n} {new[n]['version']}"
            for n in sorted(new.keys() & old.keys(), key=str.lower)
            if old[n]["version"] == new[n]["version"] and old[n]["zig_hash"] != new[n]["zig_hash"]
        ],
        "License changed": [
            f"- {n}: {old[n]['license']} -> {new[n]['license']}"
            for n in sorted(new.keys() & old.keys(), key=str.lower)
            if old[n]["license"] != new[n]["license"]
        ],
        "Removed": [f"- {n}" for n in sorted(old.keys() - new.keys(), key=str.lower)],
    }
    out = [f"#### {title}\n\n" + "\n".join(lines) for title, lines in sections.items() if lines]
    print("\n\n".join(out) if out else "No library changes.")


if __name__ == "__main__":
    main()
