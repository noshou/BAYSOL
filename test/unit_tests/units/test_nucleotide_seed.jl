# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises how the nucleotide stages are wired into the timing log of `seed_model`
# (src/Pipeline/SeedModel.jl) and the timing table (`Pipeline._timing_table`): the names and
# notes of the stages, their order, which ones appear for which content. Only the structure
# of the log is asserted, never a time. Small fragments of the fixtures (a few residues of
# 1EHZ, 1CRN, 1BNA) are seeded with synthetic data, so a seed is quick; the hydrogenation
# is real (pdb2pqr, PROPKA for the protein fragments: the CondaPkg tools are needed, like
# test_pdb2pqr.jl, no network). The residue names that are not in the bundled table are
# served from a file in the component cache and by a fake download hook, so the
# `components` note counts one of each source. Every file here has its own stem
# (`nt-seed-*`); its cache files are removed at the end.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_nucleotide_seed

using Test
using BAYSOL

using Random
using BAYSOL.BulkElectronDensity: NonBiological, Solute
using BAYSOL.MolecularStructure: LocalPathSource, _store_dir, _component_path,
    _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _COMPONENT_TABLE, AMBER_NUCLEIC_NAMES
using BAYSOL.Hydrogenator: _hydrogens_path, _pka_path, Propka, NoTitration
using BAYSOL.Runtime: force
using BAYSOL.Runtime: tick

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures")
const _COMPONENT_FIXTURES = joinpath(_FIXTURES, "components")

function _residues(id::AbstractString, chain::Char, nums)
    out = String[]
    for l in eachline(joinpath(_FIXTURES, "molecules", "$id-TEST.pdb"))
        (startswith(l, "ATOM") || startswith(l, "HETATM")) || continue
        l[22] == chain && parse(Int, strip(l[23:26])) in nums && push!(out, l)
    end
    return out
end
rename(lines, name) = [l[1:17] * lpad(name, 3) * l[21:end] for l in lines]
residue(lines, num) = [l for l in lines if parse(Int, strip(l[23:26])) == num]

function _free_ids(n)
    ids = String[]
    table = force(_COMPONENT_TABLE)
    alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for a in alphabet, b in alphabet
        id = "Q" * a * b
        (haskey(table, id) || haskey(AMBER_NUCLEIC_NAMES, id)) && continue
        push!(ids, id)
        length(ids) == n && return ids
    end
end

_component_text(fixture, id) =
    replace(read(joinpath(_COMPONENT_FIXTURES, fixture * ".cif"), String),
        Regex("\\b" * fixture * "\\b") => id)

# synthetic data on a small grid: a decaying curve with 5 % errors
function _data()
    q = collect(range(0.02, 0.3; length = 40))
    I = 10 .* exp.(-(q .* 8) .^ 2 ./ 3) .+ 0.05
    return q, I, 0.05 .* I
end

# seed a structure file (copied under its own stem) and return the seed's stage log
function seeded(dir, stem, lines; pH = 7.0, kwargs...)
    path = joinpath(dir, stem * ".pdb")
    write(path, join(lines, "\n") * "\nEND\n")
    q, I, σ = _data()
    Random.seed!(1)
    seed = BAYSOL.seed_model(
        LocalPathSource(path), 9000.0, q, I, σ, pH, 0.1,
        Solute[NonBiological(0.15, 0.001, "sodium chloride")]; kwargs...,
    )
    return seed.timing, path
end

names_of(log) = [s.name for s in log.stages]
stage(log, name) = only(s for s in log.stages if s.name == name)
# the stages of the nucleotide wiring, in the order they were recorded
const _WIRING =
    ("resolve_structure", "components", "structure checks", "classify", "propka", "pdb2pqr",
        "pdb2pqr (nucleic, none)", "pdb2pqr (mixed, propka)",
        "modified nucleotide hydrogens", "heavy atoms", "load_molecule")
wiring(log) = [n for n in names_of(log) if n in _WIRING]

