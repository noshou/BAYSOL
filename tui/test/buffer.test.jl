# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises tui/src/store/buffer.jl: `loadBuffer` reads the buffer.json of a project (mM as
# typed) into the `Vector{Solute}` of `seedModel` (mol/L), against the fixture shared with
# the terminal interface (test/fixtures/buffer/buffer.json), the shape errors, the missing
# file, the empty buffer, the pH and sigmaPh (`loadBufferPh`); and `seedKeywords`
# (src/pipeline/settings.jl).
include(joinpath(@__DIR__, "julia-setup.jl"))

using Logging
using BAYSOL.Pipeline: seedKeywords, seedModel
using Main.BAYSOLRun: loadBuffer, loadBufferPh, InvalidBufferError, loadSettings,
    BUFFER_PH_MIN, BUFFER_PH_MAX, BUFFER_SIGMA_PH_MIN, BUFFER_SIGMA_PH_MAX,
    BUFFER_TEMPERATURE_MIN, BUFFER_TEMPERATURE_MAX, _readJson
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer, Protein, DNA, RNA,
    CustomNonBio, CustomPolymer, ρₑ, _ρₑ_i
using BAYSOL.Inference: κ_δρ₁₂, κ_δρ₃, PMV_FALLBACK_UNCERT
using BAYSOL.Scattering: SHELL_THICKNESS
using BAYSOL.Geometry: PROBE_RADIUS

const FIXTURE = joinpath(@__DIR__, "..", "..", "test", "fixtures", "buffer", "buffer.json")

"`loadBuffer` on a file holding `text`: the solutes or the error, warnings silenced."
function tryBuffer(text)
    mktempdir() do dir
        path = joinpath(dir, "buffer.json")
        write(path, text)
        with_logger(NullLogger()) do
            try
                loadBuffer(path)
            catch e
                e isa InvalidBufferError ? e : rethrow()
            end
        end
    end
end

"A buffer file with the one row `row` (JSON text)."
oneRow(row) = "{\"solutes\": [$row]}"

# A JSON row from its keys (`k => json text of the value`, in order).
row(pairs...) = "{" * join(("\"$k\": $v" for (k, v) in pairs), ", ") * "}"
const NB = row("kind" => "\"nonbiological\"", "arg" => "\"sodium chloride\"",
    "mM" => "200.0", "sigmaMm" => "10.0")


problems(text) = (r = tryBuffer(text); r isa InvalidBufferError ? r.problems : nothing)
function has(text, needle)
    p = problems(text)
    return p !== nothing && any(occursin(needle, x) for x in p)
end

@testset "loadBuffer: the shared fixture" begin
    s = loadBuffer(FIXTURE)
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
    @test one.molarity == 0.01 / 1000 && one.molarityUncertainty == 0.0001 / 1000
    @test one.n == [22.0] && one.zUnit == [24] && one.slope == [36.73]
    @test one.σ_unit == [nothing] && one.σ_unit isa Vector{Union{Nothing,Float64}}
    @test one.zEnds == 10 && one.v0 == 19.24 && one.σ_ends === nothing

    four = s[11]
    @test four.arg == "chain-4"
    @test four.n == [3.0, 4.0, 5.0, 6.0]
    @test four.zUnit == [10, 20, 30, 40]
    @test four.slope == [1.0, 2.0, 3.0, 4.0]
    @test four.σ_unit == [nothing, 0.1, nothing, 0.2]
    @test four.zEnds == 5 && four.v0 == 7.0 && four.σ_ends == 0.5

    @testset "the numbers through ρₑ's helper" begin
        Z, v, _ = _ρₑ_i(four, 7.4, 0.05, 3.5)
        @test Z == 505.0 && v == 57.0
        z1, v1, _ = _ρₑ_i(one, 7.4, 0.05, 3.5)
        @test z1 == 10 + 24 * 22 && v1 ≈ 19.24 + 36.73 * 22
    end

    @testset "round trip: the same ρₑ as the CustomPolymer built by hand" begin
        byHand =
            CustomPolymer(0.01 / 1000, 0.0001 / 1000, "chain-4", [3.0, 4.0, 5.0, 6.0],
                [10, 20, 30, 40], [1.0, 2.0, 3.0, 4.0],
                Union{Nothing,Float64}[nothing, 0.1, nothing, 0.2], 5, 7.0, 0.5)
        @test ρₑ(7.4, 0.05, Solute[four]) == ρₑ(7.4, 0.05, Solute[byHand])
        @test ρₑ(7.4, 0.05, s) isa Tuple{Float64,Float64}
    end
end

