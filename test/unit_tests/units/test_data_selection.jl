# SPDX-License-Identifier: LGPL-3.0-or-later

# The data and structure keywords of `seed_model` (`q_min`, `q_max`, `sigma_scale`,
# `exclude_q`, `lMax`, `chains`, `model`, `add_hydrogens`) and the catalog settings behind
# them (`Q_MIN` ... `ADD_HYDROGENS`): the kinds of setting the catalog gained (a number that
# may be null, a list of ranges, a list of chain ids), the curve selection, the
# structure selection (`keep_chains`, `reslove_struct(...; model)`), and `seed_model` on
# crambin with each keyword. With every keyword at its default the seed and a seeded run
# are those of the call without them.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure: LocalPathSource, StructureSourceError, reslove_struct,
    keep_chains, load_molecule, n_atoms
using BAYSOL.BulkElectronDensity: Solute, NonBiological
using BAYSOL.Pipeline: _checked_value, setting_kind, _select_curve, _apply_keywords!,
    load_settings, _relation_problems
using BAYSOL.Shannon: model_on_raw, raw_interpolation
using Logging

const _DS_CRAMBIN = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")
const _DS_ZNI = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1ZNI-TEST.cif")
const _DS_DEFAULTS = load_settings(joinpath(tempdir(), "no", "such", "settings.json"))

quiet(f) = redirect_stdout(f, devnull)

function _ds_args(src = LocalPathSource(_DS_CRAMBIN))
    q = collect(range(0.02, 0.30; length = 30))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
    return (src, 9000.0, q, I, 0.02 .* I, 7.0, 0.1, solutes)
end

"A message of the error `f` throws (`nothing` if it does not)."
function error_of(f)
    try
        f()
    catch e
        return e
    end
    return nothing
end

