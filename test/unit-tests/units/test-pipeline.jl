# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the structure-loading pipeline's primitives composing correctly
# end to end: resloveStruct -> propkaPkas -> resolveHydrogens ->
# loadMolecule, written out explicitly the way real calling code composes
# them (there is no bundled orchestration function in the library -- callers
# do this composition themselves). Needs real subprocess access for
# propka3/pdb2pqr (same assumption as test-propka.jl/test-pdb2pqr.jl) but no
# network access, since the fixture used here is a local .pdb.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure: LocalPathSource, resloveStruct, loadMolecule,
    _storeDir, Molecule, nAtoms, elms, coordsCartesian
using BAYSOL.Hydrogenator: propkaPkas, resolveHydrogens, Propka

const _PIPELINE_FIXTURE =
    joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")

# …loadMolecule
@testset "pipeline: resloveStruct -> propkaPkas -> resolveHydrogens ->" begin

    @test isfile(_PIPELINE_FIXTURE)

    # Clear any stale cache entries from a previous run so the PROPKA/Pdb2pqr
    # steps below are guaranteed to run fresh, not reuse leftovers.
    stem = "1CRN-TEST"
    rm(joinpath(_storeDir(), "$(stem).pka"); force = true)
    for pH in (7.0,)
        rm(joinpath(_storeDir(), "$(stem)_pH$(pH)_parse_propka.pdb"); force = true)
    end

    source = LocalPathSource(_PIPELINE_FIXTURE)
    pH = 7.0

    path = resloveStruct(source)
    molHeavy = loadMolecule(path)
    pKaRecords = propkaPkas(path)
    hpath = resolveHydrogens(path, pH; titration = Propka(pKaRecords))
    molH = loadMolecule(hpath)

    @testset "return types" begin
        @test molHeavy isa Molecule
        @test molH isa Molecule
    end

    @testset "hydrogens were actually added" begin
        nHeavy = nAtoms(molHeavy)
        nH = nAtoms(molH)
        @test nH > nHeavy
        @test any(e -> lowercase(e) == "h", elms(molH))
        @test !any(e -> lowercase(e) == "h", elms(molHeavy))
    end

    @testset "pKaRecords non-empty for a real protein" begin
        @test !isempty(pKaRecords)
        # PROPKA emits the sentinel 99.99 for disulfide-bonded CYS (1CRN has
        # three disulfides, so all six of its CYS residues report it) --
        # a legitimate "does not titrate" value, not a parse error -- so this
        # only checks finiteness, not a fixed numeric range.
        @test all(r -> isfinite(r.pKa), pKaRecords)
        @test any(r -> r.resname in ("ASP", "GLU", "TYR", "ARG", "N+", "C-"), pKaRecords)
    end

    @testset "no non-finite coordinates" begin
        ccHeavy = coordsCartesian(molHeavy)
        ccH = coordsCartesian(molH)
        @test all(isfinite, ccHeavy)
        @test all(isfinite, ccH)
    end

    # Leave the shared _cache/ scratch dir clean for repeat runs.
    rm(joinpath(_storeDir(), "$(stem).pka"); force = true)
    for pH in (7.0,)
        rm(joinpath(_storeDir(), "$(stem)_pH$(pH)_parse_propka.pdb"); force = true)
    end

end
