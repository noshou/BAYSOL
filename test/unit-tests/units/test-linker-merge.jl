# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the chain bookkeeping of the multi-run hydrogenation in
# src/hydrogenator/pdb2pqr.jl: a chain id reused by several chains (SASDBZ2: ten linkers
# with a blank id) is given an id of its own by `sanitizedCopy`, the pdb2pqr outputs carry
# that id, and `_mergeChainsByText` keeps only the chains it is told to. The merge must be
# told the ids of the sanitized copy; the ids of the original file drop the relabelled
# chains (the bug that lost nine of the ten linkers of SASDBZ2). Pure text work: pdb2pqr
# and PROPKA never run.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers of this file cannot
# clash with those of another file when the aggregator includes them all into Main.
module NtTest_linker_merge

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.Hydrogenator: _textChainIds, _mergeChainsByText
using BAYSOL.MolecularStructure: sanitizedCopy

# A fixed-column ATOM record of a CA atom (coordinates do not matter)
function caLine(serial, res, chain, num)
    return @sprintf("ATOM  %5d  CA  %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f           C",
        serial, res, chain, num, 1.0, 2.0, 3.0, 1.0, 20.0)
end

# Atoms per chain id of the ATOM records of `path`, a blank id as ""
function atomsPerChain(path)
    counts = Dict{String,Int}()
    for line in eachline(path)
        startswith(line, "ATOM") || continue
        c = String(strip(SubString(line, 22, 22)))
        counts[c] = get(counts, c, 0) + 1
    end
    return counts
end

# A blank-chain linker of 4 glycines, protein A, a linker, protein B, a linker
function writeTwoChains(path)
    open(path, "w") do io
        serial = 0
        for (chain, n) in ((' ', 4), ('A', 3), (' ', 4), ('B', 3), (' ', 4))
            for i in 1:n
                println(io, caLine(serial += 1, "GLY", chain, i))
            end
            println(io, "TER")
        end
        println(io, "END")
    end
end

@testset "linker chains survive the merge" begin
    dir = mktempdir()
    try
        orig = joinpath(dir, "two.pdb")
        san = joinpath(dir, "san.pdb")
        writeTwoChains(orig)
        @test atomsPerChain(orig) == Dict("" => 12, "A" => 3, "B" => 3)
        @test _textChainIds(orig) == ["", "A", "B"]

        # a reused blank id: the sanitized copy gives the later linkers ids of their own
        @test sanitizedCopy(orig, san; waters = true) !== nothing
        ids = _textChainIds(san)
        @test length(ids) == 5
        @test Set(ids) ⊇ Set(["", "A", "B"])
        @test sum(values(atomsPerChain(san))) == 18

        # the ids of the original file lose the relabelled linkers ...
        lost = joinpath(dir, "lost.pdb")
        _mergeChainsByText([(san, _textChainIds(orig))], lost)
        @test sum(values(atomsPerChain(lost))) < 18

        # ... the ids of the sanitized copy keep every atom, as the fix passes them
        kept = joinpath(dir, "kept.pdb")
        _mergeChainsByText([(san, ids)], kept)
        @test atomsPerChain(kept) == atomsPerChain(san)
        @test last(readlines(kept)) == "END"
    finally
        rm(dir; recursive = true, force = true)
    end
end

end # module