@testset "the catalog holds the data and structure settings" begin
    @testset "kinds" begin
        for (n, k) in (
            (:Q_MIN, :optional_float), (:Q_MAX, :optional_float),
            (:LMAX, :optional_int), (:EXCLUDE_Q, :ranges), (:CHAINS, :strings),
            (:SIGMA_SCALE, :float), (:MODEL, :int), (:ADD_HYDROGENS, :bool),
        )
            @test setting_kind(n, _DS_DEFAULTS[n]) === k
        end
        @test _DS_DEFAULTS[:Q_MIN] === nothing && _DS_DEFAULTS[:Q_MAX] === nothing
        @test _DS_DEFAULTS[:LMAX] === nothing && _DS_DEFAULTS[:EXCLUDE_Q] == ()
        @test _DS_DEFAULTS[:CHAINS] == () && _DS_DEFAULTS[:MODEL] == 1
        @test _DS_DEFAULTS[:SIGMA_SCALE] == 1.0 && _DS_DEFAULTS[:ADD_HYDROGENS] === true
    end

    @testset "values" begin
        @test _checked_value(:Q_MIN, nothing) === nothing
        @test _checked_value(:Q_MIN, 0.05) === 0.05
        @test _checked_value(:Q_MAX, 1) === 1.0
        @test _checked_value(:LMAX, nothing) === nothing
        @test _checked_value(:LMAX, 12) === 12
        @test_throws ArgumentError _checked_value(:Q_MIN, 0)       # above 0
        @test_throws ArgumentError _checked_value(:Q_MIN, -0.1)
        @test_throws ArgumentError _checked_value(:Q_MAX, NaN)
        @test_throws ArgumentError _checked_value(:Q_MAX, "0.3")
        @test_throws ArgumentError _checked_value(:LMAX, 0)
        @test_throws ArgumentError _checked_value(:LMAX, 2.5)
        @test_throws ArgumentError _checked_value(:LMAX, true)
        @test _checked_value(:SIGMA_SCALE, 2) === 2.0
        @test_throws ArgumentError _checked_value(:SIGMA_SCALE, 0)
        @test_throws ArgumentError _checked_value(:SIGMA_SCALE, nothing)
        @test _checked_value(:MODEL, 3) === 3
        @test_throws ArgumentError _checked_value(:MODEL, 0)
        @test _checked_value(:EXCLUDE_Q, []) == ()
        @test _checked_value(:EXCLUDE_Q, Any[Any[0.1, 0.2], (0.25, 0.3)]) ==
              ((0.1, 0.2), (0.25, 0.3))
        @test _checked_value(:EXCLUDE_Q, ((0, 1),)) == ((0.0, 1.0),)
        for bad in (
            0.1, [0.1, 0.2], [[0.2, 0.1]], [[0.1, 0.1]], [[-0.1, 0.1]], [[0.1]],
            [[0.1, 0.2, 0.3]], [["a", "b"]], [[0.1, NaN]], [[0.1, Inf]], Any[Any[true, 2]],
        )
            @test_throws ArgumentError _checked_value(:EXCLUDE_Q, bad)
        end
        @test _checked_value(:CHAINS, []) == ()
        @test _checked_value(:CHAINS, ["A", "b"]) == ("A", "b")
        @test _checked_value(:CHAINS, ('A', 'B')) == ("A", "B")
        for bad in ("A", ["AB"], [""], [" "], ["A", "A"], [1], [nothing], "")
            @test_throws ArgumentError _checked_value(:CHAINS, bad)
        end
    end

    @testset "q_min is below q_max" begin
        vals(a, b) = Dict{Symbol,Any}(:Q_MIN => a, :Q_MAX => b)
        @test isempty(_relation_problems(vals(0.05, 0.3)))
        @test isempty(_relation_problems(vals(nothing, 0.3)))
        @test isempty(_relation_problems(vals(0.05, nothing)))
        @test isempty(_relation_problems(vals(nothing, nothing)))
        for (a, b) in ((0.3, 0.05), (0.1, 0.1))
            p = _relation_problems(vals(a, b))
            @test length(p) == 1 && occursin("Q_MIN", p[1]) && occursin("Q_MAX", p[1])
        end
    end

    @testset "settings.json: null is no limit" begin
        mktempdir() do dir
            path = joinpath(dir, "settings.json")
            write(
                path,
                """{"data": {"Q_MIN": {"value": 0.05}, "Q_MAX": {"value": null},
                              "EXCLUDE_Q": {"value": [[0.1, 0.12]]},
                              "CHAINS": {"value": ["A"]}, "LMAX": {"value": 9}}}""",
            )
            s = load_settings(path)
            @test s[:Q_MIN] === 0.05 && s[:Q_MAX] === nothing && s[:LMAX] === 9
            @test s[:EXCLUDE_Q] == ((0.1, 0.12),) && s[:CHAINS] == ("A",)
            write(path, """{"data": {"Q_MIN": {"value": 0.4}, "Q_MAX": {"value": 0.1}}}""")
            e = with_logger(NullLogger()) do
                error_of(() -> load_settings(path))
            end
            @test e isa BAYSOL.InvalidSettingsError && occursin("Q_MIN", e.problems[1])
        end
    end

    @testset "run_project's overrides: nothing clears, :settings keeps" begin
        s = copy(_DS_DEFAULTS)
        s[:Q_MAX] = 0.3
        s[:LMAX] = 7
        _apply_keywords!(s, (; q_max = :settings, lMax = :settings, sigma_scale = nothing))
        @test s[:Q_MAX] == 0.3 && s[:LMAX] == 7 && s[:SIGMA_SCALE] == 1.0
        _apply_keywords!(s, (; q_max = nothing, lMax = nothing, q_min = 0.05))
        @test s[:Q_MAX] === nothing && s[:LMAX] === nothing && s[:Q_MIN] == 0.05
        # the rule is checked on the merged set, and `s` is unchanged on a failure
        e = error_of(() -> _apply_keywords!(s, (; q_min = 0.5, q_max = 0.2)))
        @test e isa BAYSOL.InvalidSettingsError && s[:Q_MIN] == 0.05
        @test_throws BAYSOL.InvalidSettingsError _apply_keywords!(
            s, (; exclude_q = ((0.3, 0.2),)),
        )
        _apply_keywords!(
            s,
            (; exclude_q = ((0.1, 0.2),), chains = ("A",), model = 2,
                add_hydrogens = false),
        )
        @test s[:EXCLUDE_Q] == ((0.1, 0.2),) && s[:CHAINS] == ("A",)
        @test s[:MODEL] == 2 && s[:ADD_HYDROGENS] === false
    end
