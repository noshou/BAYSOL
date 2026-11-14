# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests for src/utils/shannon.jl: the exact point-cloud diameter,
# the Shannon binning of a measured curve, the model curve on the
# measured grid, and the residual-structure statistics.
#
# `bruteDiameter` below is the plain O(n²) farthest pair, written independently of the
# convex-hull path in `cloudDiameter`, so agreement between the two is a real cross-check.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using Statistics
using LinearAlgebra
using BAYSOL.Shannon: ShannonInfo, SHANNON_REBIN, BIN_BIAS_MAX, cloudDiameter, autoLmax,
    shannonData, modelOnRaw, rawInterpolation,
    residualStructure, binBiasRatio
using BAYSOL.BulkElectronDensity: NonBiological, Solute
using BAYSOL.Scattering: forwardCache, hydration
using BAYSOL.Geometry: sasa
using BAYSOL.MolecularStructure: LocalPathSource, loadMolecule, coordsCartesian

bruteDiameter(P) = maximum(
    normIj for normIj in
    (sqrt(sum(abs2, P[:, i] .- P[:, j])) for i in 1:size(P, 2) for j in 1:size(P, 2))
)

@testset "Shannon" begin

    @testset "cloudDiameter" begin
        rng = MersenneTwister(1)
        @testset "random clouds agree with the brute-force farthest pair" begin
            for n in (4, 5, 20, 200, 1000)
                P = 30 .* randn(rng, 3, n)
                @test checkFloat(cloudDiameter(P), bruteDiameter(P))
            end
        end
        @testset "a real structure (crambin, 327 atoms)" begin
            P = coordsCartesian(
                loadMolecule(
                    joinpath(
                        @__DIR__,
                        "..",
                        "..",
                        "fixtures",
                        "molecules",
                        "1CRN-TEST.pdb",
                    ),
                ),
            )
            @test checkFloat(cloudDiameter(P), bruteDiameter(P))
        end
        @testset "known shapes" begin
            corners = hcat(
                [[x, y, z] for x in (0.0, 2.0) for y in (0.0, 2.0) for z in (0.0, 2.0)]...,
            )
            @test checkFloat(cloudDiameter(corners), 2sqrt(3))
            sphere = let v = randn(rng, 3, 2000)
                50 .* v ./ sqrt.(sum(abs2, v; dims = 1))
            end
            @test 99.9 < cloudDiameter(sphere) ≤ 100 + DEFAULT_ATOL
        end
        @testset "degenerate clouds have no 3-D hull and fall back to pairs" begin
            # collinear
            @test checkFloat(cloudDiameter(Float64[0 1 2 3 4; 0 0 0 0 0; 0 0 0 0 0]), 4.0)
            planar = vcat(randn(rng, 2, 30), zeros(1, 30))
            # coplanar
            @test checkFloat(cloudDiameter(planar), bruteDiameter(planar))
            # repeated point
            @test cloudDiameter(fill(1.5, 3, 6)) == 0.0
            # two points
            @test checkFloat(cloudDiameter(Float64[0 3; 0 4; 0 0]), 5.0)
            # one point
            @test cloudDiameter(reshape([1.0, 2.0, 3.0], 3, 1)) == 0.0
        end
        @testset "invalid shapes" begin
            @test_throws ArgumentError cloudDiameter(zeros(2, 5))
            @test_throws ArgumentError cloudDiameter(zeros(3, 0))
        end
    end

    @testset "autoLmax" begin
        @test autoLmax(100.0, 0.3) == 30
        @test autoLmax(100.0, 0.301) == 31            # rounded up
        @test autoLmax(1.0, 0.01) == 1                # at least 1
        @test_throws DomainError autoLmax(0.0, 0.3)
        @test_throws DomainError autoLmax(100.0, -0.1)
        @test_throws DomainError autoLmax(NaN, 0.3)
    end

    @testset "shannonData" begin
        # D = π/0.01 makes the bin width π/(k·D) = 0.01/k
        # exactly: k = 1 → bins of 0.01 from qMin.
        D = π / 0.01
        q = [0.001, 0.004, 0.009, 0.012, 0.018, 0.031]
        I = [10.0, 12.0, 14.0, 9.0, 7.0, 3.0]
        σ = [1.0, 2.0, 1.0, 0.5, 0.5, 1.0]

        @testset "inverse-variance bins" begin
            info = shannonData(q, I, σ; D, rebin = 1, maxBinBias = Inf)
            # bins from qMin = 0.001: [0.001,0.011) holds points
            # 1-3; [0.011,0.021) points 4-5; [0.031,0.041) point 6
            w1 = 1 ./ σ[1:3] .^ 2
            w2 = 1 ./ σ[4:5] .^ 2
            @test info.q ≈ [sum(w1 .* q[1:3]) / sum(w1), sum(w2 .* q[4:5]) / sum(w2), q[6]]
            @test info.I ≈ [sum(w1 .* I[1:3]) / sum(w1), sum(w2 .* I[4:5]) / sum(w2), I[6]]
            @test info.σ ≈ [1 / sqrt(sum(w1)), 1 / sqrt(sum(w2)), σ[6]]
            @test info.bin == [1, 1, 1, 2, 2, 3]
            @test info.rebin == 1 && info.nNonpositive == 0
            # raw data kept as given
            @test info.qRaw == q && info.iRaw == I && info.σ_raw == σ
            @test checkFloat(info.nChannels, (info.q[end] - info.q[1]) * D / π)
        end

        @testset "narrower bins than the data's spacing change nothing" begin
            info = shannonData(q, I, σ; D, rebin = 1000, maxBinBias = Inf)
            @test info.q == q && info.I == I && info.σ == σ && info.bin == 1:6
        end

        @testset "rebin = nothing only filters" begin
            info = shannonData(q, I, σ; D, rebin = nothing)
            @test info.q == q && info.rebin == 0 && info.bin == 1:6
        end

        # …of a linear fit)
        @testset "binning conserves Σ w·I and Σ w (the sufficient statistics" begin
            rng = MersenneTwister(2)
            qq = sort(rand(rng, 500) .* 0.3)
            σσ = 0.5 .+ rand(rng, 500)
            ii = 5 .+ randn(rng, 500)
            info = shannonData(qq, ii, σσ; D = 80.0, rebin = 4, maxBinBias = Inf)
            @test checkFloat(sum(info.I ./ info.σ .^ 2), sum(ii ./ σσ .^ 2); atol = 1e-8)
            @test checkFloat(sum(1 ./ info.σ .^ 2), sum(1 ./ σσ .^ 2); atol = 1e-8)
            @test issorted(info.q)
            Δ = π / (4 * 80.0)
            # every point is within a bin width of its bin
            @test all(abs(info.q[info.bin[i]] - qq[i]) < Δ for i in eachindex(qq))
        end

        @testset "non-positive bins are dropped and the bin map follows" begin
            # the middle bin averages negative
            ineg = [10.0, 12.0, 14.0, -9.0, -7.0, 3.0]
            info = shannonData(q, ineg, σ; D, rebin = 1, maxBinBias = Inf)
            @test info.nNonpositive == 1
            @test length(info.q) == 2 && info.I == [info.I[1], 3.0]
            @test info.bin == [1, 1, 1, 0, 0, 2]
        end

        @testset "dropNonpositive = false keeps the bins with non-positive intensity" begin
            ineg = [10.0, 12.0, 14.0, -9.0, -7.0, 3.0]
            info = shannonData(
                q,
                ineg,
                σ;
                D,
                rebin = 1,
                maxBinBias = Inf,
                dropNonpositive = false,
            )
            @test info.nNonpositive == 0 && length(info.q) == 3 &&
                  info.bin == [1, 1, 1, 2, 2, 3]
            @test info.I[2] < 0
            raw = shannonData(q, ineg, σ; D, rebin = nothing, dropNonpositive = false)
            @test raw.I == ineg && raw.bin == 1:6
        end

        @testset "binBiasRatio" begin
            info = shannonData(q, I, σ; D, rebin = 4, maxBinBias = Inf)
            @test checkFloat(
                binBiasRatio(info),
                π^2 / (96 * 16) / minimum(info.σ ./ info.I),
            )
            @test isnan(binBiasRatio(shannonData(q, I, σ; D, rebin = nothing)))
            # 1000× more precise points: the ratio grows by ≥ 1000/√n
            tight = shannonData(q, I, σ ./ 1000; D, rebin = 1, maxBinBias = Inf)
            @test binBiasRatio(tight) >
                  100 *
                  binBiasRatio(shannonData(q, I, σ; D, rebin = 1, maxBinBias = Inf))
        end

        @testset "band limit" begin
            info = shannonData(q, I, σ; D = 100.0, maxBinBias = Inf)
            @test info.lMax == autoLmax(100.0, maximum(info.q))
            @test info.rebin == SHANNON_REBIN
            @test shannonData(q, I, σ; D = 100.0, lMax = 7).lMax == 7
        end

        @testset "invalid input" begin
            @test_throws DomainError shannonData(q, I[1:5], σ; D)
            @test_throws ArgumentError shannonData(Float64[], Float64[], Float64[]; D)
            @test_throws DomainError shannonData(q, I, [σ[1:5]; 0.0]; D)
            @test_throws DomainError shannonData(q, [I[1:5]; NaN], σ; D)
            @test_throws DomainError shannonData(q, I, σ; D = -1.0)
            @test_throws DomainError shannonData(q, I, σ; D, rebin = 0)
            @test_throws ArgumentError shannonData(q, -abs.(I), σ; D)
        end
    end

    @testset "rawInterpolation: one matrix for every curve" begin
        q = collect(0.0:0.01:0.2)
        I = 1 .+ q
        σ = fill(0.1, length(q))
        info = shannonData(q, I, σ; D = 50.0, rebin = 3, maxBinBias = Inf)
        M = rawInterpolation(info)
        @test size(M) == (length(info.qRaw), length(info.q))
        rng = Xoshiro(4)
        for _ in 1:5
            y = 5 .+ rand(rng, length(info.q))
            @test M * y ≈ modelOnRaw(info, y) rtol = 1e-10
        end
        # reduced χ² of many curves at once = the per-curve function
        Y = 5 .+ rand(rng, length(info.q), 40)
        allAtOnce = BAYSOL.Pipeline._chisqMeasuredAll(info, Y)
        oneByOne = [BAYSOL.Pipeline._chisqMeasured(info, Y[:, j]) for j in 1:40]
        @test allAtOnce ≈ oneByOne rtol = 1e-10
        # more columns than one block: the blocks join up
        wide = repeat(Y, 1, 60)
        wideChi2 = BAYSOL.Pipeline._chisqMeasuredAll(info, wide)
        @test wideChi2 ≈ repeat(oneByOne, 60) rtol = 1e-10
        two = shannonData([0.1, 0.2, 0.3], [1.0, 2.0, 3.0], [0.1, 0.1, 0.1];
            D = 5.0, rebin = nothing)
        @test rawInterpolation(two) * [1.0, 2.0, 3.0] ≈ [1.0, 2.0, 3.0]
    end

    @testset "modelOnRaw" begin
        q = collect(0.0:0.01:0.2)
        I = 1 .+ q
        σ = fill(0.1, length(q))
        info = shannonData(q, I, σ; D = 50.0, rebin = 1, maxBinBias = Inf)
        f(x) = 3 .+ 2 .* x .- 40 .* x .^ 2 .+ 300 .* x .^ 3
        # cubics are interpolated exactly (also at the ends)
        @test modelOnRaw(info, f(info.q)) ≈ f(info.qRaw)
        two = shannonData(
            [0.1, 0.2, 0.3],
            [1.0, 2.0, 3.0],
            [0.1, 0.1, 0.1];
            D = 5.0,
            rebin = nothing,
        )
        # fewer than four nodes: linear
        @test modelOnRaw(two, [1.0, 2.0, 3.0]) ≈ [1.0, 2.0, 3.0]
        @test_throws DimensionMismatch modelOnRaw(info, zeros(length(info.q) + 1))
        oneBin = shannonData(
            [0.1, 0.101],
            [1.0, 1.0],
            [0.1, 0.1];
            D = 5.0,
            rebin = 1,
            maxBinBias = Inf,
        )
        @test_throws ArgumentError modelOnRaw(oneBin, [1.0])

        @testset "against the forward model on the measured grid (crambin)" begin
            mol = loadMolecule(
                joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb"),
            )
            D = cloudDiameter(coordsCartesian(mol)) + 6.0
            qraw = collect(range(0.01, 0.30; length = 150))
            lMax = autoLmax(D, maximum(qraw))
            fwRaw = forwardCache(mol, qraw, lMax, 9000.0; chunk = UInt64(64))
            yRaw = referenceIntensity(
                fwRaw,
                1.0,
                0.0,
                CRYSOL_SOLVENT_DENSITY,
                (1.0, 0.0, -0.5),
            )
            info = shannonData(
                qraw,
                yRaw,
                0.01 .* yRaw;
                D,
                rebin = SHANNON_REBIN,
                maxBinBias = Inf,
                lMax,
            )
            # the binning really coarsened the grid
            @test length(info.q) < length(qraw)
            fwB = forwardCache(mol, info.q, lMax, 9000.0; chunk = UInt64(64))
            yB = referenceIntensity(
                fwB,
                1.0,
                0.0,
                CRYSOL_SOLVENT_DENSITY,
                (1.0, 0.0, -0.5),
            )
            rel = maximum(abs.(modelOnRaw(info, yB) .- yRaw) ./ yRaw)
            @test rel < 3e-4
        end
    end

    @testset "residualStructure" begin
        rng = MersenneTwister(3)
        white = randn(rng, 4000)
        rs = residualStructure(white)
        @test abs(rs.lag1) < 4 / sqrt(4000) && abs(rs.runsZ) < 4
        # strongly autocorrelated
        slow = cumsum(randn(rng, 4000)) ./ 20
        rs = residualStructure(slow)
        @test rs.lag1 > 0.9 && rs.runsZ < -10
        alt = repeat([1.0, -1.0], 50)
        rs = residualStructure(alt)
        @test checkFloat(rs.lag1, -0.99) && rs.runsZ > 5
        # one sign: no runs statistic
        @test isnan(residualStructure([1.0, 2.0, 3.0]).runsZ)
        @test residualStructure(zeros(5)).lag1 == 0.0
        @test_throws ArgumentError residualStructure([1.0, 2.0])
    end

    @testset "seedModel → runModel → the run sheet on crambin" begin
        path = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")
        solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
        # synthetic data on a dense grid; the model that
        # made it is the forward model on the raw grid
        mol = loadMolecule(path)
        d0 = cloudDiameter(coordsCartesian(mol)) + 6.0
        qraw = collect(range(0.01, 0.25; length = 120))
        fw = forwardCache(mol, qraw, autoLmax(d0, 0.25), 9000.0; chunk = UInt64(64))
        Ī =
            1.7 .*
            referenceIntensity(fw, 1.0, 0.0, CRYSOL_SOLVENT_DENSITY, (1.0, 0.0, -0.5)) .+
            0.3
        σ = 0.02 .* abs.(Ī)
        Random.seed!(7)
        iObs = Ī .+ σ .* randn(length(Ī))

        Random.seed!(1)
        s = BAYSOL.seedModel(
            LocalPathSource(path),
            9000.0,
            qraw,
            iObs,
            σ,
            7.0,
            0.1,
            solutes;
            addHydrogens = false,
        )
        sh = s.shannon
        @test sh isa ShannonInfo && sh.rebin == SHANNON_REBIN && sh.qRaw == qraw
        @test s.fw.qvals == sh.q && s.fw.lMax == sh.lMax == autoLmax(sh.D, maximum(sh.q))
        # the grid really was coarsened
        @test length(sh.q) < length(qraw)
        # D is the diameter of the whole scatterer cloud: atoms
        # and hydration beads, hence wider than the atoms
        @test sh.D > cloudDiameter(coordsCartesian(mol)) + 3
        @test s.timing.info["nQRaw"] == length(qraw) && s.timing.info["D"] == sh.D

        # an explicit lMax and no binning are honoured
        s0 = BAYSOL.seedModel(LocalPathSource(path), 9000.0, qraw, iObs, σ, 7.0, 0.1,
            solutes;
            addHydrogens = false, rebin = nothing, lMax = 5)
        @test s0.fw.lMax == 5 && s0.fw.qvals == qraw && s0.shannon.rebin == 0

        # the precomputed accessible surface gives the
        # same hydration shell as computing it inside
        shell = sasa(mol)
        h1 = hydration(mol, qraw[1:6], 4, UInt64(8))
        h2 = hydration(mol, qraw[1:6], 4, UInt64(8); shell = shell)
        @test h1.convex ≈ h2.convex && h1.concave ≈ h2.concave && h1.cavity ≈ h2.cavity

        R = BAYSOL.Pipeline
        @test (R.N_ADAPT, R.N_DRAWS) == (300, 700)
        # nSamples / nAdapt default to the constants
        @test hasmethod(BAYSOL.runModel, Tuple{typeof(s)})
        res = BAYSOL.runModel(s, 120, 60; retry = false)
        mapParams = res[3][1]
        # the reported χ² is the one on the measured points
        # (not the binned fit's own), n − 3 degrees of freedom
        fitres = res[1]
        sh = s.shannon
        yMap = fitres.curves[:, argmax(getproperty.(fitres.stats, :log_density))]
        rMap = (sh.iRaw .- modelOnRaw(sh, yMap)) ./ sh.σ_raw
        @test mapParams["chisqRed"] ≈ sum(abs2, rMap) / (length(rMap) - 3)
        # residual statistics are a dev tool
        @test !haskey(mapParams, "residLag1") && !haskey(mapParams, "chisqRedRaw")
        # the run sheet carries the binning and the sampler's statistics
        sheets = BAYSOL.Pipeline._summarySheets(res; nAtoms = s.fw.nAtoms)
        run = Dict(zip(sheets[1].cols[2], sheets[1].cols[3]))   # name | value
        for key in ("nAtoms", "nQRaw", "rebinChannels", "channels", "divergenceRate")
            @test haskey(run, key)
        end
        @test run["nQRaw"] == length(sh.qRaw) && run["rebinFitted"] == length(sh.q)
        @test [x.name for x in sheets][2:3] == ["map", "quantiles2sigma"]
        # the timing table: the wall clock first, the fit and plot timings add up to it
        tbl = BAYSOL.Pipeline._timingTable(res[1].timing, BAYSOL.Runtime.tick())
        @test startswith(tbl.rows[1].name, "wall clock")
        @test tbl.fit + tbl.plot ≈ tbl.rows[1].secs
    end
    # …acceptable
    @testset "shannonData raises the rebin until the binning's worst-case bias is" begin
        D = 100.0
        q = collect(range(0.01, 0.30; length = 2000))
        I = 1000 .* exp.(-(q .* D / 3) .^ 2 ./ 3) .+ 1.0
        # a precise curve (0.01 % errors): at the default 12
        # bins per channel the bound is far above BIN_BIAS_MAX
        σ_precise = 1e-4 .* I
        pinned = shannonData(q, I, σ_precise; D, rebin = 12, maxBinBias = Inf)
        @test pinned.rebin == 12 && binBiasRatio(pinned) > BIN_BIAS_MAX
        auto = shannonData(q, I, σ_precise; D, rebin = 12)
        @test auto.rebin > 12 && length(auto.q) > length(pinned.q)
        @test auto.rebin == 0 || binBiasRatio(auto) ≤ BIN_BIAS_MAX
        # a coarse curve (5 % errors) keeps the requested rebin
        σ_coarse = 5e-2 .* I
        @test shannonData(q, I, σ_coarse; D, rebin = 12).rebin == 12
        # more precise than any binning can use: the curve is fitted as measured
        σ_extreme = 1e-9 .* I
        @test shannonData(q, I, σ_extreme; D, rebin = 12).rebin == 0
        # a threshold of Inf (or a loose one) never
        # raises it; a tighter one raises it further
        @test shannonData(q, I, σ_precise; D, rebin = 12, maxBinBias = 1e6).rebin == 12
        tighter = shannonData(q, I, σ_precise; D, rebin = 12, maxBinBias = 0.1)
        @test tighter.rebin ≥ auto.rebin
        # the bin map, band limit and channel count are those of the binning that was kept
        @test length(auto.bin) == length(q) && maximum(auto.bin) == length(auto.q)
        @test auto.lMax == autoLmax(D, maximum(auto.q))
    end

end
