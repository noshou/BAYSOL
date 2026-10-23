# MolecularStructure

## Overview

MolecularStructure converts a PDB ID, a local .pdb/.cif file, or an arbitrary URL into a parsed, protonated structure suitable for the forward-scattering model (`Scattering.forward_cache`).

The workflow is:

1. **Resolve** a structure source to a canonical local .pdb (StructureSource.jl), keeping the protein, the DNA/RNA (modified bases included) and dropping waters, ions and ligands; Components.jl says what a residue name is.
2. **Add hydrogens** (optional) with [`Hydrogenator`](@ref BAYSOL.Hydrogenator), which has its own module and README: PROPKA pKa prediction and pdb2pqr, with a choice of force field and titration method.
3. **Parse** the structure into the internal Molecule representation (Mols.jl).

Step 2 is optional: `BAYSOL.seed_model(...; add_hydrogens=false)` skips it, for pre-hydrogenated models (which pdb2pqr refuses, e.g. SASDP48). The hydrogenator caches its output in `_store_dir()`, the `_cache/` path this module provides. The run report marks each step `[cache hit]`/`[cache miss]` in its timing section.

```julia
using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule
using BAYSOL.Hydrogenator: propka_pKas, resolve_hydrogens, Propka

path = resolve_structure(LocalPathSource(pdb_path))
hpath = resolve_hydrogens(path, pH; titration = Propka(propka_pKas(path)))
mol = load_molecule(hpath)
```

## Module components

- AtomicRadii.jl: element/ion string → radius lookup over the bundled `atomic_radii.sqlite3` (`lookup_radii`), the radii `Mols.jl` builds `radii(mol)` from.
- Components.jl: what a residue name stands for (nucleotide or not), from the bundled wwPDB table `components.tsv`, the local cache and, last, the RCSB.
- Checks.jl: chain-id reuse and duplicate-atom repair, and the detection of dummy-atom models.
- StructureSource.jl: resolves local files, PDB IDs, and URLs.
- Mols.jl: defines the internal molecule and residue representations.

The per-atom excluded volumes that `vols(mol)` returns, and the surface sampling, are computed by [`Geometry`](@ref BAYSOL.Geometry); `Molecule` is a `Geometry.SphereCloud`.

## Components.jl

`component(id)` returns what the wwPDB Chemical Component Dictionary says about a residue name (matched case-insensitively): `(id, class, type, parent, formula, n_hydrogens, source)`, where `class` is `:dna`, `:rna` or `:other`, `parent` is the standard residue a modified one derives from (`nothing` for none), and `n_hydrogens` is read from the formula of the free monomer (`C9 H13 N2 O9 P` is 13; deuterium counts as hydrogen). `is_nucleotide(id)` is true for DNA and RNA components, standard or modified; the water names (`HOH WAT DOD H2O`) are false without a lookup. The table has seven columns, `id class type parent formula base base_source` (a five-column table is read too, without bases). `parent` is what the dictionary declares; `base` is the natural base (`A C G U T`) a DNA/RNA component stands for, declared or inferred, and `base_source` says which: `parent` (the declared parent followed up to a standard residue), `self` (a standard residue), `letter` (the dictionary's one-letter code), `ring` (the ring chemistry; it cannot tell U from T, so a U/T ring alone gives no base) or `name` (the component's name); `-` for none. Over the 843 DNA/RNA rows: parent 562, self 10, letter 8, ring 52, name 41, none 170. The inference is offline, in `dev/extract_components.clj`, and was validated there against the 562 declared parents (letter 100 % precision, ring 99.2 %, name 97.8 %, combined 99.4 % at 91.1 % coverage). A component read from a cached or downloaded file has the base of its declared parent, else none (`base_source` `:none`), and an Amber name such as `RG` has the plain base's, source `:self`. Nothing in loading, the force-field choice or the classification depends on `parent` or `base`.

The `parent` is the standard residue a modified one derives from, normalised on reading (a list such as `DT, DT` becomes `DT`, a non-standard parent such as `TTD` is followed up to a standard id); `nothing` means no declared or resolvable parent and is never an error. Of the 843 DNA/RNA components of the bundled table 565 have a parent and 278 do not (14 of those are the standard and placeholder ids `A C G U DA DC DG DT DU DI I N DN T`, the other 264 terminal variants such as `0C` and unnatural nucleotides). Nothing in loading, the force-field choice or the classification depends on the parent. A nucleotide is *modified* when its id is not one of those 14 (`STANDARD_NUCLEOTIDES`) nor an Amber name, parent or not (829 of the 843).

