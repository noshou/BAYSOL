# SPDX-License-Identifier: LGPL-3.0-or-later

"""A polymers row for a finished run and its wiring into the electron-density tables."""

import json

from . import config, model, tables

RUN_NOTE = (
    "AmberTools 3D-RISM, cSPC/E, KH, GAFF2/AM1-BCC, RDKit conformers, dev/pmv-rism "
    "(pmv.py) [monomer, infinite dilution, not micellar]"
)


def make_row(name, smiles, names, aliases, mdl, res):
    """A polymers row (dict) for the finished RISM run `name`: raw conformer mean plus the
    Bayesian correction, basis `estimated`, note as the tables carry it. `names` is
    (common, iupac, formula, charge)."""
    common, iupac, formula, charge = names
    n, mu, csd = res[name]
    v, sd = model.estimate(name, smiles, mdl, res)
    corr, psd = model.correction(smiles, mdl)
    note = (
        f"3D-RISM raw value {mu:.1f} (SD {csd:.1f} over {n} conformers) plus the Bayesian "
        f"group correction {corr:+.1f} (predictive sd {psd:.1f}); sd in quadrature of "
        f"predictive sd, conformer error and unmodelled chemistry {model.EXTRA_SD} "
        f"(at least {model.MIN_SD}); {RUN_NOTE}"
    )
    return {
        "common": common,
        "iupac": iupac,
        "formula": formula,
        "charge": charge,
        "v": round(v, 2),
        "sd": round(sd, 2),
        "basis": "estimated",
        "note": note,
        "aliases": aliases,
    }


def wire(rows, apply):
    """Append the rows to polymers.tsv, polymers.json and polymers_lookup.json.

    Idempotent: a row whose iupac key exists is skipped; an alias is added only if no
    lookup (Polymers or NonBiological) already owns it. Without apply only reports."""
    pdir = config.POLYMERS
    tsv, js, lk = (
        pdir / "polymers.tsv",
        pdir / "polymers.json",
        pdir / "polymers_lookup.json",
    )
    nb = json.loads(config.NONBIO_LOOKUP.read_text())
    sel, ltext = json.loads(js.read_text()), lk.read_text()
    look = json.loads(ltext)
    text = tsv.read_text()
    if text and not text.endswith("\n"):
        text += "\n"
    groups = []
    for r in rows:
        key = r["iupac"].lower()
        if key in sel:
            print("skip existing", key)
            continue
        z = tables.electrons(r["formula"], r["charge"])
        sel[key] = [z, r["v"], r["sd"]]
        fields = [r["common"], r["iupac"], r["formula"], str(r["charge"]), str(r["v"])]
        text += "\t".join([*fields, str(r["sd"]), r["basis"], r["note"]]) + "\n"
        group = {}
        for alias in [key, r["common"], *r["aliases"]]:
            a = alias.lower()
            if (a in look and look[a] != key) or a in nb:
                print("alias taken, skipped:", a)
                continue
            look[a] = key
            group[a] = key
        groups.append(group)
        print(f"row {r['common']}: Z {z}, V {r['v']} +- {r['sd']} ({r['basis']})")
    if apply:
        tsv.write_text(text)
        js.write_text(json.dumps(sel, indent=2, ensure_ascii=False))
        body = ltext.rstrip().removesuffix("}").rstrip()
        for g in groups:  # one blank-line-separated group per row, as the file is laid out
            lines = [
                json.dumps(k, ensure_ascii=False) + ": " + json.dumps(v, ensure_ascii=False)
                for k, v in g.items()
            ]
            body += ",\n\n  " + ",\n  ".join(lines)
        lk.write_text(body + "\n}")
