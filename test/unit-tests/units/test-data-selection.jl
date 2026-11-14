# SPDX-License-Identifier: LGPL-3.0-or-later

# The data and structure keywords of `seedModel` (`qMin`, `qMax`, `sigmaScale`,
# `excludeQ`, `lMax`, `chains`, `model`, `addHydrogens`) and the catalog settings behind
# them (`Q_MIN` ... `ADD_HYDROGENS`): the kinds of setting the catalog gained (a number that
# may be null, a list of ranges, a list of chain ids), the curve selection, the
# structure selection (`keepChains`, `resloveStruct(...; model)`), and `seedModel` on
# crambin with each keyword. With every keyword at its default the seed and a seeded run
# are those of the call without them.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure:
    LocalPathSource, StructureSourceError, resloveStruct,
    keepChains, loadMolecule, nAtoms
using BAYSOL.BulkElectronDensity: Solute, NonBiological
using BAYSOL.Pipeline:
    _checkedValue, settingKind, _selectCurve, _applyKeywords!,
    _relationProblems
using BAYSOL.Shannon: modelOnRaw, rawInterpolation
using Logging

const _DS_CRAMBIN = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")
const _DS_ZNI = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1ZNI-TEST.cif")
const _DS_DEFAULTS = defaultSettings()

quiet(f) = redirect_stdout(f, devnull)

function _dsArgs(src = LocalPathSource(_DS_CRAMBIN))
    q = collect(range(0.02, 0.30; length = 30))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
    return (src, 9000.0, q, I, 0.02 .* I, 7.0, 0.1, solutes)
end

