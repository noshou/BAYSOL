# SPDX-License-Identifier: LGPL-2.1-or-later

module MolecularStructure

"""
    _store_dir() -> String

Package-root-relative, gitignored local store (`_cache/`) shared by every
part of this pipeline that persists files across runs (PROPKA's `.pka`
output, resolved structures, etc.) without version-controlling them.
Resolved via `pkgdir`, not `pwd()`, so it's stable regardless of the
caller's working directory. Created on first use.

This is a flat, permanent, name-keyed local store, **not a cache** in the
usual sense: nothing here is ever invalidated, refreshed, or verified for
staleness. `PDBIDSource` and `propka_pKas` trust a matching filename's
presence outright with no re-verification, which is safe only because
uniqueness is guaranteed *upstream* of this directory (an RCSB ID is stable
by construction; `propka_pKas`'s `.pka` is trusted only because the `.pdb`
that produced it already went through `StructureSource`'s fail-loud
collision check). `LocalPathSource`/`URLSource` don't get a "skip the work"
benefit from this directory at all — they always redo the fetch/conversion
and only deduplicate the *write* once the result is in hand. Shared across
`Propka.jl` and `StructureSource.jl` (hence living here rather than inside
either one).
"""
function _store_dir()::String
    dir = joinpath(pkgdir(@__MODULE__), "_cache")
    mkpath(dir)
    return dir
end

include("Mols.jl")
include("Ionization.jl")
include("Propka.jl")
include("StructureSource.jl")

export  Molecule, MoleculeError, create, coords_cartesian, coords_spherical,
        to_spherical, radii, vols, r_max, elms, name, n_atoms, Residues,
        Ionization, propka_pKas, PropkaError,
        StructureSource, LocalPathSource, PDBIDSource, URLSource,
        StructureSourceError, resolve_structure, load_molecule

end # module