@testset "timing log of the nucleotide stages" begin
    dir = mktempdir()
    saved_hook = _COMPONENT_DOWNLOAD[]
    ids = _free_ids(2)
    hook_calls = Ref(0)
    _COMPONENT_DOWNLOAD[] = function (url, dest)
        hook_calls[] += 1
        id = splitext(basename(url))[1]
        write(dest, _component_text("5MC", id))
    end
    empty!(_COMPONENT_MEMO)
    cleanup = String[]
    seeds = Dict{String,Any}()

    try
        # ---- nucleic acid with two modified residues unknown to the table -------------
        # A PSU 5MC U (residues 38-41 of 1EHZ); PSU is named ids[1], found in the cache,
        # and 5MC ids[2], downloaded
        frag = _residues("1EHZ", 'A', 38:41)
        mod = [residue(frag, 38); rename(residue(frag, 39), ids[1]);
            rename(residue(frag, 40), ids[2]); residue(frag, 41)]
        mkpath(dirname(_component_path(ids[1])))
        write(_component_path(ids[1]), _component_text("PSU", ids[1]))
        push!(cleanup, _component_path(ids[1]), _component_path(ids[2]))
        log, path = seeded(dir, "nt-seed-mod", mod)
        seeds["mod"] = log

        @testset "nucleic acid with modified nucleotides" begin
            @test wiring(log) == ["resolve_structure", "components", "structure checks",
                "classify", "pdb2pqr (nucleic, none)", "modified nucleotide hydrogens",
                "heavy atoms", "load_molecule"]
            @test !("propka" in names_of(log))                     # PROPKA never runs
            @test hook_calls[] == 1                                # one download
            @test isfile(_component_path(ids[2]))                  # into the cache
            @test stage(log, "components").note ==
                  "[4 residue names: 2 builtin, 1 cache, 1 download]"
            @test stage(log, "classify").note == "[nucleic: AMBER, titration none]"
            @test stage(log, "structure checks").note ==
                  "[0 chains relabelled, 0 duplicate atoms dropped, 0 dummy-like findings]"
            @test stage(log, "heavy atoms").note ==
                  "[83 in, 83 out; 1 restored, 0 added by pdb2pqr]"
            @test stage(log, "pdb2pqr (nucleic, none)").note == "[cache miss]"
            # PSU (10 hydrogens through U) and 5MC (11 through C); the formulas of the
            # free components (the cached PSU and 5MC files) carry 13 and 16
            @test stage(log, "modified nucleotide hydrogens").note ==
                  "[2 residues: 2 hydrogenated through their base, 0 without a base; " *
                  "21 hydrogens placed, 29 in the free components' formulas]"
            # all of them are static-build stages at depth 1, recorded before SASA
            for n in _WIRING
                n in names_of(log) || continue
                s = stage(log, n)
                @test s.group === :static && s.depth == 1
            end
            order = names_of(log)
            @test findfirst(==("load_molecule"), order) < findfirst(==("SASA"), order)
            @test findfirst(==("modified nucleotide hydrogens"), order) <
                  findfirst(==("load_molecule"), order)
        end

        # ---- the same again: everything is cached ------------------------------------
        @testset "a second seed of the same structure" begin
            log2, _ = seeded(dir, "nt-seed-mod", mod)
            @test hook_calls[] == 1                                # no new download
            # the downloaded component is in the cache now (the memo says so too)
            @test stage(log2, "components").note ==
                  "[4 residue names: 2 builtin, 2 cache, 0 download]"
            @test stage(log2, "pdb2pqr (nucleic, none)").note == "[cache hit]"
            # the balance of the run is read back from the cache
            @test stage(log2, "heavy atoms").note ==
                  "[83 in, 83 out; 1 restored, 0 added by pdb2pqr]"
        end

        # ---- standard nucleotides only: no modified stage -----------------------------
        std = _residues("1EHZ", 'A', 41:45)       # U G G A G
        log, path = seeded(dir, "nt-seed-std", std)
        seeds["std"] = log
        @testset "nucleic acid without modified nucleotides" begin
            @test wiring(log) == ["resolve_structure", "components", "structure checks",
                "classify", "pdb2pqr (nucleic, none)", "heavy atoms", "load_molecule"]
            @test !("modified nucleotide hydrogens" in names_of(log))
            @test stage(log, "components").note ==
                  "[3 residue names: 3 builtin, 0 cache, 0 download]"
            @test stage(log, "classify").note == "[nucleic: AMBER, titration none]"
            @test stage(log, "structure checks").note ==
                  "[0 chains relabelled, 0 duplicate atoms dropped, 0 dummy-like findings]"
            @test stage(log, "heavy atoms").note ==
                  "[111 in, 111 out; 1 restored, 0 added by pdb2pqr]"
        end

        @testset "without hydrogens: the residues are still looked up" begin
            log, _ = seeded(dir, "nt-seed-std", std; add_hydrogens = false)
            @test wiring(log) ==
                  ["resolve_structure", "components", "structure checks", "load_molecule"]
            @test stage(log, "components").note ==
                  "[3 residue names: 3 builtin, 0 cache, 0 download]"
        end

        # ---- protein only: the stage names are those of the protein route -------------
        prot = _residues("1CRN", 'A', 1:6)
        log, path = seeded(dir, "nt-seed-prot", prot)
        seeds["prot"] = log
        @testset "protein only" begin
            @test wiring(log) == ["resolve_structure", "components", "structure checks",
                "classify", "propka", "pdb2pqr", "heavy atoms", "load_molecule"]
            @test stage(log, "classify").note == "[protein: PARSE, titration propka]"
            @test stage(log, "structure checks").note ==
                  "[0 chains relabelled, 0 duplicate atoms dropped, 0 dummy-like findings]"
            @test stage(log, "heavy atoms").note ==
                  "[39 in, 40 out; 0 restored, 1 added by pdb2pqr]"
            @test stage(log, "propka").note == "[cache miss]"
            @test stage(log, "pdb2pqr").note == "[cache miss]"
            @test occursin(r"^\[\d+ residue names: \d+ builtin, 0 cache, 0 download\]$",
                stage(log, "components").note)
        end

        # ---- mixed protein and DNA ---------------------------------------------------
        mixed = [prot; [l[1:21] * "B" * l[23:end] for l in _residues("1BNA", 'A', 1:4)]]
        log, path = seeded(dir, "nt-seed-mixed", mixed)
        seeds["mixed"] = log
        @testset "protein and DNA" begin
            @test wiring(log) == ["resolve_structure", "components", "structure checks",
                "classify", "propka", "pdb2pqr (mixed, propka)", "heavy atoms",
                "load_molecule"]
            @test stage(log, "classify").note == "[mixed: PARSE, titration propka]"
            @test stage(log, "structure checks").note ==
                  "[0 chains relabelled, 0 duplicate atoms dropped, 0 dummy-like findings]"
            @test stage(log, "heavy atoms").note ==
                  "[118 in, 119 out; 0 restored, 1 added by pdb2pqr]"
            @test stage(log, "propka").note == "[cache miss]"
            @test !("modified nucleotide hydrogens" in names_of(log))
        end

        # ---- the report prints the stages and notes ----------------------------------
        @testset "the timing table lists the stages and their notes" begin
            # a row of the table is a stage's name, as recorded, and its note
            rows_of(log) = [
                "  "^r.depth * r.name * "  " * r.note for
                r in BAYSOL.Pipeline._timing_table(log, tick()).rows
            ]
            for (key, notes) in (
                "mod" => ["resolve_structure", "components", "classify",
                    "pdb2pqr (nucleic, none)", "modified nucleotide hydrogens",
                    "load_molecule",
                    "[4 residue names: 2 builtin, 1 cache, 1 download]",
                    "[nucleic: AMBER, titration none]",
                    "hydrogenated through their base"],
                "std" => ["components", "classify", "pdb2pqr (nucleic, none)"],
                "prot" =>
                    ["components", "classify", "propka", "pdb2pqr", "[protein: PARSE"],
                "mixed" => ["pdb2pqr (mixed, propka)", "[mixed: PARSE, titration propka]"],
            )
                lines = rows_of(seeds[key])
                flat = join(lines, "\n")
                for n in notes
                    @test occursin(n, flat)
                end
                # the stages are in the order they were recorded
                at(n) = findfirst(l -> occursin(n, l), lines)
                present = [
                    n for n in _WIRING if n in names_of(seeds[key]) &&
                        !(n == "pdb2pqr" && key != "prot")
                ]
                pos = [at(n) for n in present]
                @test all(!isnothing, pos) && issorted(pos)
            end
            # a modified-nucleotide stage is absent where there are none
            @test !occursin("modified nucleotide hydrogens", join(rows_of(seeds["std"])))
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        foreach(p -> rm(p; force = true), cleanup)
        for f in readdir(_store_dir())
            startswith(f, "nt-seed-") && rm(joinpath(_store_dir(), f); force = true)
        end
        rm(dir; recursive = true, force = true)
    end
end

end # module
