# SPDX-License-Identifier: LGPL-3.0-or-later

# Pins the nucleic-acid fixtures in test/fixtures/molecules/ (real RCSB entries,
# unmodified), what the structure loader keeps of them and what pdb2pqr (PARSE, the one
# force field BAYSOL runs) makes of them. These are the inputs the nucleotide work needs
# (see "Nucleotide support" in the project brief):
#
#   1BNA  B-DNA dodecamer, standard residues only, 80 waters
#   1RNA  A-form RNA helix, A and U only, 91 waters
#   1SDR  RNA dodecamer, all four standard bases, 39 waters
#   246D  RNA with a deoxy-C residue and two Na+ ions (a chimera / HETATM-ion case)
#   1EHZ  yeast tRNA-Phe: 11 modified-base types (HETATM), Mg2+ and Mn2+ ions,
#         160 waters; also as mmCIF to exercise the other loader path
#   3HDD  engrailed homeodomain-DNA complex, chains A-D (protein and DNA)
#
# The loader keeps the HETATM modified bases (not waters or ions), so 1EHZ is 1,652 heavy
# atoms, 323 of them in the 14 modified residues. The hydrogen counts are what pdb2pqr
# 3.x gives through `resolve_hydrogens` (the modified bases through the standard residue
# of their base; hydrogens that exist only in a modification are not placed). They need the
# CondaPkg tools like test_pdb2pqr.jl, no network. The fixtures are copied under their own
# names (`nt-fix-*`) because hydrogenated files are cached by file stem; the cache files
# are removed at the end.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_nucleotide_fixtures

using Test
using BAYSOL

using BAYSOL.MolecularStructure:
    load_molecule, n_atoms, LocalPathSource,
    resolve_structure, _store_dir
using BAYSOL.Hydrogenator: resolve_hydrogens, Propka, NoTitration, Pdb2pqrError,
    _hydrogens_path, _pka_path, hydrogenation_choice, NUCLEIC_FORCE_FIELD,
    DEFAULT_FORCE_FIELD
using BAYSOL.MolecularStructure: component, residue_names

const _FIX = joinpath(@__DIR__, "..", "..", "fixtures", "molecules")
_fix(id, ext = "pdb") = joinpath(_FIX, "$id-TEST.$ext")

# residue-name => record count over the ATOM/HETATM lines of a .pdb fixture,
# split by record type (the fixture's own content, independent of the loader)
function _composition(path)
    atoms = Dict{String,Int}()
    hets = Dict{String,Int}()
    for l in eachline(path)
        startswith(l, "ATOM") || startswith(l, "HETATM") || continue
        d = startswith(l, "ATOM") ? atoms : hets
        r = strip(l[18:20])
        d[r] = get(d, r, 0) + 1
    end
    return atoms, hets
end

# remove the store files (hydrogenated .pdb, .balance, .pka, canonical .pdb) of the stems
# starting with `prefix`
function purge_store(prefix)
    for f in readdir(_store_dir())
        startswith(f, prefix) &&
            rm(joinpath(_store_dir(), f); force = true, recursive = true)
    end
end

# hydrogens (element column) among the non-water atoms of a hydrogenated .pdb
function _n_hydrogens(path)
    n = 0
    for l in eachline(path)
        (startswith(l, "ATOM") || startswith(l, "HETATM")) || continue
        strip(l[18:20]) == "HOH" && continue
        n += strip(l[77:min(end, 78)]) == "H"
    end
    return n
end

# hydrogenate a fixture copied under the stem `nt-fix-<id>` the way the pipeline does (the
# force field and titration `hydrogenation_choice` picks): returns (heavy atoms, atoms,
# hydrogens, whether PROPKA ran, force field)
function _hydrogenated(dir, id; pH = 7.4)
    path = joinpath(dir, "nt-fix-$(lowercase(id)).pdb")
    cp(_fix(id), path; force = true)
    try
        choice = hydrogenation_choice(component.(residue_names(path)), path)
        titration = choice.titration === :propka ? Propka() : NoTitration()
        hp = resolve_hydrogens(path, pH; ff = choice.ff, titration)
        @test occursin("_$(choice.ff)_", basename(hp))
        return (n_atoms(load_molecule(path)), n_atoms(load_molecule(hp)), _n_hydrogens(hp),
            isfile(_pka_path(path)), choice.ff)
    finally
        purge_store("nt-fix-")
    end
end

