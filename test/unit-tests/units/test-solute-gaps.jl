# SPDX-License-Identifier: LGPL-3.0-or-later

# The 3D-RISM queue of solutes that have no literature volume (`dev/data/pmv-queue.tsv`,
# ranked in `notes/solute-gaps.md`), which
# `bysl extract pmv batch dev/data/pmv-queue.tsv [--tier T]` runs (batch skips finished
# ids, takes tiers and `--nice`). The queue is data `batch` reads, so it has to stay
# self-consistent: the `id smiles charge nconf tier` columns batch needs, unique ids, a
# SMILES whose formal charge is the stated charge, a named anchor, and the tier order the
# owner asked for (the BTP species and the Tris anchors first). Nothing here runs RISM.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

const QUEUE_ROOT = normpath(joinpath(pathof(BAYSOL), "..", ".."))
const QUEUE_FILE = joinpath(QUEUE_ROOT, "dev", "data", "pmv-queue.tsv")
const QUEUE_COLUMNS =
    ["id", "smiles", "charge", "nconf", "tier", "name", "anchor", "neededBy"]
const QUEUE_FIRST = ["BTP0", "BTP1", "BTP2", "TRIS0", "TRIS1"]

"""
    queueRows() -> Vector{Dict{String,String}}

The rows of `queue.tsv` keyed by the header.

# Returns
One dictionary per data line.

# Exceptions
`SystemError` if the file is missing.
"""
function queueRows()
    lines = filter(!isempty, readlines(QUEUE_FILE))
    header = split(lines[1], '\t')
    return [Dict(zip(header, split(l, '\t'))) for l in lines[2:end]]
end

"""
    formalCharge(smiles) -> Int

The sum of the charges written on the bracket atoms of a SMILES string (`[NH3+]` is 1,
`[O-]` is -1, `[Cu+2]` is 2).

# Returns
The net formal charge.

# Exceptions
None.
"""
function formalCharge(smiles::AbstractString)
    total = 0
    for m in eachmatch(r"\[[^\]]*?([+-])(\d*)\]", smiles)
        n = isempty(m[2]) ? 1 : parse(Int, m[2])
        total += m[1] == "+" ? n : -n
    end
    return total
end

@testset "RISM queue" begin
    rows = queueRows()
    @test !isempty(rows)
    @test all(r -> sort(collect(keys(r))) == sort(QUEUE_COLUMNS), rows)
    ids = [r["id"] for r in rows]
    @test allunique(ids)
    @test ids[1:length(QUEUE_FIRST)] == QUEUE_FIRST

    @testset "$(r["id"])" for r in rows
        @test formalCharge(r["smiles"]) == parse(Int, r["charge"])
        @test parse(Int, r["nconf"]) >= 1
        @test parse(Int, r["tier"]) in 1:3
        @test !isempty(r["anchor"])
        @test !isempty(r["name"])
        @test !isempty(r["neededBy"])
        @test !occursin(r"\s", r["smiles"])
    end

    # Tiers never go back: tier 1 (BTP, Tris) before 2 (template buffers) before 3.
    tiers = [parse(Int, r["tier"]) for r in rows]
    @test issorted(tiers)
    @test all(==(1), tiers[1:length(QUEUE_FIRST)])
end

@testset "queue.tsv is what `bysl extract pmv batch` reads" begin
    rows = queueRows()
    # batch reads id, smiles, charge, nconf (integers) and the optional tier by header name
    @test QUEUE_COLUMNS[1:5] == ["id", "smiles", "charge", "nconf", "tier"]
    @test all(r -> all(k -> !isempty(r[k]), QUEUE_COLUMNS[1:5]), rows)
    @test all(r -> tryparse(Int, r["charge"]) !== nothing, rows)
    @test all(r -> tryparse(Int, r["nconf"]) !== nothing, rows)
    # `--tier 1 --tier 2` style filters compare the tier column as text
    @test Set(r["tier"] for r in rows) <= Set(["1", "2", "3"])
    @test !ispath(joinpath(QUEUE_ROOT, "dev", "pmv-rism"))
end
