# MolecularStructure

## Overview

MolecularStructure converts a PDB ID, a local .pdb/.cif file, or an arbitrary URL into a parsed, protonated structure suitable for the forward-scattering model (`Scattering.forward_cache`).

The workflow is:

1. **Resolve** a structure source to a canonical local .pdb (StructureSource.jl).
2. **Predict** per-residue-instance pKa values using external PROPKA (Pdb2pqr.jl).
3. **Add hydrogens** for a target pH using Pdb2pqr, with pKa predictions used to resolve free-terminal protonation states (Pdb2pqr.jl).
4. **Parse** the structure into the internal Molecule representation (Mols.jl).

Steps 2 and 3 are optional. PROPKA's pKas have exactly one consumer, the terminus protonation in step 3. So `BAYSOL.seed_model(...; add_hydrogens=false)` skips both and runs the forward model on the structure exactly as given. Use that for pre-hydrogenated models, which pdb2pqr refuses (e.g. SASDP48). Both steps cache their output in `_store_dir()`: `<stem>.pka` (`_pka_path`) and `<stem>_pH<pH>.pdb` (`_hydrogens_path`). The run report marks each one `[cache hit]`/`[cache miss]` in its timing section.

```julia
using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule,
 propka_pKas, resolve_hydrogens

path = resolve_structure(LocalPathSource(pdb_path))
pKa_records = propka_pKas(path)
hpath = resolve_hydrogens(path, pKa_records, pH)
mol = load_molecule(hpath)
```

## Module components

