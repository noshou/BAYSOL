#!/usr/bin/env python3
"""Compare fitting-test results between git revisions and the working tree.

    python3 test/fitting_tests/compare.py [REV ...] [--no-tree] [--csv out.csv]

Each REV is any git revision (tag, branch, commit hash, ``HEAD~3``, ...). With none given the
comparison is ``23151ec`` (the v0.2.0 rerun, the timing baseline) and ``HEAD``. The columns
appear in the order given, followed by the working tree, which is the one being judged: every
speedup and every χ² comparison is "last column against each of the others". ``--no-tree``
drops the working tree, so the last REV is judged instead.

Reads every ``test/fitting_tests/*/res*.txt`` at each REV via ``git show`` (no checkout, nothing
rerun) and prints timing totals, fit-quality and parameter distributions, and the fits that do the
most NUTS work. Per-fit numbers go to ``--csv`` if given.

Examples:
    compare.py v0.1.0-sɩngre v0.2.0-soukouratou HEAD     # three tags/commits against the tree
    compare.py HEAD~2 HEAD --no-tree                      # two commits only

Conventions (CLAUDE.md): speedups are cumulative against the reference and not additive; the
wall clock excludes PROPKA/pdb2pqr; fit comparisons are judged on distributions, not 1:1.
"""
import argparse
import re
import subprocess
import statistics as st
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIT_DIR = "test/fitting_tests"
NUM = r"([-+]?\d+\.?\d*(?:[eE][-+]?\d+)?)"


def _count(tok):
    """'496.68k' -> 496680.0; '12.4k' -> 12400.0; '1.2M' -> 1.2e6."""
    scale = {"k": 1e3, "M": 1e6}.get(tok[-1], 1.0)
    return float(tok.rstrip("kM")) * scale


def parse(text):
    """The numbers of one ``res*.txt`` report, ``None`` where a revision lacks them."""
    def one(pat, flags=re.M):
        m = re.search(pat, text, flags)
        return m.group(1) if m else None

    def num(pat):
        v = one(pat)
        return float(v) if v is not None else None

    nuts = re.search(r"NUTS  \(([\d.]+k?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step\)\s+" + NUM, text)
    d = {
        "div": num(r"^divergence_rate = " + NUM),
        "chi2": num(r"^χ²\s+= " + NUM),
        "c1": num(r"^excl_vol_corr\s+= " + NUM),
        "rho_e": num(r"^ρₑ\s+= " + NUM),
        "d1": num(r"^δρ₁\s+= " + NUM),
        "d2": num(r"^δρ₂\s+= " + NUM),
        "d3": num(r"^δρ₃\s+= " + NUM),
        "steps": num(r"^mean_n_steps\s+= " + NUM),
        "depth": num(r"^tree_depth\s+= " + NUM),
        "accept": num(r"^mean_accept\s+= " + NUM),
        "ebfmi": num(r"^EBFMI\s+= " + NUM),
        "sat": one(r"^excl_vol_sat\s+= (\w+)"),
        "wall": num(r"^wall clock.*?\s" + NUM + r"\s+100\.0"),
        "fwd": num(r"^\s+forward_cache\s+" + NUM),
        "propka": num(r"^\s+propka.*?" + NUM + r"\s*$"),
        "pdb2pqr": num(r"^\s+pdb2pqr.*?" + NUM + r"\s*$"),
        "map_s": num(r"^\s+MAP search \+ whitening .*\)\s+" + NUM + r"\s*$"),
        "reprofile": num(r"^\s+per-draw c1 re-profile.*?\)\s+" + NUM + r"\s*$"),
        "gc": num(r"^GC: " + NUM),
    }
    if nuts:
        d["leapfrog"] = _count(nuts.group(2))
        d["ms_step"] = float(nuts.group(3))
        d["nuts"] = float(nuts.group(4))
    else:
        d["leapfrog"] = d["ms_step"] = d["nuts"] = None
    # z-score of the MAP δρ₃ from the prior (θ-space), first number of its row in that table
    m = re.search(r"=== Standard deviations from prior.*?^δρ₃\s+" + NUM, text, re.M | re.S)
    d["z3"] = float(m.group(1)) if m else None
    d["n_modes"] = None
    m = re.search(r"MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?", text)
    if m:
        d["n_modes"] = int(m.group(1))
    d["wall_ex"] = None if d["wall"] is None else d["wall"] - (d["propka"] or 0) - (d["pdb2pqr"] or 0)
    return d


