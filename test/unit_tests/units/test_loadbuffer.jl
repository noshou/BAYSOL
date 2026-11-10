# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/Buffer.jl: `load_buffer` reads the buffer.json of a project (mM as
# typed) into the `Vector{Solute}` of `seed_model` (mol/L), against the fixture shared with
# the terminal interface (test/fixtures/buffer/buffer.json), the shape errors, the missing
# file, the empty buffer, the pH and sigma-pH (`load_buffer_ph`); and `seed_keywords`
# (src/Pipeline/Settings.jl).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Logging
using BAYSOL.Pipeline:
    load_buffer, load_buffer_ph, InvalidBufferError, seed_keywords, load_settings,
    seed_model, BUFFER_PH_MIN, BUFFER_PH_MAX, BUFFER_SIGMA_PH_MIN, BUFFER_SIGMA_PH_MAX,
    _read_json
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer, Protein, DNA, RNA,
    CustomNonBio, CustomPolymer, ρₑ, _ρₑ_i
using BAYSOL.Inference: κ_δρ₁₂, κ_δρ₃, PMV_FALLBACK_UNCERT
using BAYSOL.Scattering: SHELL_THICKNESS
using BAYSOL.Geometry: PROBE_RADIUS

const FIXTURE = joinpath(@__DIR__, "..", "..", "fixtures", "buffer", "buffer.json")

"`load_buffer` on a file holding `text`: the solutes or the error, warnings silenced."
function try_buffer(text)
    mktempdir() do dir
        path = joinpath(dir, "buffer.json")
        write(path, text)
        with_logger(NullLogger()) do
            try
                load_buffer(path)
            catch e
                e isa InvalidBufferError ? e : rethrow()
            end
        end
    end
end

"A buffer file with the one row `row` (JSON text)."
one_row(row) = "{\"solutes\": [$row]}"

# A JSON row from its keys (`k => json text of the value`, in order).
row(pairs...) = "{" * join(("\"$k\": $v" for (k, v) in pairs), ", ") * "}"
const NB = row("kind" => "\"nonbiological\"", "arg" => "\"sodium chloride\"",
    "mM" => "200.0", "sigma-mM" => "10.0")


problems(text) = (r = try_buffer(text); r isa InvalidBufferError ? r.problems : nothing)
function has(text, needle)
    p = problems(text)
    return p !== nothing && any(occursin(needle, x) for x in p)
end

@testset "load_buffer: the shared fixture" begin
    s = load_buffer(FIXTURE)
    @test s isa Vector{Solute}
    @test length(s) == 11
    @test s[1] == NonBiological(0.2, 0.01, "sodium chloride")
    @test s[2] == Polymer(0.05 / 1000, 0.003 / 1000, "PEG 3350")
    @test s[3] == Polymer(0.1 / 1000, 0.01 / 1000, "PEG n=22")
    @test s[4] == Polymer(0.01 / 1000, 0.001 / 1000, "Pluronic nEO=100 nPO=65")
    @test s[5] == DNA(0.01 / 1000, 0.001 / 1000, "ACGTTGCA")
    @test s[6] == RNA(0.02 / 1000, 0.002 / 1000, "ACGUUGCA")
    @test s[7] == Protein(0.02 / 1000, 0.002 / 1000, "MKTAYIAKQR")
    @test s[8] == CustomNonBio(5.0 / 1000, 0.1 / 1000, "N-acetylcysteine ethyl ester",
        102, 118.4, 4.0)
    @test s[9] == CustomNonBio(10.0 / 1000, 0.2 / 1000, "ammonium nitrate", 32, 46.7,
        nothing)
    @test s[8].σ_ϕ° === 4.0
    @test s[9].σ_ϕ° === nothing

    one = s[10]
    @test one isa CustomPolymer
    @test one.arg == "chain-1"
    @test one.molarity == 0.01 / 1000 && one.molarity_uncertainty == 0.0001 / 1000
    @test one.n == [22.0] && one.Z_unit == [24] && one.slope == [36.73]
    @test one.σ_unit == [nothing] && one.σ_unit isa Vector{Union{Nothing,Float64}}
    @test one.Z_ends == 10 && one.v0 == 19.24 && one.σ_ends === nothing

    four = s[11]
    @test four.arg == "chain-4"
    @test four.n == [3.0, 4.0, 5.0, 6.0]
    @test four.Z_unit == [10, 20, 30, 40]
    @test four.slope == [1.0, 2.0, 3.0, 4.0]
    @test four.σ_unit == [nothing, 0.1, nothing, 0.2]
    @test four.Z_ends == 5 && four.v0 == 7.0 && four.σ_ends == 0.5

    @testset "the numbers through ρₑ's helper" begin
        Z, v, _ = _ρₑ_i(four, 7.4, 0.05, 3.5)
        @test Z == 505.0 && v == 57.0
        Z1, v1, _ = _ρₑ_i(one, 7.4, 0.05, 3.5)
        @test Z1 == 10 + 24 * 22 && v1 ≈ 19.24 + 36.73 * 22
    end

    @testset "round trip: the same ρₑ as the CustomPolymer built by hand" begin
        by_hand =
            CustomPolymer(0.01 / 1000, 0.0001 / 1000, "chain-4", [3.0, 4.0, 5.0, 6.0],
                [10, 20, 30, 40], [1.0, 2.0, 3.0, 4.0],
                Union{Nothing,Float64}[nothing, 0.1, nothing, 0.2], 5, 7.0, 0.5)
        @test ρₑ(7.4, 0.05, Solute[four]) == ρₑ(7.4, 0.05, Solute[by_hand])
        @test ρₑ(7.4, 0.05, s) isa Tuple{Float64,Float64}
    end