@testset "nucleotide fixtures" begin

    @testset "1BNA: B-DNA, standard residues" begin
        atoms, hets = _composition(_fix("1BNA"))
        @test atoms == Dict("DG" => 176, "DC" => 146, "DA" => 84, "DT" => 80)
        @test hets == Dict("HOH" => 80)
        @test n_atoms(load_molecule(_fix("1BNA"))) == 486   # no waters
    end

    @testset "1RNA, 1SDR: standard RNA" begin
        atoms, hets = _composition(_fix("1RNA"))
        @test atoms == Dict("A" => 308, "U" => 274)
        @test hets == Dict("HOH" => 91)
        @test n_atoms(load_molecule(_fix("1RNA"))) == 582

        atoms, hets = _composition(_fix("1SDR"))
        @test atoms == Dict("A" => 302, "C" => 200, "G" => 230, "U" => 274)
        @test hets == Dict("HOH" => 39)
        @test n_atoms(load_molecule(_fix("1SDR"))) == 1006
    end

    @testset "246D: DNA residue and Na+ ions inside an RNA" begin
        atoms, hets = _composition(_fix("246D"))
        @test atoms["DC"] == 38 && !haskey(atoms, "C")
        @test hets == Dict("HOH" => 85, "NA" => 2)
    end

    @testset "1EHZ: tRNA with modified bases" begin
        atoms, hets = _composition(_fix("1EHZ"))
        @test atoms == Dict("A" => 374, "C" => 300, "G" => 415, "U" => 240)
        modified = ["1MA", "2MG", "5MC", "5MU", "7MG", "H2U", "M2G", "OMC", "OMG",
            "PSU", "YYG"]
        @test all(haskey(hets, r) for r in modified)
        @test sum(hets[r] for r in modified) == 323
        @test hets["HOH"] == 160 && hets["MG"] == 6 && hets["MN"] == 3

        standard = 374 + 300 + 415 + 240
        # the loader keeps the modified bases: 1,329 standard + 323 modified atoms
        @test n_atoms(load_molecule(_fix("1EHZ"))) == standard + 323 == 1652
        # also through the canonical .pdb written for the mmCIF fixture
        resolved = resolve_structure(LocalPathSource(_fix("1EHZ", "cif")))
        try
            @test n_atoms(load_molecule(resolved)) == standard + 323
        finally
            rm(resolved; force = true)
        end
    end

    @testset "3HDD: protein-DNA complex" begin
        atoms, hets = _composition(_fix("3HDD"))
        @test atoms["DA"] + atoms["DT"] + atoms["DG"] + atoms["DC"] == 855
        @test atoms["ARG"] == 187 && hets == Dict("HOH" => 53)
        @test n_atoms(load_molecule(_fix("3HDD"))) == 1811
    end

    @testset "hydrogens: nucleic acids only, no PROPKA" begin
        dir = mktempdir()
        try
            # 1BNA 486 heavy atoms, 272 hydrogens (11 per internal nucleotide)
            @test _hydrogenated(dir, "1BNA") == (486, 758, 272, false, :amber)
            @test _hydrogenated(dir, "1RNA") == (582, 880, 298, false, :amber)
            @test _hydrogenated(dir, "1SDR") == (1006, 1528, 522, false, :amber)
            # 1EHZ: 14 modified residues through their base, 149 of the 821 hydrogens;
            # pdb2pqr's 5TERM patch deletes the 5' phosphorus of residue 1: the pipeline
            # puts
            # it back and drops that residue's H5T, so 1652 heavy atoms and 820 hydrogens
            @test _hydrogenated(dir, "1EHZ") == (1652, 2472, 820, false, :amber)
            # the classification that sends them there
            for id in ("1BNA", "1RNA", "1SDR", "1EHZ")
                c = hydrogenation_choice(
                    component.(residue_names(_fix(id))), _fix(id))
                @test c == (content = :nucleic, ff = :amber, titration = :none, reason = "")
            end
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "hydrogens: protein-DNA complex and protein, PROPKA" begin
        dir = mktempdir()
        try
            # 3HDD at pH 7.4: protein and DNA; 1478 hydrogens (and the two OXT of pdb2pqr)
            @test _hydrogenated(dir, "3HDD") == (1811, 3291, 1478, true, :parse)
            # crambin, the protein route as it was before the nucleotide work
            @test _hydrogenated(dir, "1CRN") == (327, 642, 315, true, :parse)
            c = hydrogenation_choice(component.(residue_names(_fix("3HDD"))), _fix("3HDD"))
            @test c == (content = :mixed, ff = :parse, titration = :propka, reason = "")
            c = hydrogenation_choice(component.(residue_names(_fix("1CRN"))), _fix("1CRN"))
            @test c == (content = :protein, ff = :parse, titration = :propka, reason = "")
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "the force field is part of the cache key" begin
        dir = mktempdir()
        path = joinpath(dir, "nt-fix-keyff.pdb")
        cp(_fix("1BNA"), path)
        try
            @test NUCLEIC_FORCE_FIELD === :amber && DEFAULT_FORCE_FIELD === :parse
            pa = resolve_hydrogens(path, 7.4; ff = :amber, titration = NoTitration())
            pp = resolve_hydrogens(path, 7.4; ff = :parse, titration = NoTitration())
            @test pa != pp && endswith(pa, "_amber_notitration.pdb")
            @test endswith(pp, "_parse_notitration.pdb")
            @test isfile(pa) && isfile(pp)
            # both make the same atoms of a DNA (the --pdb-output is the same)
            @test n_atoms(load_molecule(pa)) == n_atoms(load_molecule(pp)) == 758
        finally
            purge_store("nt-fix-")
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "246D: an RNA/DNA chimera" begin
        dir = mktempdir()
        path = joinpath(dir, "nt-fix-246d.pdb")
        cp(_fix("246D"), path)
        try
            # nucleic acid only: AMBER, which builds it (the Na+ ions and waters are not
            # nucleotides)
            choice = hydrogenation_choice(component.(residue_names(path)), path)
            @test choice ==
                  (content = :nucleic, ff = :amber, titration = :none, reason = "")
            hp = resolve_hydrogens(path, 7.4; ff = choice.ff, titration = NoTitration())
            @test n_atoms(load_molecule(path)) == 330
            @test n_atoms(load_molecule(hp)) == 504
            # pdb2pqr with PARSE gives up on the total charge of the file (-12.68): a typed
            # Pdb2pqrError, which is why a nucleic acid goes through AMBER
            ok = try
                resolve_hydrogens(path, 7.4; ff = :parse, titration = NoTitration())
                true
            catch e
                e isa Pdb2pqrError || rethrow()
                false
            end
            @test_broken ok
        finally
            purge_store("nt-fix-")
            rm(dir; recursive = true, force = true)
        end
    end
end

end # module