"A message of the error `f` throws (`nothing` if it does not)."
function errorOf(f)
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
            (:Q_MIN, :optionalFloat), (:Q_MAX, :optionalFloat),
            (:LMAX, :optionalInt), (:EXCLUDE_Q, :ranges), (:CHAINS, :strings),
            (:SIGMA_SCALE, :float), (:MODEL, :int), (:ADD_HYDROGENS, :bool),
        )
            @test settingKind(n, _DS_DEFAULTS[n]) === k
        end
        @test _DS_DEFAULTS[:Q_MIN] === nothing && _DS_DEFAULTS[:Q_MAX] === nothing
        @test _DS_DEFAULTS[:LMAX] === nothing && _DS_DEFAULTS[:EXCLUDE_Q] == ()
        @test _DS_DEFAULTS[:CHAINS] == () && _DS_DEFAULTS[:MODEL] == 1
        @test _DS_DEFAULTS[:SIGMA_SCALE] == 1.0 && _DS_DEFAULTS[:ADD_HYDROGENS] === true
    end

    @testset "values" begin
        @test _checkedValue(:Q_MIN, nothing) === nothing
        @test _checkedValue(:Q_MIN, 0.05) === 0.05
        @test _checkedValue(:Q_MAX, 1) === 1.0
        @test _checkedValue(:LMAX, nothing) === nothing
        @test _checkedValue(:LMAX, 12) === 12
        @test_throws ArgumentError _checkedValue(:Q_MIN, 0)       # above 0
        @test_throws ArgumentError _checkedValue(:Q_MIN, -0.1)
        @test_throws ArgumentError _checkedValue(:Q_MAX, NaN)
        @test_throws ArgumentError _checkedValue(:Q_MAX, "0.3")
        @test_throws ArgumentError _checkedValue(:LMAX, 0)
        @test_throws ArgumentError _checkedValue(:LMAX, 2.5)
        @test_throws ArgumentError _checkedValue(:LMAX, true)
        @test _checkedValue(:SIGMA_SCALE, 2) === 2.0
        @test_throws ArgumentError _checkedValue(:SIGMA_SCALE, 0)
        @test_throws ArgumentError _checkedValue(:SIGMA_SCALE, nothing)
        @test _checkedValue(:MODEL, 3) === 3
        @test_throws ArgumentError _checkedValue(:MODEL, 0)
        @test _checkedValue(:EXCLUDE_Q, []) == ()
        @test _checkedValue(:EXCLUDE_Q, Any[Any[0.1, 0.2], (0.25, 0.3)]) ==
              ((0.1, 0.2), (0.25, 0.3))
        @test _checkedValue(:EXCLUDE_Q, ((0, 1),)) == ((0.0, 1.0),)
        for bad in (
            0.1, [0.1, 0.2], [[0.2, 0.1]], [[0.1, 0.1]], [[-0.1, 0.1]], [[0.1]],
            [[0.1, 0.2, 0.3]], [["a", "b"]], [[0.1, NaN]], [[0.1, Inf]], Any[Any[true, 2]],
        )
            @test_throws ArgumentError _checkedValue(:EXCLUDE_Q, bad)
        end
        @test _checkedValue(:CHAINS, []) == ()
        @test _checkedValue(:CHAINS, ["A", "b"]) == ("A", "b")
        @test _checkedValue(:CHAINS, ('A', 'B')) == ("A", "B")
        for bad in ("A", ["AB"], [""], [" "], ["A", "A"], [1], [nothing], "")
            @test_throws ArgumentError _checkedValue(:CHAINS, bad)
        end
    end

    @testset "qMin is below qMax" begin
        vals(a, b) = Dict{Symbol,Any}(:Q_MIN => a, :Q_MAX => b)
        @test isempty(_relationProblems(vals(0.05, 0.3)))
        @test isempty(_relationProblems(vals(nothing, 0.3)))
        @test isempty(_relationProblems(vals(0.05, nothing)))
        @test isempty(_relationProblems(vals(nothing, nothing)))
        for (a, b) in ((0.3, 0.05), (0.1, 0.1))
            p = _relationProblems(vals(a, b))
            @test length(p) == 1 && occursin("Q_MIN", p[1]) && occursin("Q_MAX", p[1])
        end
    end

    @testset "runProject's overrides: nothing clears, :settings keeps" begin
        s = copy(_DS_DEFAULTS)
        s[:Q_MAX] = 0.3
        s[:LMAX] = 7
        _applyKeywords!(s, (; qMax = :settings, lMax = :settings, sigmaScale = nothing))
        @test s[:Q_MAX] == 0.3 && s[:LMAX] == 7 && s[:SIGMA_SCALE] == 1.0
        _applyKeywords!(s, (; qMax = nothing, lMax = nothing, qMin = 0.05))
        @test s[:Q_MAX] === nothing && s[:LMAX] === nothing && s[:Q_MIN] == 0.05
        # the rule is checked on the merged set, and `s` is unchanged on a failure
        e = errorOf(() -> _applyKeywords!(s, (; qMin = 0.5, qMax = 0.2)))
        @test e isa BAYSOL.InvalidSettingsError && s[:Q_MIN] == 0.05
        @test_throws BAYSOL.InvalidSettingsError _applyKeywords!(
            s, (; excludeQ = ((0.3, 0.2),)),
        )
        _applyKeywords!(
            s,
            (; excludeQ = ((0.1, 0.2),), chains = ("A",), model = 2,
                addHydrogens = false),
        )
        @test s[:EXCLUDE_Q] == ((0.1, 0.2),) && s[:CHAINS] == ("A",)
        @test s[:MODEL] == 2 && s[:ADD_HYDROGENS] === false
    end
end

