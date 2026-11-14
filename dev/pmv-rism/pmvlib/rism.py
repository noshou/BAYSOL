# SPDX-License-Identifier: LGPL-3.0-or-later

"""The 3D-RISM driver: RDKit conformers, antechamber/tleap, rism3d.snglpnt.

Heavy (a job takes every core): run one at a time. Needs the AmberTools environment
(`config.amber_home()`) and RDKit.
"""

import math
import re
import subprocess

try:
    from rdkit import Chem
    from rdkit.Chem import AllChem
except ImportError:
    Chem = AllChem = None

from . import config, model, tables

A3_TO_CM3 = 0.602214076  # A^3 per molecule -> cm3/mol


def xvv():
    """The solvent susceptibility file (cSPC/E, KH)."""
    return config.amber_home() / "dat/rism1d/cSPCE/cSPCE_kh.xvv"


def sh(cmd, cwd, log):
    """Run a shell command in cwd with the AmberTools environment; return its status."""
    with open(cwd / log, "w") as f:
        return subprocess.run(
            cmd,
            shell=True,
            cwd=cwd,
            env=config.amber_env(),
            stdout=f,
            stderr=subprocess.STDOUT,
            check=False,
        ).returncode


def conformer_volume(c, mol, cid, charge):
    """One conformer (antechamber AM1-BCC/GAFF2, tleap, rism3d.snglpnt); cm3/mol or None."""
    done = c / "result.txt"
    if done.exists():
        return float(done.read_text())
    Chem.MolToMolFile(mol, str(c / "x.mol"), confId=cid)
    bad = sh(
        f"antechamber -i x.mol -fi mdl -o x.mol2 -fo mol2 -c bcc -nc {charge} "
        "-at gaff2 -rn MOL -s 0 -pf y",
        c,
        "antechamber.log",
    )
    bad |= sh("parmchk2 -i x.mol2 -f mol2 -o x.frcmod -s gaff2", c, "parmchk2.log")
    (c / "leap.in").write_text(
        "source leaprc.gaff2\nm = loadmol2 x.mol2\nloadamberparams x.frcmod\n"
        "saveamberparm m x.prmtop x.inpcrd\nsavepdb m x.pdb\nquit\n"
    )
    bad |= sh("tleap -f leap.in", c, "tleap.log")
    if bad or not (c / "x.prmtop").exists():
        return None
    g = model.GRID
    sh(
        f"rism3d.snglpnt --pdb x.pdb --rst x.inpcrd --prmtop x.prmtop --xvv {xvv()} "
        f"--closure kh --buffer {model.BUFFER} --grdspc {g},{g},{g} "
        f"--tolerance {model.TOL} --maxstep 5000 --centering 2 --verbose 1",
        c,
        "rism.log",
    )
    m = re.search(
        r"(?m)^rism_partialMolarVolume\s+([-\d.eE+]+)", (c / "rism.log").read_text()
    )
    if not m:
        return None
    v = float(m.group(1)) * A3_TO_CM3
    done.write_text(str(v))
    return v


def run_molecule(name, smiles, nconf, charge, seed=1):
    """ETKDG + MMFF conformers, 3D-RISM each; appends the mean and SD to results.tsv."""
    if Chem is None:
        raise SystemExit("RDKit is not installed (run with the AmberTools environment)")
    d = config.work_dir() / name
    d.mkdir(parents=True, exist_ok=True)
    mol = Chem.AddHs(Chem.MolFromSmiles(smiles))
    cids = list(AllChem.EmbedMultipleConfs(mol, numConfs=nconf, randomSeed=seed))
    if not cids:
        # large flexible molecules (LMNG): ETKDG can fail from a distance-geometry start
        cids = list(
            AllChem.EmbedMultipleConfs(
                mol, numConfs=nconf, randomSeed=seed, useRandomCoords=True
            )
        )
    AllChem.MMFFOptimizeMoleculeConfs(mol, maxIters=5000)
    vs = []
    for i, cid in enumerate(cids):
        c = d / f"c{i:02d}"
        c.mkdir(exist_ok=True)
        v = conformer_volume(c, mol, cid, charge)
        if v is None:
            print("FAIL", name, i, flush=True)
            continue
        vs.append(v)
        print(name, i, v, flush=True)
    if not vs:
        return None
    mu = sum(vs) / len(vs)
    sd = (
        math.sqrt(sum((x - mu) ** 2 for x in vs) / (len(vs) - 1))
        if len(vs) > 1
        else math.nan
    )
    p = config.results_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as f:
        f.write(
            f"{name}\t{len(vs)}\t{mu:.2f}\t{sd:.2f}\t{model.BUFFER}\t{model.GRID}"
            f"\t{model.TOL}\n"
        )
    print(f"RESULT {name} n={len(vs)} mean={mu:.2f} sd={sd:.2f}", flush=True)
    return mu, sd


def batch(path, tier=None):
    """Run the rows of a spec TSV (columns id, smiles, charge, nconf; a tier column filters
    with --tier). The RISM name is the id. Sequential, skips ids already in results.tsv."""
    done = tables.read_results()
    for r in tables.read_tsv(path):
        if r["id"] in done or (tier is not None and r.get("tier") != tier):
            continue
        run_molecule(r["id"], r["smiles"], int(r["nconf"]), int(r["charge"]))