end

@testset "load_buffer: missing file and empty buffer" begin
    mktempdir() do dir
        path = joinpath(dir, "nope.json")
        e = with_logger(NullLogger()) do
            try
                load_buffer(path)
            catch e
                e
            end
        end
        @test e isa InvalidBufferError
        @test occursin("does not exist", e.problems[1])
        @test_logs (:warn, r"invalid buffer") (
            @test_throws InvalidBufferError load_buffer(path)
        )
        write(path, "{\"solutes\": []}")
        @test_logs (:warn, "the buffer has no solutes: pure water") (
            @test load_buffer(path) == Solute[]
        )
    end
    @test try_buffer("{\"solutes\": []}") == Solute[]
end

@testset "load_buffer: invalid files" begin
    dna(; kind = "\"dna\"", arg = "\"AC\"", mM = "1", sm = "0") =
        row("kind" => kind, "arg" => arg, "mM" => mM, "sigma-mM" => sm)
    @test has("not json {", "cannot be read")
    @test has("[1, 2]", "`solutes`")
    @test has("{\"other\": []}", "`solutes`")
    @test has("{\"solutes\": 3}", "`solutes`")
    @test has(one_row("3"), "solute 1: is not an object")
    @test has(one_row(dna(kind = "\"metal\"")), "unknown `kind`")
    @test has(one_row(row("arg" => "\"x\"", "mM" => "1", "sigma-mM" => "0")),
        "unknown `kind`")
    @test has(one_row(row("kind" => "\"dna\"", "mM" => "1", "sigma-mM" => "0")),
        "`arg` is missing")
    @test has(one_row(dna(arg = "5")), "`arg` is 5")
    @test has(one_row(dna(arg = "\"\"")), "`arg`")
    @test has(one_row(row("kind" => "\"dna\"", "arg" => "\"AC\"", "sigma-mM" => "0")),
        "`mM` is missing")
    @test has(one_row(dna(mM = "\"1\"")), "`mM`")
    @test has(one_row(dna(mM = "0")), "above 0")
    @test has(one_row(dna(mM = "-1")), "above 0")
    @test has(one_row(row("kind" => "\"dna\"", "arg" => "\"AC\"", "mM" => "1")),
        "`sigma-mM` is missing")
    @test has(one_row(dna(sm = "null")), "`sigma-mM`")
    @test has(one_row(dna(sm = "-0.1")), "negative")
    # the row number is 1-based and the later rows are still checked
    p = problems("{\"solutes\": [$NB, $(row("kind" => "\"dna\"", "mM" => "1",
        "sigma-mM" => "0")), 7]}")
    @test length(p) == 2 && occursin("solute 2", p[1]) && occursin("solute 3", p[2])
    # integers are numbers
    @test try_buffer(one_row(dna())) == Solute[DNA(0.001, 0.0, "AC")]

    cn(; custom = "\"x\"", z = "5", pmv = "10.0", sp = "null") =
        row("kind" => "\"custom-nonbio\"", "custom" => custom, "z" => z, "pmv" => pmv,
            "sigma-pmv" => sp, "mM" => "1", "sigma-mM" => "0")
    @test try_buffer(one_row(cn())) ==
          Solute[CustomNonBio(0.001, 0.0, "x", 5, 10.0, nothing)]
    @test has(one_row(cn(custom = "\"\"")), "`custom`")
    @test has(one_row(replace(cn(), "\"z\": 5, " => "")), "`z` is missing")
    @test has(one_row(cn(z = "5.5")), "`z` is 5.5")
    @test has(one_row(cn(pmv = "null")), "`pmv`")
    @test has(one_row(replace(cn(), "\"sigma-pmv\": null, " => "")),
        "`sigma-pmv` is missing")
    @test has(one_row(cn(sp = "\"a\"")), "`sigma-pmv`")

    u(z = 24) =
        "{\"label\": \"A\", \"formula\": \"C\", \"z\": $z, \"slope\": 1.0, " *
        "\"sigma\": null}"
    cp(; units = "[$(u())]", counts = "[22.0]", ze = "10", pe = "1.0", se = "null") =
        row("kind" => "\"custom-polymer\"", "custom" => "\"c\"", "units" => units,
            "z-ends" => ze, "pmv-ends" => pe, "sigma-ends" => se, "counts" => counts,
            "mM" => "1", "sigma-mM" => "0")
    @test try_buffer(one_row(cp())) isa Vector{Solute}
    @test has(one_row(cp(units = "[]", counts = "[]")), "1 to 4")
    @test has(
        one_row(
            cp(units = "[$(u()), $(u()), $(u()), $(u()), $(u())]",
                counts = "[1, 1, 1, 1, 1]"),
        ), "1 to 4")
    @test has(one_row(cp(counts = "[1.0, 2.0]")), "`counts` has 2 entries")
    @test has(one_row(cp(counts = "[\"a\"]")), "`counts`")
    @test has(one_row(cp(units = "3", counts = "[1]")), "`units`")
    @test has(one_row(cp(units = "[3]")), "unit 1: is not an object")
    @test has(
        one_row(cp(units = "[{\"label\": \"A\", \"slope\": 1.0, \"sigma\": null}]")),
        "`z` is missing")
    @test has(one_row(cp(units = "[{\"z\": 1, \"slope\": null, \"sigma\": null}]")),
        "`slope`")
    @test has(one_row(replace(cp(), "\"z-ends\": 10, " => "")), "`z-ends` is missing")
    @test has(one_row(cp(pe = "null")), "`pmv-ends`")
    @test has(one_row(replace(cp(), "\"sigma-ends\": null, " => "")),
        "`sigma-ends` is missing")
    # the range of a number is ρₑ's business, not the loader's
    @test try_buffer(one_row(cp(units = "[$(u(-3))]"))) isa Vector{Solute}
    @test try_buffer(one_row(cp(counts = "[0.5]"))) isa Vector{Solute}
