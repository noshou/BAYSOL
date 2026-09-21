# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises the structure-loading pipeline's primitives composing correctly
# end to end: resolve_structure -> propka_pKas -> resolve_hydrogens ->
# load_molecule, written out explicitly the way real calling code composes
# them (there is no bundled orchestration function in the library -- callers
# do this composition themselves). Needs real subprocess access for
# propka3/pdb2pqr (same assumption as test_propka.jl/test_pdb2pqr.jl) but no
# network access, since the fixture used here is a local .pdb.
include(joinpath(@__DIR__, "testsetup.jl"))

using BayeSol.MolecularStructure: LocalPathSource, resolve_structure, propka_pKas,
                    resolve_hydrogens, load_molecule,
                    _store_dir, Molecule, Residues, n_atoms, elms, coords_cartesian

const _PIPELINE_FIXTURE = joinpath(@__DIR__, "..", "fixtures", "structures", "1CRN-TEST.pdb")

@testset "pipeline: resolve_structure -> propka_pKas -> resolve_hydrogens -> load_molecule" begin

    @test isfile(_PIPELINE_FIXTURE)

    # Clear any stale cache entries from a previous run so the PROPKA/PDB2PQR
    # steps below are guaranteed to run fresh, not reuse leftovers.
    stem = "1CRN-TEST"
    rm(joinpath(_store_dir(), "$(stem).pka"); force = true)
    for pH in (7.0,)
        rm(joinpath(_store_dir(), "$(stem)_pH$(pH).pdb"); force = true)
    end

    source = LocalPathSource(_PIPELINE_FIXTURE)
    pH = 7.0

    path = resolve_structure(source)
    mol_heavy, res_heavy = load_molecule(path)
    pKa_records = propka_pKas(path)
    hpath = resolve_hydrogens(path, pKa_records, pH)
    mol_h, res_h = load_molecule(hpath)

    @testset "return types" begin
        @test mol_heavy isa Molecule
        @test res_heavy isa Residues
        @test mol_h isa Molecule
        @test res_h isa Residues
    end

    @testset "hydrogens were actually added" begin
        n_heavy = n_atoms(mol_heavy)
        n_h = n_atoms(mol_h)
        @test n_h > n_heavy
        @test any(e -> lowercase(e) == "h", elms(mol_h))
        @test !any(e -> lowercase(e) == "h", elms(mol_heavy))
    end

    @testset "pKa_records non-empty for a real protein" begin
        @test !isempty(pKa_records)
        # PROPKA emits the sentinel 99.99 for disulfide-bonded CYS (1CRN has
        # three disulfides, so all six of its CYS residues report it) --
        # a legitimate "does not titrate" value, not a parse error -- so this
        # only checks finiteness, not a fixed numeric range.
        @test all(r -> isfinite(r.pKa), pKa_records)
        @test any(r -> r.resname in ("ASP", "GLU", "TYR", "ARG", "N+", "C-"), pKa_records)
    end

    @testset "no non-finite coordinates" begin
        cc_heavy = coords_cartesian(mol_heavy)
        cc_h = coords_cartesian(mol_h)
        @test all(isfinite, cc_heavy)
        @test all(isfinite, cc_h)
    end

    @testset "Residues field-length internal consistency" begin
        n_heavy = n_atoms(mol_heavy)
        @test length(res_heavy.resname) == n_heavy
        @test length(res_heavy.atomname) == n_heavy
        @test length(res_heavy.resnum) == n_heavy
        @test length(res_heavy.chain) == n_heavy

        n_h = n_atoms(mol_h)
        @test length(res_h.resname) == n_h
        @test length(res_h.atomname) == n_h
        @test length(res_h.resnum) == n_h
        @test length(res_h.chain) == n_h
    end

    @testset "resolve_hydrogens(add=false) is a no-op, load_molecule still works" begin
        noop_path = resolve_hydrogens(path, pKa_records, pH; add = false)
        @test noop_path == path
        mol_noop, res_noop = load_molecule(noop_path)
        @test n_atoms(mol_noop) == n_atoms(mol_heavy)
        @test elms(mol_noop) == elms(mol_heavy)
        @test coords_cartesian(mol_noop) == coords_cartesian(mol_heavy)
    end

    # Leave the shared _cache/ scratch dir clean for repeat runs.
    rm(joinpath(_store_dir(), "$(stem).pka"); force = true)
    for pH in (7.0,)
        rm(joinpath(_store_dir(), "$(stem)_pH$(pH).pdb"); force = true)
    end

end
