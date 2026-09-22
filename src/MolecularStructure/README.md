# MolecularStructure

## Overview

`MolecularStructure` converts a PDB ID, a local `.pdb`/`.cif` file, or an arbitrary URL into a parsed, protonated, and charge-annotated structure suitable for the forward-scattering model (`Scattering.forward_cache`) and the cavity-electrostatics prior in `Solvation.Electrostatics`.

The workflow is:

1. **Resolve** a structure source to a canonical local `.pdb` (`StructureSource.jl`).
2. **Predict** per-residue-instance pKa values using external `PROPKA` (`Propka.jl`).
3. **Add hydrogens** for a target pH using `PDB2PQR`, with pKa predictions used to resolve free-terminal protonation states (`PDB2PQR.jl`).
4. **Parse** the structure into the internal `Molecule`/`Residues` representation (`Mols.jl`).
5. **Compute ionization** by assigning per-atom fractional charges, protonation states, and pH-related charge uncertainties using the PROPKA pKas and `charge_topology.json` (`Ionization.jl`).

```julia
using BayeSol.MolecularStructure: LocalPathSource, resolve_structure, load_molecule,
 propka_pKas, resolve_hydrogens, Ionization

path = resolve_structure(LocalPathSource(pdb_path))
pKa_records = propka_pKas(path)
hpath = resolve_hydrogens(path, pKa_records, pH; add = true)
mol, residues = load_molecule(hpath)

ionization = Ionization(residues, pKa_records, pH, σ_pH)
```

## Module components

- `StructureSource.jl`: resolves local files, PDB IDs, and URLs.
- `Mols.jl`: defines the internal molecule and residue representations.
- `Propka.jl`: predicts and parses pKa values for individual residue instances.
- `PDB2PQR.jl`: adds hydrogens at a target pH.
- `Ionization.jl`: computes fractional charges, protonation states, and charge uncertainty.
- `charge_topology.json`: defines charge-bearing atoms and charge-splitting rules.

## `StructureSource.jl`

`resolve_structure(source::StructureSource) -> String` resolves any of three input shapes to an absolute path to a canonical `.pdb` in `_store_dir()` (model 1 only, `standardselector`/`heavyatomselector`-filtered: no HETATM/ waters, no hydrogens). 

- **`LocalPathSource(path)`**: a structure already on local disk; if a file already exists under that name, the freshly-converted result is byte-compared against it. Identical content reuses the existing file, different content under the same name raises `StructureSourceError`.
- **`PDBIDSource(id)`**: a structure identified by its 4-character RCSB PDB ID (e.g. `"1CRN"`), fetched via `BioStructures.retrievepdb` and stored under the uppercased ID. A repeat request for the same ID trusts an existing file's presence and skips fetching.
- **`URLSource(url, id)`**: a structure at an arbitrary `url`, in either legacy `.pdb` or mmCIF format (sniffed from the downloaded content via the literal `loop_` keyword, not the URL), stored under the caller-supplied `id`. Every call re-downloads and re-converts, unlike`PDBIDSource`, and the result is then byte-compared against any existing file under`id`with the same collision policy. Constructing a`URLSource`with an empty`id`raises`StructureSourceError`.

```julia
using BayeSol.MolecularStructure: LocalPathSource, PDBIDSource, URLSource, resolve_structure

path1 = resolve_structure(LocalPathSource("structure.cif"))
path2 = resolve_structure(PDBIDSource("1CRN"))
path3 = resolve_structure(URLSource("https://files.rcsb.org/download/1CRN.pdb", "1CRN-mirror"))
```

## `Mols.jl`

### `Molecule`

Per-atom centered coordinates in both cartesian and spherical frames, with lazily computed `radii`/`vols`/`r_max`. Both coordinate frames are `(3, n)` matrices sharing a column index (the atom); the spherical rows are `r`, `theta`, `phi` in that order (`theta = acos(z/r) ∈ [0, π]`, `phi = atan(y, x) ∈ (-π, π]`). `r = 0`is handled explicitly rather than producing a`0/0`, since the angle is unobservable downstream anyway (`j_l(0) = 0`for every`l > 0`).

```julia
using BayeSol.MolecularStructure: create, coords_cartesian, coords_spherical,
 radii, vols, r_max, elms, name, n_atoms

mol = create("my-mol", elements, coords) # coords: any iterable of 3-tuples/vectors
coords_cartesian(mol) # (3, n) centered (x, y, z)
coords_spherical(mol) # (3, n) (r, theta, phi)
radii(mol) # per-atom radius, lazy/memoized, via AtomicRadii by default
vols(mol) # per-atom sphere volume, (4/3)πr³ of radii(mol)
r_max(mol) # largest per-atom radius; SASA's neighbour-filter bound
```

