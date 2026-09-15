#!/usr/bin/env python3
"""Coordinator rollup for the functionality audit package.

Reads every analyses/*.json row record written by the analyst subagents and
emits a single merged table plus the counters the COVERAGE.md index needs.

Read-only with respect to the audit package: it prints, it does not write.
"""
import glob
import json
import os
import sys

ROOT = "docs/audits/functionality-audit-2026-09-15/analyses"

SEV_ORDER = ["critical", "major", "minor", "info"]


def load():
    rows = []
    for path in sorted(glob.glob(os.path.join(ROOT, "*.json"))):
        try:
            data = json.load(open(path))
        except json.JSONDecodeError as exc:
            print(f"UNPARSEABLE {path}: {exc}", file=sys.stderr)
            continue
        # Multi-row briefs (apps/scripts) carry {"rows": [...]}.
        payload = data.get("rows") if isinstance(data, dict) and "rows" in data else [data]
        for item in payload:
            item["_file"] = os.path.basename(path)
            rows.append(item)
    return rows


def main():
    rows = load()
    if not rows:
        print("no row records found")
        return

    totals = {s: 0 for s in SEV_ORDER}
    lenses_missing = []

    print(f"{'ROW':6} {'VERDICT':10} {'C':>2} {'M':>2} {'m':>2} {'i':>2}  FINDINGS")
    print("-" * 100)
    for r in sorted(rows, key=lambda x: str(x.get("row", "?"))):
        c = r.get("counts", {})
        for s in SEV_ORDER:
            totals[s] += c.get(s, 0)
        lens = r.get("lenses", {})
        gaps = [k for k, v in lens.items() if v != "reviewed"]
        if gaps:
            lenses_missing.append((r.get("row"), gaps))
        ids = " ".join(
            f"{f['id']}({f['severity'][:4]})" for f in r.get("findings", [])
        )
        print(
            f"{str(r.get('row','?')):6} {str(r.get('verdict','?')):10} "
            f"{c.get('critical',0):2} {c.get('major',0):2} {c.get('minor',0):2} "
            f"{c.get('info',0):2}  {ids}"
        )

    print("-" * 100)
    print(
        f"rows={len(rows)}  critical={totals['critical']} major={totals['major']} "
        f"minor={totals['minor']} info={totals['info']}"
    )

    needs_challenge = [
        f["id"]
        for r in rows
        for f in r.get("findings", [])
        if f["severity"] in ("critical", "major")
    ]
    if needs_challenge:
        print(f"\ncritical/major requiring a challenge record: {' '.join(sorted(set(needs_challenge)))}")

    if lenses_missing:
        print("\nlenses not fully reviewed:")
        for row, gaps in lenses_missing:
            print(f"  {row}: {', '.join(gaps)}")

    flags = [(r.get("row"), f) for r in rows for f in r.get("coordinator_flags", [])]
    if flags:
        print("\ncoordinator flags:")
        for row, flag in flags:
            print(f"  {row}: {flag}")


if __name__ == "__main__":
    main()