end

@testset "the JSON reader on the shapes the buffer needs" begin
    text = """
        {"solutes":
         [{"kind": "dna", "arg": "ACGT",
           "name": "ünï — 核", "mM": 1.5e-1, "sigma-mM": 0.01},
          {"kind": "custom-polymer", "custom": "c",
           "units": [{"z": 1, "slope": -2.5, "sigma": null}],
           "z-ends": 0, "pmv-ends": 0.0, "sigma-ends": null, "counts": [1, 2.0],
           "mM": 1, "sigma-mM": 0}]}
        """
    p = problems(text)
    # two counts for one unit: only the length rule fires
    @test p !== nothing && length(p) == 1 && occursin("`counts` has 2", p[1])
    ok = replace(text, "[1, 2.0]" => "[3]")
    s = try_buffer(ok)
    @test s[1] == DNA(0.00015, 1e-5, "ACGT")
    @test s[2].slope == [-2.5] && s[2].n == [3.0]
end

@testset "seed_keywords" begin
    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.json"))
    k = seed_keywords(defaults)
    @test k.thickness == SHELL_THICKNESS && k.probe == PROBE_RADIUS
    @test k.κ_δρ₁₂ == κ_δρ₁₂ && k.κ_δρ₃ == κ_δρ₃
    @test k.pmv_fallback_uncert == PMV_FALLBACK_UNCERT
    # the geometry, prior and c1 settings that are keywords of seed_model too
    @test length(k) == 24 && k.shell_sample == 256 && k.sasa_n_occ == 104
    # every keyword is one `seed_model` takes
    kw = Base.kwarg_decl(first(methods(seed_model)))
    @test all(n -> n in kw, keys(k))
    mktempdir() do dir
        path = joinpath(dir, "settings.json")
        write(
            path,
            "{\"inference\": {\"PMV_FALLBACK_UNCERT\": {\"value\": 7.5}, " *
            "\"κ_δρ₃\": {\"value\": 2.0}}}",
        )
        s = load_settings(path)
        k2 = seed_keywords(s)
        @test k2.pmv_fallback_uncert == 7.5 && k2.κ_δρ₃ == 2.0
        @test k2.thickness == SHELL_THICKNESS && k2.κ_δρ₁₂ == κ_δρ₁₂
    end