end

@testset "the selection of the measured curve" begin
    q = collect(range(0.1, 1.0; length = 10))
    I = collect(1.0:10.0)
    σ = fill(0.5, 10)
    sel(; kw...) = _select_curve(
        q, I, σ; q_min = nothing, q_max = nothing, sigma_scale = 1.0, exclude_q = (),
        kw...,
    )
    @testset "nothing to do gives the same vectors" begin
        r = sel()
        @test r.q === q && r.I === I && r.σ === σ
        @test (r.n_input, r.n_cropped, r.n_excluded) == (10, 0, 0)
    end
    @testset "the range keeps both ends" begin
        r = sel(; q_min = q[3], q_max = q[8])
        @test r.q == q[3:8] && r.I == I[3:8] && r.σ == σ[3:8]
        @test (r.n_cropped, r.n_excluded) == (4, 0)
        @test sel(; q_min = q[8]).q == q[8:10]
        @test sel(; q_max = q[4]).q == q[1:4]
    end
    @testset "excluded ranges, with their ends" begin
        r = sel(; exclude_q = ((q[4], q[5]), (0.95, 2.0)))
        @test r.q == q[[1, 2, 3, 6, 7, 8, 9]]
        @test r.I == I[[1, 2, 3, 6, 7, 8, 9]]
        @test (r.n_cropped, r.n_excluded) == (0, 3)
        # overlapping ranges, and a range inside the cropped part counted once
        r = sel(; q_min = q[2], exclude_q = ((q[1], q[3]), (q[2], q[4])))
        @test r.q == q[5:10] && (r.n_cropped, r.n_excluded) == (1, 3)
    end
    @testset "the scale multiplies the errors only" begin
        r = sel(; sigma_scale = 2.5)
        @test r.σ == 2.5 .* σ && r.q === q && r.I === I
        @test σ == fill(0.5, 10)                       # the input is untouched
        r = sel(; sigma_scale = 0.5, q_max = q[5])
        @test r.σ == fill(0.25, 5)
    end
    @testset "a bad point that is left out is never looked at" begin
        Ib = copy(I)
        Ib[4] = NaN
        r = _select_curve(
            q, Ib, σ; q_min = nothing, q_max = nothing, sigma_scale = 1.0,
            exclude_q = ((q[4], q[4]),),
        )
        @test length(r.q) == 9 && all(isfinite, r.I)
    end
    @testset "fewer than 3 points is an error that names the keywords" begin
        e = error_of(() -> sel(; q_min = q[9]))
        @test e isa ArgumentError && occursin("q_min", e.msg) && occursin("q_max", e.msg)
        @test occursin("exclude_q", e.msg) && occursin("at least 3", e.msg)
        @test_throws ArgumentError sel(; q_min = q[5], q_max = q[6])
        @test_throws ArgumentError sel(; exclude_q = ((0.0, 2.0),))
        @test length(sel(; q_min = q[8]).q) == 3         # three is enough
    end
end