def resolve(rev):
    """The commit hash of ``rev``, or ``None`` if git does not know it."""
    r = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
                       cwd=ROOT, capture_output=True, text=True)
    return r.stdout.strip() or None


def git_reports(rev):
    """{relative path: parsed report} for every ``res*.txt`` under the fitting tests at ``rev``."""
    out = subprocess.run(["git", "ls-tree", "-r", "--name-only", rev, FIT_DIR],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    res = {}
    for p in out:
        if re.fullmatch(rf"{FIT_DIR}/[^/]+/res[^/]*\.txt", p):
            txt = subprocess.run(["git", "show", f"{rev}:{p}"], cwd=ROOT, capture_output=True,
                                 text=True, check=True).stdout
            res[p] = parse(txt)
    return res


def tree_reports():
    return {str(p.relative_to(ROOT)): parse(p.read_text(encoding="utf-8"))
            for p in sorted((ROOT / FIT_DIR).glob("*/res*.txt"))}


def total(rs, key):
    """Sum of ``key`` over the reports, or ``None`` if no report has it (older formats lack some fields)."""
    vals = [r[key] for r in rs.values() if r[key] is not None]
    return sum(vals) if vals else None


def cell(r):
    """'steps / NUTS seconds' of one report, with '-' for whatever an older format lacks."""
    if r is None:
        return "-"
    steps = "-" if r["steps"] is None else f"{r['steps']:.1f}"
    nuts = "-" if r["nuts"] is None else f"{r['nuts']:.1f}s"
    return f"{steps} / {nuts}"


def med(xs, fmt):
    return format(st.median(xs), fmt) if xs else "-"


def pct(xs, q):
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def timing_table(sets):
    names = list(sets)
    cur = names[-1]
    others = names[:-1]
    rows = [("forward_cache", "fwd"), ("MAP search + whitening", "map_s"), ("NUTS", "nuts"),
            ("per-draw c1 re-profile", "reprofile"), ("wall clock excl. PROPKA/pdb2pqr", "wall_ex"),
            ("leapfrog steps (x1e6)", "leapfrog")]
    head = "| (all fits, summed) | " + " | ".join(names) + " | " + " | ".join(f"{cur} vs {n}" for n in others) + " |"
    print(head)
    print("|---|" + "---|" * (len(names) + len(others)))
    for label, key in rows:
        vals = {n: total(sets[n], key) for n in names}
        cells = " | ".join("-" if vals[n] is None else f"{vals[n] * 1e-6:,.2f}" if key == "leapfrog" else f"{vals[n]:,.0f} s" for n in names)
        ratios = " | ".join(f"{vals[n] / vals[cur]:.2f}x" if vals[n] and vals[cur] else "n/a" for n in others)
        print(f"| {label} | {cells} | {ratios} |")
    print("\n(ratio > 1: the last column is faster / does less work than that revision)")


def quality(new, old, label, cur):
    common = [k for k in new if k in old and new[k]["chi2"] is not None and old[k]["chi2"] is not None]
    lower = sum(new[k]["chi2"] < 0.99 * old[k]["chi2"] for k in common)
    higher = sum(new[k]["chi2"] > 1.01 * old[k]["chi2"] for k in common)
    print(f"χ² of {cur} vs {label} ({len(common)} common fits, ±1 % counts as unchanged): "
          f"{lower} lower, {higher} higher, {len(common) - lower - higher} unchanged")


def distribution(rs, name):
    c = [r["chi2"] for r in rs.values() if r["chi2"] is not None]
    z = [abs(r["z3"]) for r in rs.values() if r["z3"] is not None]
    d3 = [r["d3"] for r in rs.values() if r["d3"] is not None]
    n = len(rs)
    div = sum((r["div"] or 0) > 0.01 for r in rs.values())
    sat = sum(r["sat"] not in (None, "false", "0") for r in rs.values())
    deep = sum((r["steps"] or 0) > 100 for r in rs.values())
    steps = [r["steps"] for r in rs.values() if r["steps"] is not None]
    q = f"{pct(c, .25):.2f} / {pct(c, .75):.2f}" if c else "-"
    print(f"| {name} | {n} | {med(c, '.2f')} | {q} | "
          f"{div} | {sat} | {sum(v > 3 for v in z)} | {med(d3, '+.2f')} | {deep} | "
          f"{med(steps, '.1f')} |")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("revs", nargs="*", metavar="REV", default=["23151ec", "HEAD"],
                    help="git revisions to compare, in column order (default: 23151ec HEAD)")
    ap.add_argument("--no-tree", action="store_true", help="leave out the working tree; the last REV is then judged")
    ap.add_argument("--csv", help="write per-fit numbers here")
    a = ap.parse_args()

    sets = {}
    for rev in a.revs:
        if resolve(rev) is None:
            tags = subprocess.run(["git", "tag", "--list"], cwd=ROOT, capture_output=True, text=True).stdout.split()
            raise SystemExit(f"unknown git revision {rev!r}; tags here: {', '.join(tags) or '(none)'}")
        label = rev if rev not in sets else f"{rev}#{len(sets)}"
        reports = git_reports(rev)
        if not reports:
            print(f"warning: no fitting-test reports at {rev}; skipped")
            continue
        sets[label] = reports
    if not a.no_tree:
        sets["working tree"] = tree_reports()
    if len(sets) < 2:
        raise SystemExit("need at least two result sets to compare")
    names = list(sets)
    cur = names[-1]
    common = set.intersection(*(set(v) for v in sets.values()))
    if not common:
        raise SystemExit("no fit has a report in every column")
    print("Reports: " + ", ".join(f"{n}={len(sets[n])}" for n in names))
    print(f"Everything below except the per-fit list and the CSV is aggregated over the {len(common)} fits "
          "that have a report in every column.\n")
    agg = {n: {k: v for k, v in sets[n].items() if k in common} for n in names}
    timing_table(agg)

    print("\n| | fits | median χ² | χ² Q1 / Q3 | >1 % divergent | c1 pinned | MAP >3σ from δρ₃ prior | median δρ₃ | fits >100 steps/iter | median steps/iter |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for n in names:
        distribution(agg[n], n)
    print()
    for n in names[:-1]:
        quality(agg[cur], agg[n], n, cur)

    new = sets[cur]
    print(f"\nFits with the most NUTS work in {cur} (columns: {' | '.join(names)}): steps/iter / NUTS seconds")
    for k in sorted(new, key=lambda k: -(new[k]["steps"] or 0))[:8]:
        cells = " | ".join(cell(sets[n].get(k)) for n in names)
        print(f"  {k.replace(FIT_DIR + '/', ''):42s} {cells}")

    if a.csv:
        keys = ["chi2", "steps", "depth", "nuts", "wall_ex", "div", "c1", "d1", "d2", "d3", "z3", "n_modes"]
        with open(a.csv, "w", encoding="utf-8") as f:
            f.write("fit," + ",".join(f"{n}:{k}" for n in names for k in keys) + "\n")
            for k in sorted(new):
                f.write(k.replace(FIT_DIR + "/", "") + "," + ",".join(
                    "" if sets[n].get(k) is None or sets[n][k][kk] is None else f"{sets[n][k][kk]:.6g}"
                    for n in names for kk in keys) + "\n")


if __name__ == "__main__":
    main()