@testset "loadBuffer: missing file and empty buffer" begin
    mktempdir() do dir
        path = joinpath(dir, "nope.json")
        e = with_logger(NullLogger()) do
            try
                loadBuffer(path)
            catch e
                e
            end
        end
        @test e isa InvalidBufferError
        @test occursin("does not exist", e.problems[1])
        @test_logs (:warn, r"invalid buffer") (
            @test_throws InvalidBufferError loadBuffer(path)
        )
        write(path, "{\"solutes\": []}")
        @test_logs (:warn, "the buffer has no solutes: pure water") (
            @test loadBuffer(path) == Solute[]
        )
    end
    @test tryBuffer("{\"solutes\": []}") == Solute[]
end

@testset "loadBuffer: the notes of the interface are not the loader's business" begin
    # `"notes"` (an array of {title, text}) sits next to `solutes`; the loader ignores it
    notes = "[{\"title\": \"setup\", \"text\": \"line 1\\nline 2\"}]"
    plain = tryBuffer(oneRow(NB))
    @test plain isa Vector{Solute}
    @test tryBuffer("{\"solutes\": [$NB], \"notes\": $notes}") == plain
end

@testset "loadBuffer: invalid files" begin
    dna(; kind = "\"dna\"", arg = "\"AC\"", mM = "1", sm = "0") =
        row("kind" => kind, "arg" => arg, "mM" => mM, "sigmaMm" => sm)
    @test has("not json {", "cannot be read")
    @test has("[1, 2]", "`solutes`")
    @test has("{\"other\": []}", "`solutes`")
    @test has("{\"solutes\": 3}", "`solutes`")
    @test has(oneRow("3"), "solute 1: is not an object")
    @test has(oneRow(dna(kind = "\"metal\"")), "unknown `kind`")
    @test has(oneRow(row("arg" => "\"x\"", "mM" => "1", "sigmaMm" => "0")),
        "unknown `kind`")
    @test has(oneRow(row("kind" => "\"dna\"", "mM" => "1", "sigmaMm" => "0")),
        "`arg` is missing")
    @test has(oneRow(dna(arg = "5")), "`arg` is 5")
    @test has(oneRow(dna(arg = "\"\"")), "`arg`")
    @test has(oneRow(row("kind" => "\"dna\"", "arg" => "\"AC\"", "sigmaMm" => "0")),
        "`mM` is missing")
    @test has(oneRow(dna(mM = "\"1\"")), "`mM`")
    @test has(oneRow(dna(mM = "0")), "above 0")
    @test has(oneRow(dna(mM = "-1")), "above 0")
    @test has(oneRow(row("kind" => "\"dna\"", "arg" => "\"AC\"", "mM" => "1")),
        "`sigmaMm` is missing")
    @test has(oneRow(dna(sm = "null")), "`sigmaMm`")
    @test has(oneRow(dna(sm = "-0.1")), "negative")
    # the row number is 1-based and the later rows are still checked
    p = problems("{\"solutes\": [$NB, $(row("kind" => "\"dna\"", "mM" => "1",
        "sigmaMm" => "0")), 7]}")
    @test length(p) == 2 && occursin("solute 2", p[1]) && occursin("solute 3", p[2])
    # integers are numbers
    @test tryBuffer(oneRow(dna())) == Solute[DNA(0.001, 0.0, "AC")]

    cn(; custom = "\"x\"", z = "5", pmv = "10.0", sp = "null") =
        row("kind" => "\"custom-nonbio\"", "custom" => custom, "z" => z, "pmv" => pmv,
            "sigmaPmv" => sp, "mM" => "1", "sigmaMm" => "0")
    @test tryBuffer(oneRow(cn())) ==
          Solute[CustomNonBio(0.001, 0.0, "x", 5, 10.0, nothing)]
    @test has(oneRow(cn(custom = "\"\"")), "`custom`")
    @test has(oneRow(replace(cn(), "\"z\": 5, " => "")), "`z` is missing")
    @test has(oneRow(cn(z = "5.5")), "`z` is 5.5")
    @test has(oneRow(cn(pmv = "null")), "`pmv`")
    @test has(oneRow(replace(cn(), "\"sigmaPmv\": null, " => "")),
        "`sigmaPmv` is missing")
    @test has(oneRow(cn(sp = "\"a\"")), "`sigmaPmv`")

    u(z = 24) =
        "{\"label\": \"A\", \"formula\": \"C\", \"z\": $z, \"slope\": 1.0, " *
        "\"sigma\": null}"
    cp(; units = "[$(u())]", counts = "[22.0]", ze = "10", pe = "1.0", se = "null") =
        row("kind" => "\"custom-polymer\"", "custom" => "\"c\"", "units" => units,
            "zEnds" => ze, "pmvEnds" => pe, "sigmaEnds" => se, "counts" => counts,
            "mM" => "1", "sigmaMm" => "0")
    @test tryBuffer(oneRow(cp())) isa Vector{Solute}
    @test has(oneRow(cp(units = "[]", counts = "[]")), "1 to 4")
    @test has(
        oneRow(
            cp(units = "[$(u()), $(u()), $(u()), $(u()), $(u())]",
                counts = "[1, 1, 1, 1, 1]"),
        ), "1 to 4")
    @test has(oneRow(cp(counts = "[1.0, 2.0]")), "`counts` has 2 entries")
    @test has(oneRow(cp(counts = "[\"a\"]")), "`counts`")
    @test has(oneRow(cp(units = "3", counts = "[1]")), "`units`")
    @test has(oneRow(cp(units = "[3]")), "unit 1: is not an object")
    @test has(
        oneRow(cp(units = "[{\"label\": \"A\", \"slope\": 1.0, \"sigma\": null}]")),
        "`z` is missing")
    @test has(oneRow(cp(units = "[{\"z\": 1, \"slope\": null, \"sigma\": null}]")),
        "`slope`")
    @test has(oneRow(replace(cp(), "\"zEnds\": 10, " => "")), "`zEnds` is missing")
    @test has(oneRow(cp(pe = "null")), "`pmvEnds`")
    @test has(oneRow(replace(cp(), "\"sigmaEnds\": null, " => "")),
        "`sigmaEnds` is missing")
    # the range of a number is ρₑ's business, not the loader's
    @test tryBuffer(oneRow(cp(units = "[$(u(-3))]"))) isa Vector{Solute}
    @test tryBuffer(oneRow(cp(counts = "[0.5]"))) isa Vector{Solute}