@testset "the selection of the structure" begin
    mktempdir() do cache
        withenv("BAYSOL_CACHE" => cache) do
            lines = readlines(_DS_CRAMBIN)
            atoms = filter(l -> startswith(l, "ATOM"), lines)
            # chains of a hand-made file: crambin as chain A, its first 100 atoms as B
            # (shifted in x so that they are not duplicates), and a water of chain C
            shifted(l, c) = l[1:21] * c * l[23:30] * lpad("50.000", 8) * l[39:end]
            two = vcat(
                atoms, ["TER"], [shifted(l, "B") for l in atoms[1:100]], ["TER"],
                [
                    "HETATM 9000  O   HOH C   1      1.000   2.000   3.000  " *
                    "1.00 10.00           O",
                ],
                ["END"],
            )
            file = joinpath(cache, "chains.pdb")
            write(file, join(two, "\n") * "\n")

            @testset "no chains: the path itself, nothing written" begin
                before = readdir(cache)
                @test keep_chains(file, ()) == file
                @test keep_chains(file, String[]) == file
                @test readdir(cache) == before
            end
            @testset "a subset of the chains" begin
                a = keep_chains(file, ("A",))
                @test dirname(a) == cache && endswith(a, ".pdb")
                @test occursin("chains.pdb"[1:(end-4)] * "_chainsA_", basename(a))
                @test count(l -> startswith(l, "ATOM"), readlines(a)) == length(atoms)
                @test !any(l -> startswith(l, "HETATM"), readlines(a))
                @test n_atoms(load_molecule(a)) == n_atoms(load_molecule(_DS_CRAMBIN))
                b = keep_chains(file, ["B"])
                @test count(l -> startswith(l, "ATOM"), readlines(b)) == 100
                @test all(
                    l -> l[22] == 'B',
                    filter(l -> startswith(l, "ATOM"), readlines(b)),
                )
                ab = keep_chains(file, ("B", "A"))
                @test count(l -> startswith(l, "ATOM"), readlines(ab)) ==
                      length(atoms) + 100
                @test ab == keep_chains(file, ("A", "B"))        # the order is no matter
                # the same call is the same file (reused, not rewritten)
                @test keep_chains(file, ("A",)) == a
            end
            @testset "the name follows the content" begin
                other = joinpath(mktempdir(), "chains.pdb")        # same stem, other file
                write(other, join(two[1:50], "\n") * "\nEND\n")
                @test keep_chains(other, ("A",)) != keep_chains(file, ("A",))
            end
            @testset "case counts, and a missing chain is an error that lists them" begin
                e = error_of(() -> keep_chains(file, ("a",)))
                @test e isa StructureSourceError && occursin("a", e.msg)
                @test occursin("A, B", e.msg) || occursin("A, B, C", e.msg)
                e = error_of(() -> keep_chains(file, ("A", "Z")))
                @test e isa StructureSourceError && occursin("Z", e.msg)
            end

            @testset "the model of a multi-model .pdb" begin
                first_atoms = atoms
                second_atoms = atoms[1:40]
                text =
                    join(
                        vcat(
                            ["REMARK a header", "MODEL        1"], first_atoms, ["ENDMDL"],
                            ["MODEL        2"], second_atoms, ["ENDMDL", "END"],
                        ), "\n") * "\n"
                multi = joinpath(cache, "multi.pdb")
                write(multi, text)
                @test reslove_struct(LocalPathSource(multi)) == abspath(multi)   # model 1
                @test reslove_struct(LocalPathSource(multi); model = 1) == abspath(multi)
                p2 = reslove_struct(LocalPathSource(multi); model = 2)
                @test p2 != abspath(multi) && occursin("multi_model2_", basename(p2))
                kept = readlines(p2)
                @test count(l -> startswith(l, "ATOM"), kept) == 40
                @test !any(l -> startswith(l, "MODEL") || startswith(l, "ENDMDL"), kept)
                @test kept[1] == "REMARK a header" && kept[end] == "END"
                @test reslove_struct(LocalPathSource(multi); model = 2) == p2
                e = error_of(() -> reslove_struct(LocalPathSource(multi); model = 3))
                @test e isa StructureSourceError && occursin("2 model", e.msg)
                e = error_of(() -> reslove_struct(LocalPathSource(_DS_CRAMBIN); model = 2))
                @test e isa StructureSourceError && occursin("1 model", e.msg)
                @test_throws StructureSourceError reslove_struct(
                    LocalPathSource(multi); model = 0,
                )
            end

            @testset "the model of an mmCIF" begin
                p1 = reslove_struct(LocalPathSource(_DS_ZNI))
                @test basename(p1) == "1ZNI-TEST.pdb"
                @test reslove_struct(LocalPathSource(_DS_ZNI); model = 1) == p1
                e = error_of(() -> reslove_struct(LocalPathSource(_DS_ZNI); model = 2))
                @test e isa StructureSourceError && occursin("model 2", e.msg)
            end
        end
    end
