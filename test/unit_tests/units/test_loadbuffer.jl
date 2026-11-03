# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/Buffer.jl: `load_buffer` reads the buffer.edn of a project (mM as
# typed) into the `Vector{Solute}` of `seed_model` (mol/L), against the fixture shared with
# the terminal interface (test/fixtures/buffer/buffer.edn), the shape errors, the missing
# file and the empty buffer; and `seed_keywords` (src/Pipeline/Settings.jl).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Logging
using BAYSOL.Pipeline:
    load_buffer, InvalidBufferError, seed_keywords, load_settings,
    seed_model
using BAYSOL.BulkElectronDensity: Solute, NonBiological, Polymer, Protein, DNA, RNA,
    CustomNonBio, CustomPolymer, ρₑ, _ρₑ_i
using BAYSOL.Inference: κ_δρ₁₂, κ_δρ₃, PMV_FALLBACK_UNCERT
using BAYSOL.Scattering: SHELL_THICKNESS
using BAYSOL.Geometry: PROBE_RADIUS

const FIXTURE = joinpath(@__DIR__, "..", "..", "fixtures", "buffer", "buffer.edn")

"`load_buffer` on a file holding `text`: the solutes or the error, warnings silenced."
function try_buffer(text)
    mktempdir() do dir
        path = joinpath(dir, "buffer.edn")
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

"A buffer file with the one row `row` (EDN text)."
one_row(row) = "{:solutes [$row]}"

const NB = "{:kind :nonbiological :arg \"sodium chloride\" :mM 200.0 :sigma-mM 10.0}"

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
        path = joinpath(dir, "nope.edn")
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
        write(path, "{:solutes []}")
        @test_logs (:warn, "the buffer has no solutes: pure water") (
            @test load_buffer(path) == Solute[]
        )
    end
    @test try_buffer("{:solutes []}") == Solute[]
end

@testset "load_buffer: invalid files" begin
    @test has("not edn {", "cannot be read")
    @test has("[1 2]", ":solutes")
    @test has("{:other []}", ":solutes")
    @test has("{:solutes 3}", ":solutes")
    @test has(one_row("3"), "solute 1: is not a map")
    @test has(one_row("{:kind :metal :arg \"x\" :mM 1 :sigma-mM 0}"), "unknown `:kind`")
    @test has(one_row("{:arg \"x\" :mM 1 :sigma-mM 0}"), "unknown `:kind`")
    @test has(one_row("{:kind :dna :mM 1 :sigma-mM 0}"), "`arg` is missing")
    @test has(one_row("{:kind :dna :arg 5 :mM 1 :sigma-mM 0}"), "`arg` is 5")
    @test has(one_row("{:kind :dna :arg \"\" :mM 1 :sigma-mM 0}"), "`arg`")
    @test has(one_row("{:kind :dna :arg \"AC\" :sigma-mM 0}"), "`mM` is missing")
    @test has(one_row("{:kind :dna :arg \"AC\" :mM \"1\" :sigma-mM 0}"), "`mM`")
    @test has(one_row("{:kind :dna :arg \"AC\" :mM 0 :sigma-mM 0}"), "above 0")
    @test has(one_row("{:kind :dna :arg \"AC\" :mM -1 :sigma-mM 0}"), "above 0")
    @test has(one_row("{:kind :dna :arg \"AC\" :mM 1}"), "`sigma-mM` is missing")
    @test has(one_row("{:kind :dna :arg \"AC\" :mM 1 :sigma-mM nil}"), "`sigma-mM`")
    @test has(one_row("{:kind :dna :arg \"AC\" :mM 1 :sigma-mM -0.1}"), "negative")
    # the row number is 1-based and the later rows are still checked
    p = problems("{:solutes [$NB {:kind :dna :mM 1 :sigma-mM 0} 7]}")
    @test length(p) == 2 && occursin("solute 2", p[1]) && occursin("solute 3", p[2])
    # integers are numbers
    @test try_buffer(one_row("{:kind :dna :arg \"AC\" :mM 1 :sigma-mM 0}")) ==
          Solute[DNA(0.001, 0.0, "AC")]

    cn =
        "{:kind :custom-nonbio :custom \"x\" :z 5 :pmv 10.0 :sigma-pmv nil " *
        ":mM 1 :sigma-mM 0}"
    @test try_buffer(one_row(cn)) ==
          Solute[CustomNonBio(0.001, 0.0, "x", 5, 10.0, nothing)]
    @test has(one_row(replace(cn, ":custom \"x\"" => ":custom \"\"")), "`custom`")
    @test has(one_row(replace(cn, ":z 5" => "")), "`z` is missing")
    @test has(one_row(replace(cn, ":z 5" => ":z 5.5")), "`z` is 5.5")
    @test has(one_row(replace(cn, ":pmv 10.0" => ":pmv nil")), "`pmv`")
    @test has(one_row(replace(cn, ":sigma-pmv nil" => "")), "`sigma-pmv` is missing")
    @test has(one_row(replace(cn, ":sigma-pmv nil" => ":sigma-pmv \"a\"")),
        "`sigma-pmv`")

    u(z = 24) = "{:label \"A\" :formula \"C\" :z $z :slope 1.0 :sigma nil}"
    cp(; units = "[$(u())]", counts = "[22.0]", extra = "") =
        "{:kind :custom-polymer :custom \"c\" :units $units :z-ends 10 :pmv-ends 1.0 " *
        ":sigma-ends nil :counts $counts :mM 1 :sigma-mM 0 $extra}"
    @test try_buffer(one_row(cp())) isa Vector{Solute}
    @test has(one_row(cp(units = "[]", counts = "[]")), "1 to 4")
    @test has(
        one_row(cp(units = "[$(u()) $(u()) $(u()) $(u()) $(u())]",
            counts = "[1 1 1 1 1]")), "1 to 4")
    @test has(one_row(cp(counts = "[1.0 2.0]")), "`:counts` has 2 entries")
    @test has(one_row(cp(counts = "[\"a\"]")), "`counts`")
    @test has(one_row(cp(units = "3", counts = "[1]")), "`units`")
    @test has(one_row(cp(units = "[3]")), "unit 1: is not a map")
    @test has(one_row(cp(units = "[{:label \"A\" :slope 1.0 :sigma nil}]")),
        "`z` is missing")
    @test has(one_row(cp(units = "[{:z 1 :slope nil :sigma nil}]")), "`slope`")
    @test has(one_row(replace(cp(), ":z-ends 10" => "")), "`z-ends` is missing")
    @test has(one_row(replace(cp(), ":pmv-ends 1.0" => ":pmv-ends nil")), "`pmv-ends`")
    @test has(one_row(replace(cp(), ":sigma-ends nil" => "")), "`sigma-ends` is missing")
    # the range of a number is ρₑ's business, not the loader's
    @test try_buffer(one_row(cp(units = "[$(u(-3))]"))) isa Vector{Solute}
    @test try_buffer(one_row(cp(counts = "[0.5]"))) isa Vector{Solute}
