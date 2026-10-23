# MolecularStructure

Converts a PDB ID, a local `.pdb`/`.cif` file or a URL into a parsed structure suitable for the forward model (`Scattering.forward_cache`).

1. **Resolve** a source to a canonical local `.pdb` (`StructureSource.jl`): the first model, heavy atoms of the polymer (protein, DNA/RNA, modified residues written as HETATM included), no waters, ions or ligands.
2. **Add hydrogens** (optional) with [`Hydrogenator`](@ref BAYSOL.Hydrogenator), which has its own README. `seed_model(...; add_hydrogens=false)` skips it, for pre-hydrogenated models (which pdb2pqr refuses, e.g. SASDP48). The hydrogenator caches in `_store_dir()`, the `_cache/` path this module provides; the report marks each step `[cache hit]`/`[cache miss]`.
3. **Parse** into a `Molecule` (`Mols.jl`).

```julia
using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule
using BAYSOL.Hydrogenator: propka_pKas, resolve_hydrogens, Propka

path  = resolve_structure(LocalPathSource(pdb_path))
hpath = resolve_hydrogens(path, pH; titration = Propka(propka_pKas(path)))
mol   = load_molecule(hpath)
```

Files: `AtomicRadii.jl` (element/ion → radius), `Components.jl` (what a residue name is), `Checks.jl` (repairs and dummy-model detection), `StructureSource.jl`, `Mols.jl`. The per-atom excluded volumes behind `vols(mol)` and the surface sampling are in [`Geometry`](@ref BAYSOL.Geometry); `Molecule` is a `Geometry.SphereCloud`.

## Molecule

```julia
mol = create("my-mol", elements, coords)   # coords: any iterable of 3-vectors
coords_cartesian(mol)   # (3, n) centred (x, y, z)
coords_spherical(mol)   # (3, n) (r, θ, φ), θ = acos(z/r) ∈ [0, π], φ = atan(y, x) ∈ (-π, π]
radii(mol)              # van der Waals radii, lazy, via `lookup_radii`
vols(mol)               # per-atom excluded volume (Geometry); NOT (4/3)π·radii³
r_max(mol)              # largest radius (neighbour-filter bound of `Geometry.sasa`)
```

`create` translates the coordinates to the **centroid**, `c_i ← c_i − (1/n)Σ c_k`, and computes both frames eagerly; radii, volumes and `r_max` are `Runtime.Lazy` values resolved on first use. The intensity is independent of the origin but the multipole truncation is not: at the centroid the radii `r_i` are smallest, so fewer degrees `l` are needed (Scattering) and the radius-sorted tiling is tighter. `r = 0` is handled explicitly (the angle is unobservable, `j_l(0) = 0` for `l > 0`).

`load_molecule(pdb_path)` reads the first model whatever its MODEL number (so an ensemble member extracted to its own file loads), the ATOM records and the HETATM records of nucleotides and amino acids (`polymer_selector`; waters, ions, ligands, saccharides and `UNK` are left out, one `@info` per structure names the modified amino acids kept). A file with no atom records raises `MoleculeError`; reused chain ids and duplicate atoms are repaired first (Checks).

## Components

`component(id)` returns what the wwPDB Chemical Component Dictionary says (case-insensitive): `(id, class, type, parent, formula, n_hydrogens, source)`. `class` is `:dna`, `:rna` or `:other`; `n_hydrogens` is read from the formula of the free monomer (deuterium counts as hydrogen); `parent` is the standard residue a modified one derives from, normalised on reading (a list `DT, DT` becomes `DT`, a non-standard parent such as `TTD` is followed up to a standard id), `nothing` if none. `is_nucleotide(id)` is true for DNA and RNA components, standard or modified; water names (`HOH WAT DOD H2O`) are false without a lookup. A nucleotide is *modified* when its id is not one of the 14 `STANDARD_NUCLEOTIDES` (`A C G U DA DC DG DT DU DI I N DN T`) nor an Amber name (829 of the 843 DNA/RNA components). Nothing in loading, force-field choice or classification depends on `parent` or `base`; they are used only by the hydrogenation.