end

@testset "the JSON reader on the shapes the buffer needs" begin
    text = """
        {"solutes":
         [{"kind": "dna", "arg": "ACGT",
           "name": "ünï — 核", "mM": 1.5e-1, "sigmaMm": 0.01},
          {"kind": "custom-polymer", "custom": "c",
           "units": [{"z": 1, "slope": -2.5, "sigma": null}],
           "zEnds": 0, "pmvEnds": 0.0, "sigmaEnds": null, "counts": [1, 2.0],
           "mM": 1, "sigmaMm": 0}]}
        """
    p = problems(text)
    # two counts for one unit: only the length rule fires
    @test p !== nothing && length(p) == 1 && occursin("`counts` has 2", p[1])
    ok = replace(text, "[1, 2.0]" => "[3]")
    s = tryBuffer(ok)
    @test s[1] == DNA(0.00015, 1e-5, "ACGT")
    @test s[2].slope == [-2.5] && s[2].n == [3.0]
end

@testset "seedKeywords" begin
    defaults = loadSettings(joinpath(tempdir(), "no", "such", "settings.json"))
    k = seedKeywords(defaults)
    @test k.thickness == SHELL_THICKNESS && k.probe == PROBE_RADIUS
    @test k.κ_δρ₁₂ == κ_δρ₁₂ && k.κ_δρ₃ == κ_δρ₃
    @test k.pmvFallbackUncert == PMV_FALLBACK_UNCERT
    # the geometry, prior and c1 settings that are keywords of seedModel too
    @test length(k) == 24 && k.shellSample == 256 && k.sasaNOcc == 104
    # every keyword is one `seedModel` takes
    kw = Base.kwarg_decl(first(methods(seedModel)))
    @test all(n -> n in kw, keys(k))
    mktempdir() do dir
        path = joinpath(dir, "settings.json")
        write(
            path,
            "{\"inference\": {\"PMV_FALLBACK_UNCERT\": {\"value\": 7.5}, " *
            "\"κ_δρ₃\": {\"value\": 2.0}}}",
        )
        s = loadSettings(path)
        k2 = seedKeywords(s)
        @test k2.pmvFallbackUncert == 7.5 && k2.κ_δρ₃ == 2.0
        @test k2.thickness == SHELL_THICKNESS && k2.κ_δρ₁₂ == κ_δρ₁₂
    end
end

@testset "loadBufferPh: the shared fixture and the limits" begin
    c = loadBufferPh(FIXTURE)
    @test c == (pH = 7.4, σ_pH = 0.1)
    @test c.pH isa Float64 && c.σ_pH isa Float64
    @test loadBuffer(FIXTURE) isa Vector{Solute}
    # the limits are the ones of the interface's asset file
    asset = _readJson(
        read(
            joinpath(@__DIR__, "..", "assets", "data",
                "buffer_conditions.json"), String))
    @test (asset[:pH][:min], asset[:pH][:max]) == (BUFFER_PH_MIN, BUFFER_PH_MAX)
    @test (asset[:sigmaPh][:min], asset[:sigmaPh][:max]) ==
          (BUFFER_SIGMA_PH_MIN, BUFFER_SIGMA_PH_MAX)
    @test (asset[:temperature][:min], asset[:temperature][:max]) ==
          (BUFFER_TEMPERATURE_MIN, BUFFER_TEMPERATURE_MAX)
end

