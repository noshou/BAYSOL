# MolecularStructure

## Overview

MolecularStructure converts a PDB ID, a local .pdb/.cif file, or an arbitrary URL into a parsed, protonated structure suitable for the forward-scattering model (`Scattering.forward_cache`).

The workflow is:

1. **Resolve** a structure source to a canonical local .pdb (StructureSource.jl).
2. **Predict** per-residue-instance pKa values using external PROPKA (Propka.jl).
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

- StructureSource.jl: resolves local files, PDB IDs, and URLs.
- Mols.jl: defines the internal molecule and residue representations.
- ExcludedVolumes.jl: per-atom displaced-solvent volumes (power-diagram share of each vdW sphere) for the excluded-volume dummy species.
- Propka.jl: predicts and parses pKa values for individual residue instances (only consumed by Pdb2pqr.jl's terminus protonation; there is no other ionization/charge model; the former `Ionization.jl` and the cavity electrostatics were removed).
- Pdb2pqr.jl: adds hydrogens at a target pH (and holds the Henderson-Hasselbalch helpers that pick each chain's terminus protonation).

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
radii(mol) # per-atom van der Waals radius, lazy/memoized, via AtomicRadii by default
vols(mol) # per-atom excluded volume; see ExcludedVolumes.jl below
r_max(mol) # largest per-atom radius; SASA's neighbour-filter bound
```

vols is **not** (4/3)π·radii(mol)³ (see ExcludedVolumes.jl below).

`create(name, elms, coords)` centres coords at the centroid and computes both coordinate frames eagerly; radii/vols/`r_max` are resolved (and cached) only on first  access, through `AtomicRadii.lookup`.

### `load_molecule`

```julia
mol = load_molecule(pdb_path)
```

Parses whatever .pdb is at `pdb_path` into a Molecule. Only the first model is read, whatever its MODEL number, so an ensemble member extracted to its own file (e.g. `MODEL 63`) loads correctly.

## ExcludedVolumes.jl

`sphere_volume(r)` (4π/3·r³, defined in ExcludedVolumes.jl) is the volume of an isolated sphere. vols(mol) is the per-atom volume of the excluded-volume dummy species (`Scattering._gaussian_dummy`): the solvent volume the atom displaces. `excluded_volume(cart, rads, tree, rmax)` computes it geometrically, adapted from Chamberlain, Moore & Grant (2023), 10.1016/j.bpj.2023.10.034: each atom's van der Waals sphere is clipped by the radical (power-diagram) planes of its overlapping neighbours, and the surviving volume is estimated by quasi-random sampling (`N_VOL_SHELL` = 2145 plastic-sequence points per atom). An atom with no overlapping neighbour keeps its whole sphere.

The per-atom volumes sum to the volume of the vdW union. That leaves out the packing voids between atoms that no solvent can reach (with hydrogens, Σvols ≈ 0.73 of the sequence partial molar volume and ≈ 0.66 of CRYSOL's fitted `Vol` on SASDA52). Chamberlain et al. correct for this with per-atom-type scale factors fitted to lysozyme data; BAYSOL instead leaves it to the profiled excluded-volume correction c1. Across the fitting tests c1 ≈ 1.15–1.22, so c1³ ≈ 1.5–1.8 (see `test/fitting_tests/README.md`).

A solvent-excluded-surface (SES) partition that includes those voids was tried on 2026-09-29 and reverted: with it, every tested dataset's best fit required a negative convex-shell contrast (δρ₁ < 0), which the δρ priors exclude, and under the priors SASDA52's fit degraded from `χ²_red` ≈ 6 to ≈ 19.

radii stays the isolated van der Waals radius throughout (SASA and hydration-shell generation need real atomic sizes); vols is **not** (4/3)π·radii³.

## Propka.jl

A free amino acid's textbook pKa is valid only in isolation. Inside a folded protein, a titratable side chain's actual pKa is shifted by its local electrostatic and desolvation environment: burial away from solvent, hydrogen bonding, and proximity to other charged groups all perturb it.

```julia
using BAYSOL.MolecularStructure: propka_pKas, PropkaError

records = propka_pKas(pdb_path)
# Vector{<:NamedTuple}, one per standard titratable group:
# (resname::String, resnum::Int, chain::String, pKa::Float64)
```

## Pdb2pqr.jl

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

## MolecularStructure.jl

Includes the five files above in dependency order (Mols.jl, ExcludedVolumes.jl, Propka.jl, StructureSource.jl, Pdb2pqr.jl) and provides `_store_dir()`, the shared `_cache/` path used throughout the module.

## Constants

Defined at module level in `MolecularStructure.jl`.


`N_VOL_SHELL` (2145 quasi-random points per atom for the power-diagram excluded-volume estimate in `MolecularStructure.excluded_volume`)