`create(name, elms, coords; radii_source::RadiiSource = AtomicRadiiSource())` centers `coords` at the centroid and computes both coordinate frames eagerly; `radii`/`vols`/`r_max` are resolved (and cached) only on first  access, through `AtomicRadii.RadiiSource`. 

### `Residues`

```julia
struct Residues
 resname :: Vector{String}
 atomname :: Vector{String}
 resnum :: Vector{Int}
 chain :: Vector{String}
end
```

Per-atom residue identity for a protein `Molecule`: standard PDB identity, one entry per atom, aligned with `Molecule`'s own atom index. `resnum`/`chain` distinguish different *instances* of the same residue type (two separate `"ASP"` residues at different sequence positions).

### `load_molecule`

```julia
mol, residues = load_molecule(pdb_path) # Tuple{Molecule, Residues}
```

Parses whatever `.pdb` is at `pdb_path` into a `Molecule`/`Residues` pair.

## `Propka.jl` 

A free amino acid's textbook pKa is valid only in isolation. Inside a folded protein, a titratable side chain's *actual* pKa is shifted by its local electrostatic and desolvation environment: burial away from solvent, hydrogen bonding, and proximity to other charged groups all perturb it. PROPKA computes these per-residue-instance, structure-derived pKa shifts from the folded 3D geometry, which is why `Ionization.jl` takes one pKa *per residue instance* (keyed by `(resname, resnum, chain)`) rather than one fixed value per residue *type*.

```julia
using BayeSol.MolecularStructure: propka_pKas, PropkaError

records = propka_pKas(pdb_path)
# Vector{<:NamedTuple}, one per standard titratable group:
# (resname::String, resnum::Int, chain::String, pKa::Float64)
```

## `PDB2PQR.jl` 

 A structure resolved from RCSB or a bare crystallographic `.cif`/`.pdb`  typically carries heavy atoms only. The forward-model geometry step needs an explicit, pH-consistent set of atoms (hydrogens included) to compute scattering correctly, and *which* hydrogens a titratable group carries depends on its protonation state at the solution pH being fit against (e.g. a free amine's three vs. two hydrogens, a carboxylate's presence/absence of an "HO"). `PDB2PQR.jl` runs the external `pdb2pqr` tool to add hydrogens consistent with a target pH and force field, so the geometry passed downstream matches the physical/chemical state the fit assumes.

```julia
using BayeSol.MolecularStructure: resolve_hydrogens, PDB2PQRError

hpath = resolve_hydrogens(pdb_path, pKa_records, pH; add = true)
```

`resolve_hydrogens(pdb_path, pKa_records, pH; add=true)`:

- With `add=true` (default), runs `pdb2pqr --ff PARSE --titration-state-method propka --with-ph <pH>` on the heavy-atom `.pdb` at `pdb_path` and returns the path to a hydrogen-included `.pdb` stored in `_store_dir()` under `"<stem>_pH<pH>.pdb"`. A repeat call for the same `(stem, pH)` is a cache hit and not re-run.
- With `add=false`, it is a no-op: `pdb_path` is returned unchanged.

`pKa_records` must be the records `propka_pKas` produced **on this same structure**.

### Terminus protonation

`pdb2pqr`'s  terminus handling is not pH-driven (it defaults to a fixed charged state). `_terminus_flags(pKa_records, pH)` overrides this from the `"N+"`/`"C-"`, producing `pdb2pqr`'s `--neutraln`/`--neutralc` CLI flags. A free N-terminus gets `--neutraln` when it's deprotonated (neutral), a free C-terminus gets `--neutralc` when it's protonated (neutral). Since these flags are global (not per-chain), a structure whose multiple free N-termini (or C-termini) round to *different* protonation states at the same`pH`cannot be represented by a single`pdb2pqr`run. `PDB2PQRError` is raised when`pdb2pqr` cannot be run or produces no usable output (bad input path, non-zero exit, missing expected output file).

## `Ionization.jl`

### Henderson-Hasselbalch math

For a **base** group (charged when protonated; His, Lys, Arg side chains, the free N-terminus), the protonated (charged) fraction at solution pH is:

```
f = 1 / (1 + 10^(pH - pKa))
```

For an **acid** group (charged when deprotonated; Asp, Glu side chains, Cys, Tyr, the free C-terminus), the deprotonated (charged) fraction is:

```
f = 1 / (1 + 10^(pKa - pH))
```