"`loadBufferPh` (or `loadBuffer`) on a file holding `text`: the result or the error."
function tryPh(text; f = loadBufferPh)
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

@testset "loadBufferPh: what is refused" begin
    ok = "{\"solutes\": [], \"pH\": 6.5, \"sigmaPh\": 0}"
    @test tryPh(ok) == (pH = 6.5, σ_pH = 0.0)
    @test tryPh("{\"solutes\": [], \"pH\": 0, \"sigmaPh\": 14}") ==
          (pH = 0.0, σ_pH = 14.0)
    # no conditions: loadBuffer is fine, loadBufferPh insists
    none = "{\"solutes\": []}"
    @test tryPh(none; f = loadBuffer) == Solute[]
    e = tryPh(none)
    @test e isa InvalidBufferError && occursin("no `pH`", e.problems[1])
    for extra in ("\"pH\": 7", "\"sigmaPh\": 0.1", "\"pH\": -0.5, \"sigmaPh\": 0.1",
        "\"pH\": 14.5, \"sigmaPh\": 0.1", "\"pH\": 7, \"sigmaPh\": -1",
        "\"pH\": 7, \"sigmaPh\": 15", "\"pH\": \"7\", \"sigmaPh\": 0.1",
        "\"pH\": 7, \"sigmaPh\": null", "\"pH\": true, \"sigmaPh\": 0.1")
        text = "{\"solutes\": [], $extra}"
        @test tryPh(text) isa InvalidBufferError
        # a bad pH also makes the whole buffer invalid, as it does for the interface
        @test tryPh(text; f = loadBuffer) isa InvalidBufferError
    end
    e = tryPh("{\"solutes\": [], \"pH\": 7}")
    @test any(occursin("sigmaPh", p) for p in e.problems)
    # a missing file and a file that is no buffer
    mktempdir() do dir
        path = joinpath(dir, "nope.json")
        e = with_logger(NullLogger()) do
            try
                loadBufferPh(path)
            catch e
                e
            end
        end
        @test e isa InvalidBufferError && occursin("does not exist", e.problems[1])
    end
    @test tryPh("[1]") isa InvalidBufferError
end

@testset "loadBufferPh: the optional temperature" begin
    base = "{\"solutes\": [], \"pH\": 6.5, \"sigmaPh\": 0.1"
    # present and valid, or absent: both load, the temperature is not returned
    for t in ("4", "0", "100", "22.5")
        @test tryPh("$base, \"temperature\": $t}") == (pH = 6.5, σ_pH = 0.1)
        @test tryPh("$base, \"temperature\": $t}"; f = loadBuffer) == Solute[]
    end
    @test tryPh("$base}") == (pH = 6.5, σ_pH = 0.1)
    # out of range, not a number: refused, naming the key
    for t in ("150", "-1", "100.5", "\"4\"", "null", "true")
        e = tryPh("$base, \"temperature\": $t}")
        @test e isa InvalidBufferError && occursin("temperature", e.problems[1])
        @test tryPh("$base, \"temperature\": $t}"; f = loadBuffer) isa
              InvalidBufferError
    end
end

@testset "loadBuffer: a row that follows the pH (`template`) loads like any row" begin
    link =
        "{\"id\": \"tris\", \"mM\": 10, \"sigmaMm\": 0.2, \"titrant\": \"chloride\"," *
        " \"restMm\": 100}"
    linked = row("kind" => "\"nonbiological\"", "arg" => "\"chloride\"", "mM" => "8.5",
        "sigmaMm" => "0.4", "template" => link)
    # the extra key is ignored, even one that is not a valid link
    s = tryBuffer("{\"solutes\": [$NB, $linked]}")
    @test s isa Vector
    @test length(s) == 2
    odd = row("kind" => "\"nonbiological\"", "arg" => "\"chloride\"", "mM" => "8.5",
        "sigmaMm" => "0.4", "template" => "\"not an object\"")
    @test tryBuffer(oneRow(odd)) isa Vector
end

@testset "loadBuffer: the same solute twice is refused" begin
    twin = row("kind" => "\"nonbiological\"", "arg" => "\" Sodium Chloride \"",
        "mM" => "5.0", "sigmaMm" => "0.1")
    other = row("kind" => "\"nonbiological\"", "arg" => "\"chloride\"", "mM" => "5.0",
        "sigmaMm" => "0.1")
    @test has("{\"solutes\": [$NB, $other, $twin]}", "row 3: duplicate of row 1")
    # different solutes, and a polymer of the same name as a solute, are fine
    @test tryBuffer("{\"solutes\": [$NB, $other]}") isa Vector
    poly = row("kind" => "\"polymer\"", "arg" => "\"sodium chloride\"", "mM" => "1.0",
        "sigmaMm" => "0.1")
    @test tryBuffer("{\"solutes\": [$NB, $poly]}") isa Vector
end
