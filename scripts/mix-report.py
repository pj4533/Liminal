#!/usr/bin/env python3
"""Measure a Liminal Lo-Fi capture and evaluate the mix criteria (docs/plans/mpc-chopping.md section 9).

  python3 scripts/mix-report.py CAPTURE [--baseline DIR] [--strict] [--no-plots] [--criteria FILE]
  python3 scripts/mix-report.py --print-criteria-md
  python3 scripts/mix-report.py --self-test

Writes CAPTURE/report/mix-report.json, mix-report.md and PNG figures.
"""

import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from mixlib import plots, report  # noqa: E402
from mixlib.audio import Capture  # noqa: E402


def criteria_markdown(criteria):
    lines = ["| Id | Level | Applies to | Criterion |", "|---|---|---|---|"]
    for c in criteria:
        cases = c.get("cases", "*")
        lines.append(f"| {c['id']} | {c['level']} | {'all cases' if cases == '*' else ', '.join(cases)} | {c['description']} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", type=Path, nargs="?", help="capture directory (manifest.json and WAVs)")
    parser.add_argument("--baseline", type=Path, help="baseline capture directory or its report directory to compare against")
    parser.add_argument("--strict", action="store_true",
                        help="exit nonzero when a fail-level criterion fails or is skipped for a reason other than 'no dialogue' or 'no footage'")
    parser.add_argument("--no-plots", action="store_true")
    parser.add_argument("--criteria", type=Path, default=HERE / "mix-criteria.json")
    parser.add_argument("--case", help="matrix case name (ref, long, fast, same, nofilm); default from the directory name")
    parser.add_argument("--print-criteria-md", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        from mixlib.selftest import run_self_test
        return run_self_test()
    criteria = report.load_criteria(args.criteria)
    if args.print_criteria_md:
        print(criteria_markdown(criteria))
        return 0
    if not args.capture:
        parser.error("a capture directory is required")
    cap_dir = args.capture.resolve()
    if not (cap_dir / "manifest.json").is_file():
        parser.error(f"{cap_dir} has no manifest.json")

    started = time.time()
    cap = Capture(cap_dir, case=args.case)
    print(f"Mix report for {cap_dir} (case {cap.case}, schema {cap.schema}, {cap.frames / cap.rate:.1f} s)", flush=True)
    metrics, aux = report.run_analysis(cap)
    results = report.evaluate(metrics, cap, criteria)

    baseline_doc = None
    if args.baseline:
        bdir = args.baseline.resolve()
        bfile = bdir / "mix-report.json" if (bdir / "mix-report.json").is_file() else bdir / "report" / "mix-report.json"
        if bfile.is_file():
            baseline_doc = json.loads(bfile.read_text())
        else:
            print(f"warning: no baseline report at {bfile}", file=sys.stderr)

    out = cap_dir / "report"
    doc = report.write_report(out, cap, metrics, results, baseline_doc)
    if not args.no_plots:
        print("  plotting", flush=True)
        plots.make_all(cap, metrics, aux, out)
        if baseline_doc:
            plots.compare_plots(doc, baseline_doc, results, baseline_doc["criteria"], out)

    counts = doc["summary"]["counts"]
    print(f"\n{'id':7s}{'level':6s}{'status':9s}values")
    for r in doc["criteria"]:
        vals = ", ".join(f"{k}={report.fmt(v)}" for k, v in (r.get("values") or {}).items())
        note = f"  [{r['reason']}]" if r.get("reason") else ""
        print(f"{r['id']:7s}{r['level']:6s}{r['status']:9s}{vals[:150]}{note}")
    m = doc["metrics"]
    ff = report.g(m, "loudness", "ffmpeg", "integratedLufs")
    print(f"\nIntegrated {report.fmt(report.g(m, 'loudness', 'integratedLufs'))} LUFS (ffmpeg {report.fmt(ff)}, diff {report.fmt(report.g(m, 'loudness', 'ffmpegDiffLu'))} LU); "
          f"true peak {report.fmt(report.g(m, 'truePeak', 'ffmpegDbtp'))} dBTP (16x {report.fmt(report.g(m, 'truePeak', 'reconstructionDbtp'))})")
    print(f"{counts['pass']} pass, {counts['fail']} fail, {counts['warn']} warn, {counts['skipped']} skipped; "
          f"strict failures: {', '.join(doc['summary']['strictFailures']) or 'none'}")
    if baseline_doc:
        print("\nBaseline comparison")
        report.print_comparison(doc, baseline_doc)
    print(f"\nReport: {out / 'mix-report.md'} ({time.time() - started:.0f} s)")
    return 1 if args.strict and doc["summary"]["strictFailures"] else 0


if __name__ == "__main__":
    sys.exit(main())
