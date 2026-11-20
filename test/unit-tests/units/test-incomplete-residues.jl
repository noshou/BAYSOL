# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/hydrogenator/incomplete.jl, the blank-line filter of pdb2pqr.jl (SASDFZ3:
# pdb2pqr stops reading at a blank header line) and the pdb2pqr command of pdb2pqr.jl:
# residues
# without a backbone (the C-alpha-only stretches of SASDC57, the split-off phosphate DC 31
# of SASDMG6) stay out of the pdb2pqr run and are put back as deposited, without hydrogens;
# the command that starts pdb2pqr lifts its 10 % repair limit (SASDN75, whose truncated side
# chains made pdb2pqr stop on a gap). Text work only, no pdb2pqr run (SASDC57, SASDN75 and
# SASDMG6 were hydrogenated end to end when this was written).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

module NtTest_incomplete_residues

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.Hydrogenator:
    holdBackIncomplete, restoreHeldBack!, dropBlankLines, _pdb2pqrCommand,
    PDB2PQR_NO_REPAIR_LIMIT

# a fixed-column ATOM record, atoms placed along x
function rec(serial, atom, res, chain, num, x)
    a = length(atom) >= 4 ? atom : " " * rpad(atom, 3)
    return @sprintf(
        "ATOM  %5d %s %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        serial, a, res, chain, num, x, 0.0, 0.0, 1.0, 10.0, string(first(atom)),
    )
end
residue(res, chain, num, atoms, s0) =
    [rec(s0 + i - 1, a, res, chain, num, 3.0i + 10num) for (i, a) in enumerate(atoms)]

@testset "backbone-less residues" begin
    dir = mktempdir()
    try
        full = ["N", "CA", "C", "O", "CB"]
        lines = vcat(
            residue("GLY", 'A', 1, ["CA"], 1),          # C-alpha only
            residue("ALA", 'A', 2, full, 2),
            residue("DC", 'B', 1, ["P", "OP1", "OP2", "O5'"], 10),   # a split-off phosphate
            residue("DC", 'B', 2,
                ["P", "O5'", "C5'", "C4'", "O4'", "C3'", "C2'", "C1'",
                    "N1", "C2", "N3", "C4", "C5", "C6"], 20),
        )
        inPath = joinpath(dir, "in.pdb")
        write(inPath, join(lines, "\n") * "\n")
        outPath = joinpath(dir, "out.pdb")
        held = holdBackIncomplete(inPath, outPath)
        @test held.held == 2
        @test length(held.lines) == 5
        kept = readlines(outPath)
        @test length(kept) == 5 + 14
        @test all(l -> !(l[18:20] == "GLY"), kept)
        @test !any(l -> l[22] == 'B' && strip(l[23:26]) == "1", kept)

        # put back after the last atom record, verbatim
        pqr = joinpath(dir, "res.pdb")
        write(pqr, join(vcat(kept, ["END"]), "\n") * "\n")
        @test restoreHeldBack!(pqr, held) == 2
        back = readlines(pqr)
        @test back[end] == "END"
        @test back[(end-5):(end-1)] == held.lines
        @test count(startswith("ATOM"), back) == length(lines)

        # a complete structure is left alone, nothing is written
        whole = joinpath(dir, "whole.pdb")
        write(whole, join(lines[2:6], "\n") * "\n")
        none = holdBackIncomplete(whole, joinpath(dir, "none.pdb"))
        @test none.held == 0 && isempty(none.lines)
        @test !isfile(joinpath(dir, "none.pdb"))
        @test restoreHeldBack!(whole, none) == 0
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "pdb2pqr command lifts the repair limit" begin
    @test occursin("REPAIR_LIMIT", PDB2PQR_NO_REPAIR_LIMIT)
    dir = mktempdir()
    try
        entry = joinpath(dir, "pdb2pqr")
        write(entry, "")
        # no Python beside the entry script: the script itself
        @test _pdb2pqrCommand(entry) == `$entry`
        py = joinpath(dir, "python")
        write(py, "")
        @test _pdb2pqrCommand(entry) == `$py -c $PDB2PQR_NO_REPAIR_LIMIT`
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "blank lines are dropped (pdb2pqr stops reading at the first)" begin
    dir = mktempdir()
    try
        atoms = residue("ALA", 'A', 1, ["N", "CA", "C", "O", "CB"], 1)
        inPath = joinpath(dir, "in.pdb")
        text = ["REMARK a", "", "REMARK b", "  ", atoms..., "END"]
        write(inPath, join(text, "\n") * "\n")
        outPath = joinpath(dir, "out.pdb")
        @test dropBlankLines(inPath, outPath)
        @test readlines(outPath) == ["REMARK a", "REMARK b", atoms..., "END"]

        # no blank line: nothing is written
        clean = joinpath(dir, "clean.pdb")
        write(clean, join(atoms, "\n") * "\n")
        @test !dropBlankLines(clean, joinpath(dir, "none.pdb"))
        @test !isfile(joinpath(dir, "none.pdb"))
    finally
        rm(dir; recursive = true, force = true)
    end
end

end # module