The legacy ids `ADE GUA CYT URI THY` (`LEGACY_NUCLEOTIDE_NAMES`) are free bases in the dictionary and stay `:other` here; they count as nucleotides only with the sugar-phosphate backbone, which needs atoms and so lives in the content scan (`legacy_nucleotides_in_file`, `legacy_nucleotides_in_model`; the rule is in the Hydrogenator README). The loader and the canonical writer keep HETATM residues that satisfy it.

The Amber/pdb2pqr names (`RA RC RG`, `DA5 DT3 DAN`, ... in `AMBER_NUCLEIC_NAMES`) are reported as nucleotides (`rna linking`/`dna linking`, `parent` the plain base, the base's formula) before the table is consulted, because the table also uses some of them for unrelated ligands; `RU` stays ruthenium. The free-base ids `ADE CYT GUA THY URA` are not nucleotides (the dictionary has them as non-polymers). `nucleotide_selector` is the BioStructures atom selector `!ishetero(at) || is_nucleotide(resname(at))`, kept for its own sake; `load_molecule` and `resolve_structure` use `polymer_selector` (not exported), which also keeps the HETATM atoms of **amino acids**, instead of `standardselector`, which drops every HETATM record, modified bases and residues such as selenomethionine among them.

`is_amino_acid(id)` (not exported) is true for a component whose dictionary type names `peptide linking` (L, D and plain) or a peptide amino or carboxy terminus, not `peptide-like`; `UNK` and water are false without a lookup. `amino_parent(id)` (not exported) is the standard amino acid (of the twenty, `STANDARD_AMINO_ACIDS`) a modified one derives from, read from the table's parent column and resolved like the nucleotides' (`MSE` is `MET`, `SEP` is `SER`, `PTR` is `TYR`; 1138 of the 1861 amino acid components have one); it is the only place the amino acids' parent is used, `ComponentInfo.parent` keeps the nucleotides' meaning.

```julia
using BAYSOL.MolecularStructure: component, is_nucleotide, ComponentError

component("psu")        # (id = "PSU", class = :rna, parent = "U", n_hydrogens = 13, source = :builtin, ...)
is_nucleotide("5MC")    # true
is_nucleotide("MG")     # false
```

The lookup order is fixed:

1. **The bundled table** `components.tsv`: all 51,437 components of the dictionary at the time it was generated (843 are DNA/RNA), one line each, `id class type parent formula`, `#` lines are comments, `-` is no parent. It is generated by `dev/extract_components.clj` and read once, lazily, at the first lookup. `source` is `:builtin`.
2. **The cache**: `_cache/components/<ID>.cif`. If the file is there it is used and nothing is downloaded (`:cache`).
3. **The RCSB**: for a residue newer than the table, `https://files.rcsb.org/ligands/download/<ID>.cif` is downloaded into the cache (checked to be a component file before it is moved into place, so a failed download leaves nothing behind; `:download`). The constants (`COMPONENT_CACHE_DIR`, `COMPONENT_URL`, `COMPONENT_TIMEOUT_S`, `WATER_NAMES`) are in MolecularStructure.jl.

A component file that lacks `_chem_comp.id`, `.type` or `.formula` (or whose id is another residue's) is rejected: a downloaded one is not cached and raises `ComponentError`; an invalid cached one is ignored, removed and fetched once more. Without a network, a residue that is in neither the table nor the cache raises `ComponentError` ("couldn't look up residue X; are you offline?" and the reason). A name that cannot be a wwPDB id (other characters than letters and digits, such as the ion `K+`; longer than five characters; empty) is an unknown, non-nucleotide residue at once, with no network access, nothing cached and no error (a lower-case `k` is the ion `K`). If the dictionary answers "no such component" (HTTP 404: a custom ligand name, an Amber-style residue name such as `HIE`), the residue is taken as unknown and not a nucleotide, nothing is cached and nothing is raised. Network access is thus only needed for residue names newer than the table. The download goes through the hook `MolecularStructure._COMPONENT_DOWNLOAD[]`, a function `(url, dest)` that tests replace to simulate an offline or online network.

`BAYSOL.seed_model` records the lookups as the `components` stage of the timing log, with the number of names found in the table, the cache and by download.

## Checks.jl

Checks and repairs of the text of a .pdb that its readers cannot take as it is, and a log of models BAYSOL is not meant for. All by text scan, never a strict parse.

- **Chain ids reused** (`sanitized_copy`): a TER-separated block whose chain reuses an id **and** a residue number of an earlier block (SASDAC9: two 186-nt RNAs both labelled `A`, numbered 600-785) gets the next unused id of `CHAIN_LETTERS` (`A-Z a-z 0-9`; a clear `MoleculeError` if they run out). A chain that only continues after a TER (a ligand or waters under the protein's id, with other residue numbers) is left alone. Both real chains stay in the model; chain letters never reach the scattering model, so the relabelling changes nothing in the profile.
- **True duplicate atoms** (same chain after relabelling, residue number, atom name and alternate-location id), which BioStructures refuses and which would count twice in the profile, are dropped (the later copies); the count is logged.
- `load_molecule` and the pdb2pqr run apply both to a temporary copy only when the file needs it; `structure_issues(path)` counts them without writing; `BAYSOL.seed_model` reports them in its `structure checks` stage.
- **Dummy-atom and fragment models** (`dummy_like_residues`, `log_dummy_like`): BAYSOL's behaviour on CORAL/EOM linker residues, `UNK` dummy residues, bead models or phosphates split off as residues is **undefined**. The detector flags, and one `@warn` per structure logs, without changing anything: an ATOM-record `UNK/DUM/DUMMY/UNL` residue; an ATOM-record residue with at most 2 heavy atoms that is not a water, ion or component that small; a protein residue lacking `N`, `CA` or `C`; a nucleotide residue with fewer than four backbone atoms and no base atom; duplicate atoms; and more than 5 % (but not all) of the atoms with B = 0.00 and occupancy 0. The constants are in MolecularStructure.jl (`DUMMY_*`). Tested on six real dummy-atom and fragment models from SASBDB that are not part of the suite (all flagged: nucleotide fragments, one-atom linker residues, `UNK` residues, duplicate atoms) and on the clean fixtures (not flagged, apart from genuinely incomplete residues in a few of them). and the clean fixtures (not flagged, with the exceptions listed in the Hydrogenator notes: genuinely incomplete residues in 6PTI, SASDA52, SASDF42, SASDV94).

## StructureSource.jl

`resolve_structure(source::StructureSource)` -> String resolves any of three input shapes to an absolute path to a canonical .pdb in `_store_dir()` (first model only, whatever its MODEL number; heavy atoms of the standard residues and of every nucleotide and amino acid, modified ones (HETATM records such as `PSU`, `5MC`, `MSE`, `SEP`) included; no waters, ions, ligands, saccharides or hydrogens).

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

`vols` is **not** (4/3)π·radii(mol)³ (see the Geometry README).

`create(name, elms, coords)` centres coords at the centroid and computes both coordinate frames eagerly; radii/vols/`r_max` are resolved and cached on first access.

### `load_molecule`

```julia
mol = load_molecule(pdb_path)
```

Parses whatever .pdb is at `pdb_path` into a Molecule (a file with no atom records raises `MoleculeError`; chains reusing an id and duplicate atoms are repaired first, see Checks.jl): the ATOM records and the HETATM records of nucleotides and amino acids (`polymer_selector`; waters, ions, ligands, saccharides and `UNK` are left out; one `@info` per structure names the modified amino acids kept). Only the first model is read, whatever its MODEL number, so an ensemble member extracted to its own file (e.g. `MODEL 63`) loads correctly.

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

Three rows have a negative radius. These are genuine Shannon (1976) values: the scale is anchored to a reference O²⁻ radius (140 pm), not an absolute size, so a cation with little electron cloud of its own (a bare proton, C4+, N5+) can land below that baseline. Any code that turns radius into a physical  volume/sphere must treat radius ≤ 0.0 the same as "no entry found" and fall through to `atomic_radii`.

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

`radius_type`: van der Waals, metallic and covalent radii are different quantities (covalent radii run 30–70% smaller than van der Waals radii).

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

212 rows, one per `ionic_radii` row. It answers "which charge states does this element have data for" and "which is closest to the one I want" with one query instead of re-parsing every `ionic_radii.ion` string:

```sql
-- nearest available charge state for element 'fe', target charge +5
SELECT ion, charge FROM element_charges
WHERE element = 'fe' ORDER BY ABS(charge - 5) LIMIT 1;
```

1. Try `ionic_radii` for the exact ion first
2. If that misses, use `element_charges` to find the nearest charge state for that  element
3. Fall back to `atomic_radii`'s bare-element value.

If `element_charges` is regenerated, rebuild it from `ionic_radii`.

## MolecularStructure.jl

Includes AtomicRadii.jl, Mols.jl, Components.jl, Checks.jl and StructureSource.jl in dependency order and provides `_store_dir()`, the shared `_cache/` path used throughout the module. The geometry constants (`N_VOL_SHELL`, `ATOM_BLOCK`, `ATOM_PARALLEL_MIN`) are in `Geometry`.