The bundled table `components.tsv` has seven columns, `id class type parent formula base base_source` (a five-column table is read too), for all 51,437 components (843 DNA/RNA; `#` lines are comments, `-` is none). `base` is the natural base (`A C G U T`) a component stands for, declared or inferred, and `base_source` says how: `parent` (562), `self` (10), `letter` (8, the dictionary's one-letter code), `ring` (52, ring chemistry; it cannot tell U from T), `name` (41), `-` none (170). The inference is offline, in `dev/extract_components.clj` (`bb extract-components`), validated against the 562 declared parents (letter 100 %, ring 99.2 %, name 97.8 %; combined 99.4 % precision at 91.1 % coverage). A component read from a cached or downloaded file has the base of its declared parent, else none.

Special cases: the legacy ids `ADE GUA CYT URI THY` (`LEGACY_NUCLEOTIDE_NAMES`) are free bases in the dictionary and stay `:other`; they count as nucleotides only with the sugar-phosphate backbone, which needs atoms and lives in the content scan (rule in the Hydrogenator README); the loader keeps such HETATM residues. The Amber/pdb2pqr names (`RA RC RG`, `DA5 DT3 DAN`, … in `AMBER_NUCLEIC_NAMES`) are nucleotides, answered before the table (which also uses some for unrelated ligands; `RU` stays ruthenium). The free-base ids `ADE CYT GUA THY URA` are not nucleotides.

`is_amino_acid(id)` (not exported) is true for a `peptide linking` component (L, D and plain) or a peptide amino/carboxy terminus, not `peptide-like`; `UNK` is false. `amino_parent(id)` (not exported) is the standard amino acid among the twenty a modified one derives from (`MSE` → `MET`, `SEP` → `SER`, `PTR` → `TYR`; 1138 of 1861), resolved like the nucleotides'. `polymer_selector` (not exported) is the loader's atom selector (ATOM records plus HETATM of nucleotides and peptide-linking amino acids); `nucleotide_selector` is kept for its own sake.

```julia
using BAYSOL.MolecularStructure: component, is_nucleotide, ComponentError
component("psu")        # (id = "PSU", class = :rna, parent = "U", n_hydrogens = 13, source = :builtin, ...)
is_nucleotide("5MC")    # true
```

**Lookup order:** (1) the bundled table, read once lazily (`source = :builtin`); (2) the cache `_cache/components/<ID>.cif` (`:cache`); (3) a download from `https://files.rcsb.org/ligands/download/<ID>.cif` into the cache, for a residue newer than the table (`:download`; checked to be a component file before it is moved into place). A file lacking `_chem_comp.id`, `.type` or `.formula`, or with another residue's id, is rejected: a downloaded one raises `ComponentError`, an invalid cached one is removed and fetched once more. Offline, a residue in neither table nor cache raises `ComponentError`. A name that cannot be a wwPDB id (other characters than letters and digits such as the ion `K+`, longer than five characters, empty) is an unknown non-nucleotide at once, with no network access (a lower-case `k` is the ion `K`); an HTTP 404 (a custom ligand, an Amber-style name such as `HIE`) is also an unknown non-nucleotide, nothing cached or raised. The download goes through the hook `_COMPONENT_DOWNLOAD[]` (`(url, dest)`), which tests replace. Constants: `COMPONENT_CACHE_DIR`, `COMPONENT_URL`, `COMPONENT_TIMEOUT_S`, `WATER_NAMES` in `MolecularStructure.jl`. `seed_model` records the `components` stage (names found in the table, cache and by download).

## Checks

- **Reused chain ids** (`sanitized_copy`): a TER-separated block reusing an id **and** a residue number of an earlier block (SASDAC9: two 186-nt RNAs both labelled `A`) gets the next unused id of `CHAIN_LETTERS` (`A-Z a-z 0-9`; `MoleculeError` if they run out). A chain that merely continues after a TER (ligand or waters under the protein's id, other residue numbers) is left alone. Chain letters never reach the scattering model.
- **True duplicate atoms** (same chain after relabelling, residue number, atom name and altloc), which BioStructures refuses and which would count twice, are dropped (the later copies; logged).
- `load_molecule` and the pdb2pqr run apply both to a temporary copy only when the file needs it; `structure_issues(path)` counts without writing; `seed_model` reports them in the `structure checks` stage.
- **Dummy-atom and fragment models** (`dummy_like_residues`, `log_dummy_like`): BAYSOL's behaviour on CORAL/EOM linker residues, `UNK` dummies, bead models or split-off phosphates is **undefined**. The detector flags and logs one `@warn` per structure, changing nothing: an ATOM-record `UNK/DUM/DUMMY/UNL` residue; an ATOM-record residue of at most 2 heavy atoms that is not a water, ion or component that small; a protein residue lacking `N`, `CA` or `C`; a nucleotide with fewer than four backbone atoms and no base atom; duplicate atoms; more than 5 % (but not all) of the atoms with `B = 0.00` and occupancy 0. Constants `DUMMY_*`. Tested on six real dummy-atom models from SASBDB (all flagged) and the clean fixtures (only genuinely incomplete residues in a few: 6PTI, SASDA52, SASDF42, SASDV94). **B-factors and occupancy are never read** for the model, so an all-zero B column (MD and modelled structures) is not a defect; occupancy 0 on atoms stays flagged because they would count as full atoms.

## Structure Source

`resolve_structure(source)` → absolute path to a canonical `.pdb` in `_store_dir()` (first model, heavy atoms of the standard residues and of every nucleotide and amino acid, modified ones such as `PSU`, `5MC`, `MSE`, `SEP` included; no waters, ions, ligands, saccharides or hydrogens).

- `LocalPathSource(path)`: a file on disk; if one already exists under that name the converted result is byte-compared, identical content is reused and different content raises `StructureSourceError`.
- `PDBIDSource(id)`: a 4-character RCSB ID, fetched with `BioStructures.retrievepdb`, stored under the uppercased ID; a repeat request trusts an existing file.
- `URLSource(url, id)`: legacy `.pdb` or mmCIF (sniffed from the content via the literal `loop_`, not the URL), stored under `id` (empty raises `StructureSourceError`); every call re-downloads and re-converts and byte-compares as above.

## Atomic Radii

`lookup_radii(ions)` over the bundled `atomic_radii.sqlite3` (loaded once), independent of residue identity: the isolated radii that SASA, the hydration shell and the power-diagram excluded volumes are built on. Lookup order: the exact ion in `ionic_radii`; else the nearest charge state for that element from `element_charges`; else the bare-element `atomic_radii` value. A radius ≤ 0 counts as "no entry".


| table                                                      | contents                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ionic_radii(ion PK, radius pm)`                           | 210 Shannon (1976) ions (10.1107/S0567739476001551) plus Au⁻ (Feldmann 1995, 10.1002/zaac.19956211113) and H⁻ (Pauling 1960); `ion` = lowercase symbol + \|charge\| + sign (`fe3+`, `cl1-`). Three radii are negative (H⁺ −38.0, N⁵⁺ −10.4, C⁴⁺ −8.0 pm): genuine, since the scale is anchored to O²⁻ = 140 pm    |
| `atomic_radii(element PK, radius Å, radius_type, source)` | 118 elements: `vdw` for 98 (Alvarez 2013, 10.1039/c3dt50599e, H–Es minus Po/At/Fr/Ra; Po/At/Fr/Ra from Mantina 2009, 10.1021/jp8111556), `metallic` for Pm (Teatum 1968, no Alvarez data), `covalent` for Fm–Lr and Rf–Og (Pyykkö & Atsumi 2009, 10.1002/chem.200800987; covalent radii run 30–70 % below van der Waals) |
| `element_charges(element, charge, ion → ionic_radii)`     | 212 rows, one per ionic radius: which charge states have data, nearest to a target with one query; rebuild it if `ionic_radii` is regenerated                                                                                                                                                                                 |

`MolecularStructure.jl` includes these files in dependency order and provides `_store_dir()`. The geometry constants (`N_VOL_SHELL`, `ATOM_BLOCK`, `ATOM_PARALLEL_MIN`) are in `Geometry`.