@testset "the selection of the measured curve" begin
    q = collect(range(0.1, 1.0; length = 10))
    I = collect(1.0:10.0)
    σ = fill(0.5, 10)
    sel(; kw...) = _selectCurve(
        q, I, σ; qMin = nothing, qMax = nothing, sigmaScale = 1.0, excludeQ = (),
        kw...,
    )
    @testset "nothing to do gives the same vectors" begin
        r = sel()
        @test r.q === q && r.I === I && r.σ === σ
        @test (r.nInput, r.nCropped, r.nExcluded) == (10, 0, 0)
    end
    @testset "the range keeps both ends" begin
        r = sel(; qMin = q[3], qMax = q[8])
        @test r.q == q[3:8] && r.I == I[3:8] && r.σ == σ[3:8]
        @test (r.nCropped, r.nExcluded) == (4, 0)
        @test sel(; qMin = q[8]).q == q[8:10]
        @test sel(; qMax = q[4]).q == q[1:4]
    end
    @testset "excluded ranges, with their ends" begin
        r = sel(; excludeQ = ((q[4], q[5]), (0.95, 2.0)))
        @test r.q == q[[1, 2, 3, 6, 7, 8, 9]]
        @test r.I == I[[1, 2, 3, 6, 7, 8, 9]]
        @test (r.nCropped, r.nExcluded) == (0, 3)
        # overlapping ranges, and a range inside the cropped part counted once
        r = sel(; qMin = q[2], excludeQ = ((q[1], q[3]), (q[2], q[4])))
        @test r.q == q[5:10] && (r.nCropped, r.nExcluded) == (1, 3)
    end
    @testset "the scale multiplies the errors only" begin
        r = sel(; sigmaScale = 2.5)
        @test r.σ == 2.5 .* σ && r.q === q && r.I === I
        @test σ == fill(0.5, 10)                       # the input is untouched
        r = sel(; sigmaScale = 0.5, qMax = q[5])
        @test r.σ == fill(0.25, 5)
    end
    @testset "a bad point that is left out is never looked at" begin
        ib = copy(I)
        ib[4] = NaN
        r = _selectCurve(
            q, ib, σ; qMin = nothing, qMax = nothing, sigmaScale = 1.0,
            excludeQ = ((q[4], q[4]),),
        )
        @test length(r.q) == 9 && all(isfinite, r.I)
    end
    @testset "fewer than 3 points is an error that names the keywords" begin
        e = errorOf(() -> sel(; qMin = q[9]))
        @test e isa ArgumentError && occursin("qMin", e.msg) && occursin("qMax", e.msg)
        @test occursin("excludeQ", e.msg) && occursin("at least 3", e.msg)
        @test_throws ArgumentError sel(; qMin = q[5], qMax = q[6])
        @test_throws ArgumentError sel(; excludeQ = ((0.0, 2.0),))
        @test length(sel(; qMin = q[8]).q) == 3         # three is enough
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
                @test keepChains(file, ()) == file
                @test keepChains(file, String[]) == file
                @test readdir(cache) == before
            end
            @testset "a subset of the chains" begin
                a = keepChains(file, ("A",))
                @test dirname(a) == cache && endswith(a, ".pdb")
                @test occursin("chains.pdb"[1:(end-4)] * "_chainsA_", basename(a))
                @test count(l -> startswith(l, "ATOM"), readlines(a)) == length(atoms)
                @test !any(l -> startswith(l, "HETATM"), readlines(a))
                @test nAtoms(loadMolecule(a)) == nAtoms(loadMolecule(_DS_CRAMBIN))
                b = keepChains(file, ["B"])
                @test count(l -> startswith(l, "ATOM"), readlines(b)) == 100
                @test all(
                    l -> l[22] == 'B',
                    filter(l -> startswith(l, "ATOM"), readlines(b)),
                )
                ab = keepChains(file, ("B", "A"))
                @test count(l -> startswith(l, "ATOM"), readlines(ab)) ==
                      length(atoms) + 100
                @test ab == keepChains(file, ("A", "B"))        # the order is no matter
                # the same call is the same file (reused, not rewritten)
                @test keepChains(file, ("A",)) == a
            end
            @testset "the name follows the content" begin
                other = joinpath(mktempdir(), "chains.pdb")        # same stem, other file
                write(other, join(two[1:50], "\n") * "\nEND\n")
                @test keepChains(other, ("A",)) != keepChains(file, ("A",))
            end
            @testset "case counts, and a missing chain is an error that lists them" begin
                e = errorOf(() -> keepChains(file, ("a",)))
                @test e isa StructureSourceError && occursin("a", e.msg)
                @test occursin("A, B", e.msg) || occursin("A, B, C", e.msg)
                e = errorOf(() -> keepChains(file, ("A", "Z")))
                @test e isa StructureSourceError && occursin("Z", e.msg)
            end

            @testset "the model of a multi-model .pdb" begin
                firstAtoms = atoms
                secondAtoms = atoms[1:40]
                text =
                    join(
                        vcat(
                            ["REMARK a header", "MODEL        1"], firstAtoms, ["ENDMDL"],
                            ["MODEL        2"], secondAtoms, ["ENDMDL", "END"],
                        ), "\n") * "\n"
                multi = joinpath(cache, "multi.pdb")
                write(multi, text)
                @test resloveStruct(LocalPathSource(multi)) == abspath(multi)   # model 1
                @test resloveStruct(LocalPathSource(multi); model = 1) == abspath(multi)
                p2 = resloveStruct(LocalPathSource(multi); model = 2)
                @test p2 != abspath(multi) && occursin("multi_model2_", basename(p2))
                kept = readlines(p2)
                @test count(l -> startswith(l, "ATOM"), kept) == 40
                @test !any(l -> startswith(l, "MODEL") || startswith(l, "ENDMDL"), kept)
                @test kept[1] == "REMARK a header" && kept[end] == "END"
                @test resloveStruct(LocalPathSource(multi); model = 2) == p2
                e = errorOf(() -> resloveStruct(LocalPathSource(multi); model = 3))
                @test e isa StructureSourceError && occursin("2 model", e.msg)
                e = errorOf(() -> resloveStruct(LocalPathSource(_DS_CRAMBIN); model = 2))
                @test e isa StructureSourceError && occursin("1 model", e.msg)
                @test_throws StructureSourceError resloveStruct(
                    LocalPathSource(multi); model = 0,
                )
            end

            @testset "the model of an mmCIF" begin
                p1 = resloveStruct(LocalPathSource(_DS_ZNI))
                @test basename(p1) == "1ZNI-TEST.pdb"
                @test resloveStruct(LocalPathSource(_DS_ZNI); model = 1) == p1
                e = errorOf(() -> resloveStruct(LocalPathSource(_DS_ZNI); model = 2))
                @test e isa StructureSourceError && occursin("model 2", e.msg)
            end
        end
    end