end

@testset "load_buffer_ph: the shared fixture and the limits" begin
    c = load_buffer_ph(FIXTURE)
    @test c == (pH = 7.4, σ_pH = 0.1)
    @test c.pH isa Float64 && c.σ_pH isa Float64
    @test load_buffer(FIXTURE) isa Vector{Solute}
    # the limits are the ones of the interface's asset file
    asset = _read_json(
        read(
            joinpath(@__DIR__, "..", "..", "..", "tui", "assets", "data",
                "buffer_conditions.json"), String))
    @test (asset[:pH][:min], asset[:pH][:max]) == (BUFFER_PH_MIN, BUFFER_PH_MAX)
    @test (asset[:sigmaPh][:min], asset[:sigmaPh][:max]) ==
          (BUFFER_SIGMA_PH_MIN, BUFFER_SIGMA_PH_MAX)
end

"`load_buffer_ph` (or `load_buffer`) on a file holding `text`: the result or the error."
function try_ph(text; f = load_buffer_ph)
    mktempdir() do dir
        path = joinpath(dir, "buffer.json")
        write(path, text)
        with_logger(NullLogger()) do
            try
                f(path)
            catch e
                e isa InvalidBufferError ? e : rethrow()
            end
        end
    end
end

@testset "load_buffer_ph: what is refused" begin
    ok = "{\"solutes\": [], \"pH\": 6.5, \"sigma-pH\": 0}"
    @test try_ph(ok) == (pH = 6.5, σ_pH = 0.0)
    @test try_ph("{\"solutes\": [], \"pH\": 0, \"sigma-pH\": 14}") ==
          (pH = 0.0, σ_pH = 14.0)
    # no conditions: load_buffer is fine, load_buffer_ph insists
    none = "{\"solutes\": []}"
    @test try_ph(none; f = load_buffer) == Solute[]
    e = try_ph(none)
    @test e isa InvalidBufferError && occursin("no `pH`", e.problems[1])
    for extra in ("\"pH\": 7", "\"sigma-pH\": 0.1", "\"pH\": -0.5, \"sigma-pH\": 0.1",
        "\"pH\": 14.5, \"sigma-pH\": 0.1", "\"pH\": 7, \"sigma-pH\": -1",
        "\"pH\": 7, \"sigma-pH\": 15", "\"pH\": \"7\", \"sigma-pH\": 0.1",
        "\"pH\": 7, \"sigma-pH\": null", "\"pH\": true, \"sigma-pH\": 0.1")
        text = "{\"solutes\": [], $extra}"
        @test try_ph(text) isa InvalidBufferError
        # a bad pH also makes the whole buffer invalid, as it does for the interface
        @test try_ph(text; f = load_buffer) isa InvalidBufferError
    end
    e = try_ph("{\"solutes\": [], \"pH\": 7}")
    @test any(occursin("sigma-pH", p) for p in e.problems)
    # a missing file and a file that is no buffer
    mktempdir() do dir
        path = joinpath(dir, "nope.json")
        e = with_logger(NullLogger()) do
            try
                load_buffer_ph(path)
            catch e
                e
            end
        end
        @test e isa InvalidBufferError && occursin("does not exist", e.problems[1])
    end
    @test try_ph("[1]") isa InvalidBufferError
end