- AtomicRadii.jl: element/ion string → radius lookup over the bundled `atomic_radii.sqlite3` (`lookup_radii`), the radii `Mols.jl` builds `radii(mol)` from.
- StructureSource.jl: resolves local files, PDB IDs, and URLs.
- Mols.jl: defines the internal molecule and residue representations.
- Pdb2pqr.jl: predicts per-residue-instance pKa values with PROPKA (`propka_pKas`; its only consumer is the terminus protonation, there is no other ionization/charge model; the former `Ionization.jl` and the cavity electrostatics were removed) and adds hydrogens at a target pH with pdb2pqr (with the Henderson-Hasselbalch helpers that pick each chain's terminus protonation).

The per-atom excluded volumes that `vols(mol)` returns, and the surface sampling, are computed by [`Geometry`](@ref BAYSOL.Geometry); `Molecule` is a `Geometry.SphereCloud`.

## StructureSource.jl

`resolve_structure(source::StructureSource)` -> String resolves any of three input shapes to an absolute path to a canonical .pdb in `_store_dir()` (first model only, whatever its MODEL number; standardselector/heavyatomselector-filtered: no HETATM/ waters, no hydrogens).

- **LocalPathSource(path)**: a structure already on local disk; if a file already exists under that name, the freshly-converted result is byte-compared against it. Identical content reuses the existing file, different content under the same name raises StructureSourceError.
- **PDBIDSource(id)**: a structure identified by its 4-character RCSB PDB ID (e.g. "1CRN"), fetched via BioStructures.retrievepdb and stored under the uppercased ID. A repeat request for the same ID trusts an existing file's presence and skips fetching.
- **URLSource(url, id)**: a structure at an arbitrary url, in either legacy .pdb or mmCIF format (sniffed from the downloaded content via the literal `loop_` keyword, not the URL), stored under the caller-supplied id. Every call re-downloads and re-converts, unlike PDBIDSource, and the result is then byte-compared against any existing file under id with the same collision policy. Constructing a URLSource with an empty id raises StructureSourceError.

```julia
using BAYSOL.MolecularStructure: LocalPathSource, PDBIDSource, URLSource, resolve_structure

path1 = resolve_structure(LocalPathSource("structure.cif"))
path2 = resolve_structure(PDBIDSource("1CRN"))
path3 = resolve_structure(URLSource("https://files.rcsb.org/download/1CRN.pdb", "1CRN-mirror"))
```

## Mols.jl

### Molecule

Per-atom centred coordinates in both cartesian and spherical frames, with lazily computed radii/vols/`r_max`. Both coordinate frames are (3, n) matrices sharing a column index (the atom); the spherical rows are r, theta, phi in that order (theta = acos(z/r) ∈ [0, π], phi = atan(y, x) ∈ (-π, π]). r = 0 is handled explicitly rather than producing a 0/0, since the angle is unobservable downstream anyway (`j_l(0)` = 0 for every l > 0).

```julia
using BAYSOL.MolecularStructure: create, coords_cartesian, coords_spherical,
 radii, vols, r_max, elms, name, n_atoms

mol = create("my-mol", elements, coords) # coords: any iterable of 3-tuples/vectors
coords_cartesian(mol) # (3, n) centred (x, y, z)
coords_spherical(mol) # (3, n) (r, theta, phi)
radii(mol) # per-atom van der Waals radius, lazy/memoized, via `lookup_radii` (AtomicRadii.jl) by default
vols(mol) # per-atom excluded volume; see the Geometry README
r_max(mol) # largest per-atom radius; `Geometry.sasa`'s neighbour-filter bound
```

vols is **not** (4/3)π·radii(mol)³ (see the Geometry README).

`create(name, elms, coords)` centres coords at the centroid and computes both coordinate frames eagerly; radii/vols/`r_max` are resolved (and cached) only on first  access, through `AtomicRadii.lookup`.

### `load_molecule`

```julia
mol = load_molecule(pdb_path)
```

Parses whatever .pdb is at `pdb_path` into a Molecule. Only the first model is read, whatever its MODEL number, so an ensemble member extracted to its own file (e.g. `MODEL 63`) loads correctly.

## PROPKA (`propka_pKas`, in Pdb2pqr.jl)

A free amino acid's textbook pKa is valid only in isolation. Inside a folded protein, a titratable side chain's actual pKa is shifted by its local electrostatic and desolvation environment: burial away from solvent, hydrogen bonding, and proximity to other charged groups all perturb it.

```julia
using BAYSOL.MolecularStructure: propka_pKas, PropkaError

records = propka_pKas(pdb_path)
# Vector{<:NamedTuple}, one per standard titratable group:
# (resname::String, resnum::Int, chain::String, pKa::Float64)
```

## pdb2pqr (`resolve_hydrogens`, in Pdb2pqr.jl)

 A structure resolved from RCSB or a bare crystallographic .cif/.pdb  typically carries heavy atoms only. The forward-model geometry step needs an explicit, pH-consistent set of atoms (hydrogens included) to compute scattering correctly, and *which hydrogens a titratable group carries depends on its protonation state at the solution pH being fit against (e.g. a free amine's three vs. two hydrogens, a carboxylate's presence/absence of an "HO"). Pdb2pqr.jl runs the external pdb2pqr tool to add hydrogens consistent with a target pH and force field, so the geometry passed downstream matches the physical/chemical state the fit assumes.

```julia
using BAYSOL.MolecularStructure: resolve_hydrogens, Pdb2pqrError

hpath = resolve_hydrogens(pdb_path, pKa_records, pH)
```

`resolve_hydrogens(pdb_path, pKa_records, pH)` runs pdb2pqr --ff PARSE --titration-state-method propka --with-ph <pH></ph> on the heavy-atom .pdb at `pdb_path` and returns the path to a hydrogen-included .pdb stored in `_store_dir()` under `"<stem>_pH<pH>.pdb"`. A repeat call for the same (stem, pH) is a cache hit and not re-run.

`pKa_records` must be the records [`propka_pKas`](@ref BAYSOL.MolecularStructure.propka_pKas) produced **on this same structure**. PARSE has no nucleotide parameters, so this path is protein-only (see CLAUDE.md, "Nucleotide support").

### Terminus protonation

pdb2pqr's  terminus handling is not pH-driven (it defaults to a fixed charged state). `_terminus_groups(pKa_records, pH, chains)` overrides this from the "N+"/"C-" records, producing, per chain, pdb2pqr's --neutraln/--neutralc CLI flags. A free N-terminus gets --neutraln when it's deprotonated (neutral), a free C-terminus gets --neutralc when it's protonated (neutral). These flags are global to a single pdb2pqr call not per-chain, so a structure whose free N-termini (or C-termini) round to different protonation states at the same pH can't be represented by one run. `resolve_hydrogens` handles this by partitioning chains into groups that share a flag, running pdb2pqr once per group, and merging each run's chains back into one hydrogenated structure. Pdb2pqrError is raised when pdb2pqr cannot be run or produces no usable output (bad input path, non-zero exit, missing expected output file).

```
			  ┌───────────────────────────────────┐
              │ 	PROPKA pKa records            │
              │ propka_pKas(full_structure)       │
 			  │ computed once on the full complex │
			  └───────────────┬───────────────────┘
                              │
                              │ 
                              ▼
        ┌─────────────────────┴─────────────────────┐
        │ _terminus_groups(pKa_records, pH, chains) │
        │											│ 
        │	determine, for each chain:				│
        │ 		--neutraln?   --neutralc?		    │
        └─────────────────────┬─────────────────────┘
                              │   
                              │
                              ▼
                  ┌───────────┴─────────────┐
                  │group chains by identical│
                  │terminal-flag combination│
                  └───────────┬─────────────┘ 
                              │
                ┌─────────────┴────────────────┐
                ▼    						   ▼
      ┌─────────┴──────────┐	    ┌──────────┴─────────┐
	  │ single flag group  │		│multiple flag groups│
      └─────────┬──────────┘        └────────────┬───────┘
                │							     │
                ▼                                ▼
      ┌─────────┴───────────┐     ┌──────────────┴───────────────┐
      │ Run Pdb2pqr once    │     │ For each distinct flag       │
      │ on the full         │     │ combination:                 │
      │ structure with      │     │                              │
      │ that group's flags. │     │  1. Run Pdb2pqr on the full  │
      └──────────┬──────────┘     │     original structure with  │
                 │                │     this group's flags       │
                 │                │                              │
                 │                │  2. Keep only atoms from     │
                 │                │     this group's chains      │
                 │                │                              │
                 │                │  3. Discard atoms from       │
                 │                │     all other chains         │
                 │                └──────────────┬───────────────┘
                 │                               │
                 │                               │ 
                 │                               ▼
                 │                ┌──────────────┴────────────┐
                 │                │ Merge the retained atoms  │
                 │                │ from all groups           │
                 │                └─────────────┬─────────────┘
                 │                				│
                 └───────────────┬──────────────┘
                                 │
                                 ▼
                  ┌──────────────┴─────────────┐
                  │ Write one hydrogenated PDB │
				  └──────────────┬─────────────┘ 
			                     │
                                 ▼
				  ┌──────────────┴─────────────┐
                  │ cache "<stem>_pH<pH>.pdb"  │
				  └────────────────────────────┘
```

## Terminus protonation (Henderson-Hasselbalch, in Pdb2pqr.jl)

For a **base** group (charged when protonated, e.g. the free N-terminus), the protonated fraction at solution pH is

```
f = 1 / (1 + 10^(pH - pKa))
```

and for an **acid** group (charged when deprotonated, e.g. the free C-terminus) the deprotonated fraction is

```
f = 1 / (1 + 10^(pKa - pH))
```

`_group_protonated` reduces both to the same rule, charged ⟺ f > 0.5, so a group sitting exactly at its own pKa rounds to its *uncharged* state. `_terminus_groups` applies it to each chain's PROPKA N+/C- records to decide pdb2pqr's --neutraln/--neutralc flags, per chain.

## AtomicRadii.jl

Element/ion string → radius lookup (`lookup_radii(ions)`; `atomic_radii.sqlite3` beside it, loaded once at module load), independent of residue identity. `MolecularStructure.create` uses it for `radii(mol)`, the isolated van der Waals radii that SASA, hydration-shell generation and the power-diagram excluded volumes are all built on.

### `atomic_radii.sqlite3`

`atomic_radii.sqlite3` holds three tables: empirical **ionic** radii (charged species only), a bare-**element** fallback radius for every element in the periodic table, and a cache of which charge states each element actually has data for.

### `ionic_radii`

```sql
CREATE TABLE ionic_radii (
    ion    TEXT PRIMARY KEY,  -- lowercase element symbol + |charge| + sign, e.g. 'fe3+', 'cl1-'
    radius REAL NOT NULL      -- empirical ionic radius, picometers
)
```

#### Negative radii: h1+ (-38.0 pm), n5+ (-10.4 pm), c4+ (-8.0 pm)

Three rows have a negative radius. These are genuine Shannon (1976) values,  Shannon's scale is anchored to a reference O^2- radius (140 pm), not an absolute physical size, so a cation with little or no electron cloud of its own (a bare proton, or a small, highly-stripped cation like C4+/N5+) can land below that baseline arithmetically.  Any code that turns radius into a physical  volume/sphere must treat radius ≤ 0.0 the same as "no entry found" and fall through to `atomic_radii`.

#### Sources


| Citation                                                                                                                                                      | DOI / identifier          | Ions     |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ---------- |
| Shannon, R.D. (1976). Revised effective ionic radii and systematic studies of interatomic distances in halides and chalcogenides.*Acta Cryst.* A32, 751–767. | 10.1107/S0567739476001551 | 210 ions |
| Feldmann, C. (1995). Zur kristallchemischen Ähnlichkeit von Aurid- und Halogenid-Ionen.*Z. Anorg. Allg. Chem.* 621, 1907–1912.                              | 10.1002/zaac.19956211113  | au1-     |
| Pauling, L. (1960).*The Nature of the Chemical Bond*, 3rd ed. Cornell University Press.                                                                       | ISBN 0-8014-0333-2        | h1-      |

### `atomic_radii`

```sql
CREATE TABLE atomic_radii (
    element     TEXT PRIMARY KEY,  -- lowercase element symbol, no charge, e.g. 'fe', 'rn'
    radius      REAL NOT NULL,     -- Angstrom
    radius_type TEXT NOT NULL,     -- 'vdw' | 'metallic' | 'covalent'
    source      TEXT NOT NULL      -- full citation for this row
)
```

118 rows: every ground state element, Z=1 through Z=118.

`radius_type`: van der Waals, metallic, and covalent radii  are three different physical quantities (covalent radii in particular run  30–70% smaller than van der Waals radii for the same element).


| `radius_type` | Elements                                                                        | Count |
| --------------- | --------------------------------------------------------------------------------- | ------- |
| vdw           | Alvarez-covered elements (H–Es, minus Po/At/Fr/Ra), plus Po/At/Fr/Ra (Mantina) | 98    |
| metallic      | Pm (no Alvarez data; Teatum 1968 fallback)                                      | 1     |
| covalent      | Fm–Lr, transactinides/superheavies Rf–Og (no Alvarez data)                    | 19    |

#### Sources


| Citation                                                                                                                                                                                                                 | DOI / identifier       | `radius_type` | Elements                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | --------------- | --------------------------------------------------------------------------------------------------------- |
| Alvarez, S. (2013). A cartography of the van der Waals territories.*Dalton Trans.* 42, 8617–8636.                                                                                                                       | 10.1039/c3dt50599e     | vdw           | 94 elements: main group, transition metals, and lanthanides/actinides through Es (minus Po, At, Fr, Ra) |
| Mantina, M.; Chamberlin, A.C.; Valero, R.; Cramer, C.J.; Truhlar, D.G. (2009). Consistent van der Waals Radii for the Whole Main Group.*J. Phys. Chem. A* 113, 5806–5812.                                               | 10.1021/jp8111556      | vdw           | Po, At, Fr, Ra — no Alvarez data                                                                       |
| Teatum, E.T.; Gschneidner, K.A. Jr.; Waber, J.T. (1968). Compilation of Calculated Data Useful in Predicting Metallurgical Behavior of the Elements in Binary Alloy Systems.*LA-4003*, Los Alamos Scientific Laboratory. | (LASL report; no DOI)  | metallic      | Pm                                                                                                      |
| Pyykkö, P.; Atsumi, M. (2009). Molecular Single-Bond Covalent Radii for Elements 1–118.*Chem. Eur. J.* 15, 186–197.                                                                                                   | 10.1002/chem.200800987 | covalent      | 19 elements: Fm–Lr and transactinides/superheavies Rf–Og                                              |

### **`element_charges`**

```sql
CREATE TABLE element_charges (
    element TEXT NOT NULL,
    charge  INTEGER NOT NULL,             -- signed, e.g. 3 for 'fe3+', -1 for 'cl1-'
    ion     TEXT NOT NULL REFERENCES ionic_radii(ion),
    PRIMARY KEY (element, charge)
)
```

212 rows, one per `ionic_radii` row. Exists to answer "what charge states does this element actually have data  for" or "which charge state is closest to the one I want" with one query instead of re-parsing every `ionic_radii.ion` string on every lookup:

```sql
-- nearest available charge state for element 'fe', target charge +5
SELECT ion, charge FROM element_charges
WHERE element = 'fe' ORDER BY ABS(charge - 5) LIMIT 1;
```

1. Try `ionic_radii` for the exact ion first
2. If that misses, use `element_charges` to find the nearest charge state for that  element
3. Fall back to `atomic_radii`'s bare-element value.
4. If `element_charges` regenerated from scratch, it must be rebuilt from `ionic_radii`

## MolecularStructure.jl

Includes AtomicRadii.jl, Mols.jl, StructureSource.jl and Pdb2pqr.jl in dependency order and provides `_store_dir()`, the shared `_cache/` path used throughout the module. The geometry constants (`N_VOL_SHELL`, `ATOM_BLOCK`, `ATOM_PARALLEL_MIN`) are in `Geometry`.
