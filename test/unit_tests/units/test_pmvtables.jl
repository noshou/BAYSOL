# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the three hand-maintained solute tables in
# src/BulkElectronDensity/NonBiological/ against each other: `nonbio_lookup.json`
# (alias -> target name; mostly preferred IUPAC names, a few grade or mixture names),
# `nonbiological.json` (the table `ϕ°` reads: lowercase IUPAC name -> [electrons, V0,
# uncertainty]) and `nonbiological.tsv` (every literature row, the provenance the JSON
# is chosen from). The JSON value must be the selection-rule winner of the README:
# rank rows by basis (measured < derived < predicted < any other), drop `rejected`,
# take the lowest stated uncertainty (blank ranks last); ties may pick any tied row.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

const PMV_TABLES = BAYSOL.BulkElectronDensity
const NB_DIR =
    normpath(joinpath(pathof(BAYSOL), "..", "BulkElectronDensity", "NonBiological"))

const BASIS_RANK = Dict("measured" => 0, "derived" => 1, "predicted" => 2)
const COLUMNS = ["common_name", "iupac_name", "formula", "charge", "v0_cm3_per_mol",
    "uncertainty_cm3_per_mol", "basis", "doi"]
const KNOWN_BASES =
    Set(["measured", "derived", "predicted", "estimated", "obigt-unverified",
        "other-T", "unverified-T", "rejected"])

struct Row
    name::String
    v0::Float64
    unc::Float64          # Inf when blank
    basis::String
end

function read_rows()
    lines = readlines(joinpath(NB_DIR, "nonbiological.tsv"))
    @assert split(lines[1], '\t') == COLUMNS
    rows = Row[]
    for (i, l) in enumerate(lines[2:end])
        f = split(l, '\t'; keepempty = true)
        length(f) == 8 || error("nonbiological.tsv line $(i + 1): $(length(f)) columns")
        push!(
            rows,
            Row(String(f[2]), parse(Float64, f[5]),
                isempty(f[6]) ? Inf : parse(Float64, f[6]), String(f[7])),
        )
    end
    return rows
end

rank(r::Row) = (get(BASIS_RANK, r.basis, 3), r.unc)

@testset "PMV tables" begin
    rows = read_rows()
    lookup = PMV_TABLES.NONBIO_LOOKUP
    solutes = PMV_TABLES._solutes
    targets = Set(values(lookup))
    by_key = Dict{String,Vector{Row}}()
    for r in rows
        push!(get!(by_key, lowercase(r.name), Row[]), r)
    end

    @testset "every row is well formed" begin
        @test all(r -> r.basis in KNOWN_BASES, rows)
        @test all(r -> isfinite(r.v0), rows)
        @test all(r -> r.unc ≥ 0, rows)
    end

    @testset "every row's name is a lookup target" begin
        @test isempty(unique(r.name for r in rows if !(r.name in targets)))
    end

    @testset "aliases are lowercase (queries are lowercased, so others never match)" begin
        @test all(a -> a == lowercase(a), keys(lookup))
    end

    @testset "JSON keys are lowercase and every JSON value is a selection-rule winner" begin
        bad = String[]
        for (k, (_, v, u)) in solutes
            k == lowercase(k) || push!(bad, "key not lowercase: $k")
            live = [r for r in get(by_key, k, Row[]) if r.basis != "rejected"]
            if isempty(live)
                push!(bad, "no non-rejected row: $k")
                continue
            end
            best = minimum(rank, live)
            tied = [r for r in live if rank(r) == best]
            ok = any(r -> abs(r.v0 - v) < 1e-9, tied)
            ok || push!(bad, "$k: JSON $v is not a winner (rule gives $(first(tied).v0))")
        end
        @test isempty(bad)
    end

    @testset "a species with a non-rejected row has a JSON key" begin
        missing_key = [
            k for (k, rs) in by_key if any(r -> r.basis != "rejected", rs) &&
                !haskey(solutes, k)
        ]
        @test isempty(missing_key)
    end
end