end

@testset "seed_model with the data and structure keywords" begin
    args = _ds_args()
    s0 = BAYSOL.seed_model(args...; add_hydrogens = false)

    @testset "every keyword at its default is the call without them" begin
        sd = BAYSOL.seed_model(
            args...; add_hydrogens = false, q_min = nothing, q_max = nothing,
            sigma_scale = 1.0, exclude_q = (), lMax = nothing, chains = (), model = 1,
        )
        sk = BAYSOL.seed_model(
            args...; BAYSOL.seed_keywords(_DS_DEFAULTS)..., add_hydrogens = false,
        )
        for s in (sd, sk)
            @test s.θ₀ == s0.θ₀ && s.pr == s0.pr
            @test s.fw.qvals == s0.fw.qvals && s.fw.n_atoms == s0.fw.n_atoms
            @test s.fw.lMax == s0.fw.lMax && s.fw.Gc == s0.fw.Gc
            @test s.c1tab.cs == s0.c1tab.cs && s.c1tab.g1 == s0.c1tab.g1
            @test all(
                f -> getfield(s.wls, f) == getfield(s0.wls, f), fieldnames(typeof(s.wls)),
            )
            @test s.shannon.q_raw == s0.shannon.q_raw && s.shannon.σ == s0.shannon.σ
            # a default run records none of the new rows
            for k in ("q_min", "q_max", "sigma_scale", "exclude_q", "n_q_input",
                "structure_model", "structure_chains", "lmax_pinned")
                @test !haskey(s.timing.info, k)
            end
        end
        a = quiet() do
            BAYSOL.run_model(s0, 40, 20; retry = false, n_chains = 2)
        end
        b = quiet() do
            BAYSOL.run_model(sd, 40, 20; retry = false, n_chains = 2)
        end
        @test a[1].samples == b[1].samples && a[3][1] == b[3][1]
    end

    @testset "the q range" begin
        s = BAYSOL.seed_model(args...; add_hydrogens = false, q_min = 0.05, q_max = 0.25)
        info = s.shannon
        @test all(0.05 .<= info.q_raw .<= 0.25) && length(info.q_raw) < 30
        @test info.q_raw == filter(x -> 0.05 <= x <= 0.25, args[3])
        @test all(0.05 .<= s.fw.qvals .<= 0.25)
        @test info.n_channels < s0.shannon.n_channels
        @test s.fw.lMax <= s0.fw.lMax                    # the band limit follows q_max
        # the measured grid works on the cropped curve
        y = model_on_raw(info, info.I)
        @test length(y) == length(info.q_raw)
        M = raw_interpolation(info)
        @test size(M) == (length(info.q_raw), length(info.q))
        @test s.timing.info["q_min"] == 0.05 && s.timing.info["q_max"] == 0.25
        @test s.timing.info["n_q_input"] == 30
        @test s.timing.info["n_q_cropped"] == 30 - length(info.q_raw)
        @test s.timing.info["n_q_excluded"] == 0
        # a raw point the range dropped is not in the fit, and the others are as given
        @test length(s.fw.qvals) <= length(info.q_raw)
    end

    @testset "the excluded ranges" begin
        s = BAYSOL.seed_model(
            args...; add_hydrogens = false, exclude_q = ((0.1, 0.15), (0.2, 0.22)),
        )
        q = args[3]
        gone = [x for x in q if 0.1 <= x <= 0.15 || 0.2 <= x <= 0.22]
        @test !isempty(gone) && s.shannon.q_raw == setdiff(q, gone)
        @test s.timing.info["n_q_excluded"] == length(gone)
        @test s.timing.info["exclude_q"] == "0.1-0.15; 0.2-0.22"
    end

    @testset "the error scale" begin
        s = BAYSOL.seed_model(args...; add_hydrogens = false, sigma_scale = 2.0)
        @test s.shannon.σ_raw == 2.0 .* args[5] && s.shannon.I_raw == args[4]
        @test s.timing.info["sigma_scale"] == 2.0
        # the binned errors are those of the scaled ones
        @test isapprox(s.shannon.σ, 2 .* s0.shannon.σ; rtol = 1e-12)
    end

    @testset "lMax pinned" begin
        s = BAYSOL.seed_model(args...; add_hydrogens = false, lMax = 6)
        @test s.fw.lMax == 6 && s.timing.info["lmax_pinned"] == 1
        @test s.fw.lMax != s0.fw.lMax
    end

    @testset "add_hydrogens off is recorded" begin
        @test s0.timing.info["add_hydrogens"] == 0
    end

    @testset "bad values stop at once, with clear messages" begin
        t = @elapsed begin
            e = error_of(() -> BAYSOL.seed_model(args...; q_min = 0.3, q_max = 0.1))
            @test e isa BAYSOL.InvalidSettingsError &&
                  occursin("Q_MIN = 0.3", e.problems[1])
            e = error_of(() -> BAYSOL.seed_model(args...; sigma_scale = 0))
            @test e isa BAYSOL.InvalidSettingsError &&
                  occursin("SIGMA_SCALE", e.problems[1])
            e = error_of(() -> BAYSOL.seed_model(args...; exclude_q = ((0.3, 0.1),)))
            @test e isa BAYSOL.InvalidSettingsError && occursin("EXCLUDE_Q", e.problems[1])
            e = error_of(() -> BAYSOL.seed_model(args...; chains = ("AB",)))
            @test e isa BAYSOL.InvalidSettingsError && occursin("CHAINS", e.problems[1])
            e = error_of(() -> BAYSOL.seed_model(args...; model = 0))
            @test e isa BAYSOL.InvalidSettingsError && occursin("MODEL", e.problems[1])
            # fewer than 3 points: an ArgumentError naming the keywords, not a WLSError
            e = error_of(() -> BAYSOL.seed_model(args...; q_min = 0.29, q_max = 0.31))
            @test e isa ArgumentError && occursin("q_min", e.msg) &&
                  occursin("at least 3", e.msg)
            e = error_of(() -> BAYSOL.seed_model(args...; exclude_q = ((0.0, 1.0),)))
            @test e isa ArgumentError && occursin("exclude_q", e.msg)
        end
        @test t < 5                      # the structure is not touched
    end

    @testset "a curve with fewer than 3 points after the binning is refused" begin
        # 3 raw points that the binning merges into one
        q = [0.020, 0.021, 0.022, 0.2, 0.25, 0.3]
        I = [100.0, 99.0, 98.0, 50.0, 20.0, 5.0]
        a = _ds_args()
        e = error_of(
            () -> BAYSOL.seed_model(
                a[1], a[2], q, I, 0.05 .* I, a[6], a[7], a[8];
                add_hydrogens = false, q_min = 0.019, q_max = 0.0225,
            ),
        )
        @test e isa ArgumentError && occursin("at least 3", e.msg)
    end

    @testset "chains and model on a real structure" begin
        mktempdir() do cache
            withenv("BAYSOL_CACHE" => cache) do
                za = _ds_args(LocalPathSource(_DS_ZNI))
                sall = BAYSOL.seed_model(za...; add_hydrogens = false)
                sac = BAYSOL.seed_model(za...; add_hydrogens = false, chains = ("A", "C"))
                @test sac.fw.n_atoms < sall.fw.n_atoms
                path = reslove_struct(LocalPathSource(_DS_ZNI))
                @test sac.fw.n_atoms ==
                      n_atoms(load_molecule(keep_chains(path, ("A", "C"))))
                @test sac.timing.info["structure_chains"] == "A,C"
                e = error_of(
                    () -> BAYSOL.seed_model(za...; add_hydrogens = false, chains = ("Z",)),
                )
                @test e isa StructureSourceError && occursin("Z", e.msg)
                e = error_of(
                    () -> BAYSOL.seed_model(za...; add_hydrogens = false, model = 2),
                )
                @test e isa StructureSourceError
            end
        end
    end
end