end

@testset "seedModel with the data and structure keywords" begin
    args = _dsArgs()
    s0 = BAYSOL.seedModel(args...; addHydrogens = false)

    @testset "every keyword at its default is the call without them" begin
        sd = BAYSOL.seedModel(
            args...; addHydrogens = false, qMin = nothing, qMax = nothing,
            sigmaScale = 1.0, excludeQ = (), lMax = nothing, chains = (), model = 1,
        )
        sk = BAYSOL.seedModel(
            args...; BAYSOL.seedKeywords(_DS_DEFAULTS)..., addHydrogens = false,
        )
        for s in (sd, sk)
            @test s.θ₀ == s0.θ₀ && s.pr == s0.pr
            @test s.fw.qvals == s0.fw.qvals && s.fw.nAtoms == s0.fw.nAtoms
            @test s.fw.lMax == s0.fw.lMax && s.fw.gc == s0.fw.gc
            @test s.c1tab.cs == s0.c1tab.cs && s.c1tab.g1 == s0.c1tab.g1
            @test all(
                f -> getfield(s.wls, f) == getfield(s0.wls, f), fieldnames(typeof(s.wls)),
            )
            @test s.shannon.qRaw == s0.shannon.qRaw && s.shannon.σ == s0.shannon.σ
            # a default run records none of the new rows
            for k in ("qMin", "qMax", "sigmaScale", "excludeQ", "nQInput",
                "structureModel", "structureChains", "lmaxPinned")
                @test !haskey(s.timing.info, k)
            end
        end
        a = quiet() do
            BAYSOL.runModel(s0, 40, 20; retry = false, nChains = 2)
        end
        b = quiet() do
            BAYSOL.runModel(sd, 40, 20; retry = false, nChains = 2)
        end
        @test a[1].samples == b[1].samples && a[3][1] == b[3][1]
    end

    @testset "the q range" begin
        s = BAYSOL.seedModel(args...; addHydrogens = false, qMin = 0.05, qMax = 0.25)
        info = s.shannon
        @test all(0.05 .<= info.qRaw .<= 0.25) && length(info.qRaw) < 30
        @test info.qRaw == filter(x -> 0.05 <= x <= 0.25, args[3])
        @test all(0.05 .<= s.fw.qvals .<= 0.25)
        @test info.nChannels < s0.shannon.nChannels
        @test s.fw.lMax <= s0.fw.lMax                    # the band limit follows qMax
        # the measured grid works on the cropped curve
        y = modelOnRaw(info, info.I)
        @test length(y) == length(info.qRaw)
        M = rawInterpolation(info)
        @test size(M) == (length(info.qRaw), length(info.q))
        @test s.timing.info["qMin"] == 0.05 && s.timing.info["qMax"] == 0.25
        @test s.timing.info["nQInput"] == 30
        @test s.timing.info["nQCropped"] == 30 - length(info.qRaw)
        @test s.timing.info["nQExcluded"] == 0
        # a raw point the range dropped is not in the fit, and the others are as given
        @test length(s.fw.qvals) <= length(info.qRaw)
    end

    @testset "the excluded ranges" begin
        s = BAYSOL.seedModel(
            args...; addHydrogens = false, excludeQ = ((0.1, 0.15), (0.2, 0.22)),
        )
        q = args[3]
        gone = [x for x in q if 0.1 <= x <= 0.15 || 0.2 <= x <= 0.22]
        @test !isempty(gone) && s.shannon.qRaw == setdiff(q, gone)
        @test s.timing.info["nQExcluded"] == length(gone)
        @test s.timing.info["excludeQ"] == "0.1-0.15; 0.2-0.22"
    end

    @testset "the error scale" begin
        s = BAYSOL.seedModel(args...; addHydrogens = false, sigmaScale = 2.0)
        @test s.shannon.σ_raw == 2.0 .* args[5] && s.shannon.iRaw == args[4]
        @test s.timing.info["sigmaScale"] == 2.0
        # the binned errors are those of the scaled ones
        @test isapprox(s.shannon.σ, 2 .* s0.shannon.σ; rtol = 1e-12)
    end

    @testset "lMax pinned" begin
        s = BAYSOL.seedModel(args...; addHydrogens = false, lMax = 6)
        @test s.fw.lMax == 6 && s.timing.info["lmaxPinned"] == 1
        @test s.fw.lMax != s0.fw.lMax
    end

    @testset "addHydrogens off is recorded" begin
        @test s0.timing.info["addHydrogens"] == 0
    end

    @testset "bad values stop at once, with clear messages" begin
        t = @elapsed begin
            e = errorOf(() -> BAYSOL.seedModel(args...; qMin = 0.3, qMax = 0.1))
            @test e isa BAYSOL.InvalidSettingsError &&
                  occursin("Q_MIN = 0.3", e.problems[1])
            e = errorOf(() -> BAYSOL.seedModel(args...; sigmaScale = 0))
            @test e isa BAYSOL.InvalidSettingsError &&
                  occursin("SIGMA_SCALE", e.problems[1])
            e = errorOf(() -> BAYSOL.seedModel(args...; excludeQ = ((0.3, 0.1),)))
            @test e isa BAYSOL.InvalidSettingsError && occursin("EXCLUDE_Q", e.problems[1])
            e = errorOf(() -> BAYSOL.seedModel(args...; chains = ("AB",)))
            @test e isa BAYSOL.InvalidSettingsError && occursin("CHAINS", e.problems[1])
            e = errorOf(() -> BAYSOL.seedModel(args...; model = 0))
            @test e isa BAYSOL.InvalidSettingsError && occursin("MODEL", e.problems[1])
            # fewer than 3 points: an ArgumentError naming the keywords, not a WLSError
            e = errorOf(() -> BAYSOL.seedModel(args...; qMin = 0.29, qMax = 0.31))
            @test e isa ArgumentError && occursin("qMin", e.msg) &&
                  occursin("at least 3", e.msg)
            e = errorOf(() -> BAYSOL.seedModel(args...; excludeQ = ((0.0, 1.0),)))
            @test e isa ArgumentError && occursin("excludeQ", e.msg)
        end
        @test t < 5                      # the structure is not touched
    end

    @testset "a curve with fewer than 3 points after the binning is refused" begin
        # 3 raw points that the binning merges into one
        q = [0.020, 0.021, 0.022, 0.2, 0.25, 0.3]
        I = [100.0, 99.0, 98.0, 50.0, 20.0, 5.0]
        a = _dsArgs()
        e = errorOf(
            () -> BAYSOL.seedModel(
                a[1], a[2], q, I, 0.05 .* I, a[6], a[7], a[8];
                addHydrogens = false, qMin = 0.019, qMax = 0.0225,
            ),
        )
        @test e isa ArgumentError && occursin("at least 3", e.msg)
    end

    @testset "chains and model on a real structure" begin
        mktempdir() do cache
            withenv("BAYSOL_CACHE" => cache) do
                za = _dsArgs(LocalPathSource(_DS_ZNI))
                sall = BAYSOL.seedModel(za...; addHydrogens = false)
                sac = BAYSOL.seedModel(za...; addHydrogens = false, chains = ("A", "C"))
                @test sac.fw.nAtoms < sall.fw.nAtoms
                path = resloveStruct(LocalPathSource(_DS_ZNI))
                @test sac.fw.nAtoms ==
                      nAtoms(loadMolecule(keepChains(path, ("A", "C"))))
                @test sac.timing.info["structureChains"] == "A,C"
                e = errorOf(
                    () ->
                        BAYSOL.seedModel(za...; addHydrogens = false, chains = ("Z",)),
                )
                @test e isa StructureSourceError && occursin("Z", e.msg)
                e = errorOf(
                    () -> BAYSOL.seedModel(za...; addHydrogens = false, model = 2),
                )
                @test e isa StructureSourceError
            end
        end
    end
end