`_fraction_deprotonated`is exactly`_fraction_protonated`with`pH`and`pKa`swapped, i.e.`1 - _fraction_protonated(pH, pKa)`. In both cases `f == 0.5`at`pH == pKa`. A group's signed fractional charge (`_group_charge`) is `+f`for a base,`-f` for an acid, and a single atom's charge contribution (`_atom_charge`) is its `split`fraction of that. Whether a group carries its exchangeable hydrogen at all (`_group_protonated`) reduces to the same `charged ⟺ fraction > 0.5` rule for both types: a group sitting exactly at its own pKa (`f == 0.5`) always rounds to its *uncharged* state, for both acid and base groups. This is the rule `PDB2PQR.jl`'s `_terminus_flags` also uses to decide `--neutraln`/`--neutralc`.

### σ_pH → σ_charge propagation

Solution pH is itself uncertain (`σ_pH`); this uncertainty is propagated into a first-order (delta-method) charge uncertainty. Since both fraction functions share the same functional form up to `pH ↔ pKa` sign, their derivative is `∓ln(10)·f·(1-f)`, giving:

```
σ_f = |df/dpH| · σ_pH = ln(10) · f · (1 - f) · σ_pH
```

`_σ_atom_charge` scales this by the same per-atom `split` fraction as `_atom_charge`. This `σ_charge` is what `Solvation.Electrostatics` later combines in quadrature with spatial spread to get its own `σ_χ` for the cavity-water contrast prior (see `src/Solvation/README.md`).

### Matching pKa records onto atoms: `_matching_atoms`

Each pKa record (`resname`, `resnum`, `chain`, `pKa`) is matched to the atoms of one residue instance in a `Residues`. For an ordinary side-chain group, the match requires `(resname, resnum, chain)` equality with the record, restricted to atoms named in that group's `atoms` map. For a terminus group (`"N+"`/`"C-"`) the residue's own`resname`in`Residues`is never`"N+"`/`"C-"`; a terminal residue keeps its real amino-acid name. The match is by `(resnum, chain)`, looking only for the specific backbone atom(s) name(s) for that terminus (`"N"`for`N+`; `"O"`/`"OXT"`for`C-`).

### `Ionization`

```julia
struct Ionization
 charge :: Vector{Float64}
 σ_charge :: Vector{Float64}
 protonated :: Vector{Bool}
end
```

```julia
using BayeSol.MolecularStructure: Ionization

ionization = Ionization(residues, pKa_records, pH, σ_pH)
```

Builds an `Ionization` aligned with `residues`'s atom index:  each pKa record is matched via `_matching_atoms` (handling the `"N+"`/`"C-"` special case), and every matched atom gets its `charge`, `σ_charge`, and `protonated` state computed from the math above. An atom with no matching record is left at `charge = σ_charge = 0.0`, `protonated = false`; a pKa record that matches no atom in `residues` is silently skipped. 

## `charge_topology.json`

`Ionization.jl` needs, for each titratable group, which atoms carry its charge and how it splits between them, and whether the group is charged when protonated or deprotonated. This is provided by `charge_topology.json` loaded once at module load as`_CHARGE_TOPOLOGY::Dict{String, _ChargeGroup}`.

### Schema

```json
{
 "RESNAME": {"type": "acid" | "base", "atoms": {"ATOMNAME": fraction,...}}
}
```

`fraction` values within one group sum to `1.0`. `type` sets the Henderson-Hasselbalch direction: `"base"` groups are charged when protonated; `"acid"` groups are charged when deprotonated.

### Groups and splits

- **ASP** (`OD1`/`OD2`, acid), **GLU** (`OE1`/`OE2`, acid): even 0.5/0.5 split across the carboxylate's two chemically-equivalent oxygens.
- **CYS** (`SG`, acid), **LYS** (`NZ`, base): single atom, no split needed.
- **TYR** (`OH`, acid): single atom, no split needed.
- **HIS** (`ND1`/`NE2`, base) and **ARG** (`NE`/`NH1`/`NH2`, base): even split across the ring's/guanidinium's resonance-delocalized nitrogens.
- **N+**/**C-**: PROPKA's group-labeling convention for the N-/C-terminus. Matched by residue number and chain, not resname (see `_matching_atoms`
  above).

### Source

"A summary of the measured pK values of the ionizable groups in folded
proteins," *Protein Science* 18(1):247-251 (2009), DOI `10.1002/pro.19`.

## `MolecularStructure.jl` 

Includes the five files above in dependency order (`Mols.jl`, `Ionization.jl`, `Propka.jl`, `StructureSource.jl`, `PDB2PQR.jl`) and provides `_store_dir()`, the shared `_cache/` path used throughout the module.