end

@testset "the EDN reader on the shapes the buffer needs" begin
    text = """
        ;; a comment, with "quotes" and {braces}
        {:solutes
         [{:kind :dna, :arg "ACGT",
           ;; a comment in the middle of a row
           :name "ünï — 核", :mM 1.5e-1, :sigma-mM .01}
          {:kind :custom-polymer, :custom "c", :units [{:z 1 :slope -2.5 :sigma nil}],
           :z-ends 0, :pmv-ends 0.0, :sigma-ends nil, :counts [1 2.0],
           :mM 1 :sigma-mM 0}]}
        """
    p = problems(text)
    # two units are not allowed by the counts: only the length rule fires
    @test p !== nothing && length(p) == 1 && occursin("`:counts` has 2", p[1])
    ok = replace(text, "[1 2.0]" => "[3]")
    s = try_buffer(ok)
    @test s[1] == DNA(0.00015, 1e-5, "ACGT")
    @test s[2].slope == [-2.5] && s[2].n == [3.0]
end

@testset "seed_keywords" begin
    defaults = load_settings(joinpath(tempdir(), "no", "such", "settings.edn"))
    k = seed_keywords(defaults)
    @test k == (thickness = SHELL_THICKNESS, probe = PROBE_RADIUS, κ_δρ₁₂ = κ_δρ₁₂,
        κ_δρ₃ = κ_δρ₃, pmv_fallback_uncert = PMV_FALLBACK_UNCERT)
    # every keyword is one `seed_model` takes
    kw = Base.kwarg_decl(first(methods(seed_model)))
    @test all(n -> n in kw, keys(k))
    mktempdir() do dir
        path = joinpath(dir, "settings.edn")
        write(
            path,
            "{:inference {\"PMV_FALLBACK_UNCERT\" {:value 7.5} " *
            "\"κ_δρ₃\" {:value 2.0}}}",
        )
        s = load_settings(path)
        k2 = seed_keywords(s)
        @test k2.pmv_fallback_uncert == 7.5 && k2.κ_δρ₃ == 2.0
        @test k2.thickness == SHELL_THICKNESS && k2.κ_δρ₁₂ == κ_δρ₁₂
    end
end
