# SPDX-License-Identifier: LGPL-2.1-or-later

# Tests for src/Utils/Shannon.jl: the exact point-cloud diameter, the Shannon binning of a measured
# curve, the model curve on the measured grid, and the residual-structure statistics.
#
# `brute_diameter` below is the plain O(n²) farthest pair, written independently of the convex-hull path
# in `cloud_diameter`, so agreement between the two is a real cross-check.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using Statistics
using LinearAlgebra
using BAYSOL.Shannon: ShannonInfo, SHANNON_REBIN, BIN_BIAS_MAX, cloud_diameter, auto_lmax, shannon_data, model_on_raw,
    residual_structure, bin_bias_ratio
using BAYSOL.Inference: NonBiological, Solute
using BAYSOL.Scattering: forward_cache, hydration
using BAYSOL.SASA: sasa
using BAYSOL.MolecularStructure: LocalPathSource, load_molecule, coords_cartesian

brute_diameter(P) = maximum(norm_ij for norm_ij in
    (sqrt(sum(abs2, P[:, i] .- P[:, j])) for i in 1:size(P, 2) for j in 1:size(P, 2)))

@testset "Shannon" begin

    @testset "cloud_diameter" begin
        rng = MersenneTwister(1)
        @testset "random clouds agree with the brute-force farthest pair" begin
            for n in (4, 5, 20, 200, 1000)
                P = 30 .* randn(rng, 3, n)
                @test check_float(cloud_diameter(P), brute_diameter(P))
            end
        end
        @testset "a real structure (crambin, 327 atoms)" begin
            P = coords_cartesian(load_molecule(joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")))
            @test check_float(cloud_diameter(P), brute_diameter(P))
        end
        @testset "known shapes" begin
            corners = hcat([[x, y, z] for x in (0.0, 2.0) for y in (0.0, 2.0) for z in (0.0, 2.0)]...)
            @test check_float(cloud_diameter(corners), 2sqrt(3))
            sphere = let v = randn(rng, 3, 2000); 50 .* v ./ sqrt.(sum(abs2, v; dims = 1)) end
            @test 99.9 < cloud_diameter(sphere) ≤ 100 + DEFAULT_ATOL
        end
        @testset "degenerate clouds have no 3-D hull and fall back to pairs" begin
            @test check_float(cloud_diameter(Float64[0 1 2 3 4; 0 0 0 0 0; 0 0 0 0 0]), 4.0)           # collinear
            planar = vcat(randn(rng, 2, 30), zeros(1, 30))
            @test check_float(cloud_diameter(planar), brute_diameter(planar))                          # coplanar
            @test cloud_diameter(fill(1.5, 3, 6)) == 0.0                                                # repeated point
            @test check_float(cloud_diameter(Float64[0 3; 0 4; 0 0]), 5.0)                              # two points
            @test cloud_diameter(reshape([1.0, 2.0, 3.0], 3, 1)) == 0.0                                 # one point
        end
        @testset "invalid shapes" begin
            @test_throws ArgumentError cloud_diameter(zeros(2, 5))
            @test_throws ArgumentError cloud_diameter(zeros(3, 0))
        end
    end

    @testset "auto_lmax" begin
        @test auto_lmax(100.0, 0.3) == 30
        @test auto_lmax(100.0, 0.301) == 31            # rounded up
        @test auto_lmax(1.0, 0.01) == 1                # at least 1
        @test_throws DomainError auto_lmax(0.0, 0.3)
        @test_throws DomainError auto_lmax(100.0, -0.1)
        @test_throws DomainError auto_lmax(NaN, 0.3)
    end

    @testset "shannon_data" begin
        # D = π/0.01 makes the bin width π/(k·D) = 0.01/k exactly: k = 1 → bins of 0.01 from q_min.
        D = π / 0.01
        q = [0.001, 0.004, 0.009, 0.012, 0.018, 0.031]
        I = [10.0, 12.0, 14.0, 9.0, 7.0, 3.0]
        σ = [1.0, 2.0, 1.0, 0.5, 0.5, 1.0]

        @testset "inverse-variance bins" begin
            info = shannon_data(q, I, σ; D, rebin = 1, max_bin_bias = Inf)
            # bins from q_min = 0.001: [0.001,0.011) holds points 1-3; [0.011,0.021) points 4-5; [0.031,0.041) point 6
            w1 = 1 ./ σ[1:3] .^ 2; w2 = 1 ./ σ[4:5] .^ 2
            @test info.q ≈ [sum(w1 .* q[1:3]) / sum(w1), sum(w2 .* q[4:5]) / sum(w2), q[6]]
            @test info.I ≈ [sum(w1 .* I[1:3]) / sum(w1), sum(w2 .* I[4:5]) / sum(w2), I[6]]
            @test info.σ ≈ [1 / sqrt(sum(w1)), 1 / sqrt(sum(w2)), σ[6]]
            @test info.bin == [1, 1, 1, 2, 2, 3]
            @test info.rebin == 1 && info.n_nonpositive == 0
            @test info.q_raw == q && info.I_raw == I && info.σ_raw == σ        # raw data kept as given
            @test check_float(info.n_channels, (info.q[end] - info.q[1]) * D / π)
        end

        @testset "narrower bins than the data's spacing change nothing" begin
            info = shannon_data(q, I, σ; D, rebin = 1000, max_bin_bias = Inf)
            @test info.q == q && info.I == I && info.σ == σ && info.bin == 1:6
        end

        @testset "rebin = nothing only filters" begin
            info = shannon_data(q, I, σ; D, rebin = nothing)
            @test info.q == q && info.rebin == 0 && info.bin == 1:6
        end

        @testset "binning conserves Σ w·I and Σ w (the sufficient statistics of a linear fit)" begin
            rng = MersenneTwister(2)
            qq = sort(rand(rng, 500) .* 0.3); σσ = 0.5 .+ rand(rng, 500); II = 5 .+ randn(rng, 500)
            info = shannon_data(qq, II, σσ; D = 80.0, rebin = 4, max_bin_bias = Inf)
            @test check_float(sum(info.I ./ info.σ .^ 2), sum(II ./ σσ .^ 2); atol = 1e-8)
            @test check_float(sum(1 ./ info.σ .^ 2), sum(1 ./ σσ .^ 2); atol = 1e-8)
            @test issorted(info.q)
            Δ = π / (4 * 80.0)
            @test all(abs(info.q[info.bin[i]] - qq[i]) < Δ for i in eachindex(qq))   # every point is within a bin width of its bin
        end

        @testset "non-positive bins are dropped and the bin map follows" begin
            Ineg = [10.0, 12.0, 14.0, -9.0, -7.0, 3.0]                  # the middle bin averages negative
            info = shannon_data(q, Ineg, σ; D, rebin = 1, max_bin_bias = Inf)
            @test info.n_nonpositive == 1
            @test length(info.q) == 2 && info.I == [info.I[1], 3.0]
            @test info.bin == [1, 1, 1, 0, 0, 2]
        end

        @testset "drop_nonpositive = false keeps the bins with non-positive intensity" begin
            Ineg = [10.0, 12.0, 14.0, -9.0, -7.0, 3.0]
            info = shannon_data(q, Ineg, σ; D, rebin = 1, max_bin_bias = Inf, drop_nonpositive = false)
            @test info.n_nonpositive == 0 && length(info.q) == 3 && info.bin == [1, 1, 1, 2, 2, 3]
            @test info.I[2] < 0
            raw = shannon_data(q, Ineg, σ; D, rebin = nothing, drop_nonpositive = false)
            @test raw.I == Ineg && raw.bin == 1:6
        end

        @testset "bin_bias_ratio" begin
            info = shannon_data(q, I, σ; D, rebin = 4, max_bin_bias = Inf)
            @test check_float(bin_bias_ratio(info), π^2 / (96 * 16) / minimum(info.σ ./ info.I))
            @test isnan(bin_bias_ratio(shannon_data(q, I, σ; D, rebin = nothing)))
            tight = shannon_data(q, I, σ ./ 1000; D, rebin = 1, max_bin_bias = Inf)           # 1000× more precise points: the ratio grows by ≥ 1000/√n
            @test bin_bias_ratio(tight) > 100 * bin_bias_ratio(shannon_data(q, I, σ; D, rebin = 1, max_bin_bias = Inf))
        end

        @testset "band limit" begin
            info = shannon_data(q, I, σ; D = 100.0, max_bin_bias = Inf)
            @test info.lMax == auto_lmax(100.0, maximum(info.q))
            @test info.rebin == SHANNON_REBIN
            @test shannon_data(q, I, σ; D = 100.0, lMax = 7).lMax == 7
        end

        @testset "invalid input" begin
            @test_throws DomainError shannon_data(q, I[1:5], σ; D)
            @test_throws ArgumentError shannon_data(Float64[], Float64[], Float64[]; D)
            @test_throws DomainError shannon_data(q, I, [σ[1:5]; 0.0]; D)
            @test_throws DomainError shannon_data(q, [I[1:5]; NaN], σ; D)
            @test_throws DomainError shannon_data(q, I, σ; D = -1.0)
            @test_throws DomainError shannon_data(q, I, σ; D, rebin = 0)
            @test_throws ArgumentError shannon_data(q, -abs.(I), σ; D)
        end
    end

    @testset "model_on_raw" begin
        q = collect(0.0:0.01:0.2); I = 1 .+ q; σ = fill(0.1, length(q))
        info = shannon_data(q, I, σ; D = 50.0, rebin = 1, max_bin_bias = Inf)
        f(x) = 3 .+ 2 .* x .- 40 .* x .^ 2 .+ 300 .* x .^ 3
        @test model_on_raw(info, f(info.q)) ≈ f(info.q_raw)                 # cubics are interpolated exactly (also at the ends)
        two = shannon_data([0.1, 0.2, 0.3], [1.0, 2.0, 3.0], [0.1, 0.1, 0.1]; D = 5.0, rebin = nothing)
        @test model_on_raw(two, [1.0, 2.0, 3.0]) ≈ [1.0, 2.0, 3.0]          # fewer than four nodes: linear
        @test_throws DimensionMismatch model_on_raw(info, zeros(length(info.q) + 1))
        one_bin = shannon_data([0.1, 0.101], [1.0, 1.0], [0.1, 0.1]; D = 5.0, rebin = 1, max_bin_bias = Inf)
        @test_throws ArgumentError model_on_raw(one_bin, [1.0])

        @testset "against the forward model on the measured grid (crambin)" begin
            mol = load_molecule(joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb"))
            D = cloud_diameter(coords_cartesian(mol)) + 6.0
            qraw = collect(range(0.01, 0.30; length = 150))
            lMax = auto_lmax(D, maximum(qraw))
            fw_raw = forward_cache(mol, qraw, lMax, 9000.0; chunk = UInt64(64))
            y_raw = reference_intensity(fw_raw, 1.0, 0.0, CRYSOL_SOLVENT_DENSITY, (1.0, 0.0, -0.5))
            info = shannon_data(qraw, y_raw, 0.01 .* y_raw; D, rebin = SHANNON_REBIN, max_bin_bias = Inf, lMax)
            @test length(info.q) < length(qraw)                              # the binning really coarsened the grid
            fw_b = forward_cache(mol, info.q, lMax, 9000.0; chunk = UInt64(64))
            y_b = reference_intensity(fw_b, 1.0, 0.0, CRYSOL_SOLVENT_DENSITY, (1.0, 0.0, -0.5))
            rel = maximum(abs.(model_on_raw(info, y_b) .- y_raw) ./ y_raw)
            @test rel < 3e-4
        end
    end

    @testset "residual_structure" begin
        rng = MersenneTwister(3)
        white = randn(rng, 4000)
        rs = residual_structure(white)
        @test abs(rs.lag1) < 4 / sqrt(4000) && abs(rs.runs_z) < 4
        slow = cumsum(randn(rng, 4000)) ./ 20                                # strongly autocorrelated
        rs = residual_structure(slow)
        @test rs.lag1 > 0.9 && rs.runs_z < -10
        alt = repeat([1.0, -1.0], 50)
        rs = residual_structure(alt)
        @test check_float(rs.lag1, -0.99) && rs.runs_z > 5
        @test isnan(residual_structure([1.0, 2.0, 3.0]).runs_z)              # one sign: no runs statistic
        @test residual_structure(zeros(5)).lag1 == 0.0
        @test_throws ArgumentError residual_structure([1.0, 2.0])
    end

    @testset "seed_model → run_model → write_report on crambin" begin
        path = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")
        solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
        # synthetic data on a dense grid; the model that made it is the forward model on the raw grid
        mol = load_molecule(path)
        D0 = cloud_diameter(coords_cartesian(mol)) + 6.0
        qraw = collect(range(0.01, 0.25; length = 120))
        fw = forward_cache(mol, qraw, auto_lmax(D0, 0.25), 9000.0; chunk = UInt64(64))
        Ī = 1.7 .* reference_intensity(fw, 1.0, 0.0, CRYSOL_SOLVENT_DENSITY, (1.0, 0.0, -0.5)) .+ 0.3
        σ = 0.02 .* abs.(Ī)
        Random.seed!(7)
        I_obs = Ī .+ σ .* randn(length(Ī))

        Random.seed!(1)
        s = BAYSOL.seed_model(LocalPathSource(path), 9000.0, qraw, I_obs, σ, 7.0, 0.1, solutes; add_hydrogens = false)
        sh = s.shannon
        @test sh isa ShannonInfo && sh.rebin == SHANNON_REBIN && sh.q_raw == qraw
        @test s.fw.qvals == sh.q && s.fw.lMax == sh.lMax == auto_lmax(sh.D, maximum(sh.q))
        @test length(sh.q) < length(qraw)                                    # the grid really was coarsened
        # D is the diameter of the whole scatterer cloud: atoms and hydration beads, hence wider than the atoms
        @test sh.D > cloud_diameter(coords_cartesian(mol)) + 3
        @test s.timing.info["n_q_raw"] == length(qraw) && s.timing.info["D"] == sh.D

        # an explicit lMax and no binning are honoured
        s0 = BAYSOL.seed_model(LocalPathSource(path), 9000.0, qraw, I_obs, σ, 7.0, 0.1, solutes;
                               add_hydrogens = false, rebin = nothing, lMax = 5)
        @test s0.fw.lMax == 5 && s0.fw.qvals == qraw && s0.shannon.rebin == 0

        # the precomputed accessible surface gives the same hydration shell as computing it inside
        shell = sasa(mol)
        h1 = hydration(mol, qraw[1:6], 4, UInt64(8))
        h2 = hydration(mol, qraw[1:6], 4, UInt64(8); shell = shell)
        @test h1.convex ≈ h2.convex && h1.concave ≈ h2.concave && h1.cavity ≈ h2.cavity

        R = BAYSOL.Pipeline
        @test (R.DEFAULT_N_ADAPT, R.DEFAULT_N_DRAWS, R.DEFAULT_N_SAMPLES) == (300, 700, 1000)
        @test hasmethod(BAYSOL.run_model, Tuple{typeof(s)})                 # n_samples / n_adapt default to the constants
        res = BAYSOL.run_model(s, 120, 60)
        map_params = res[3][1]
        # the reported χ² is the one on the measured points (not the binned fit's own), n − 3 degrees of freedom
        fitres = res[1]
        sh = s.shannon
        y_map = fitres.curves[:, argmax(getproperty.(fitres.stats, :log_density))]
        r_map = (sh.I_raw .- model_on_raw(sh, y_map)) ./ sh.σ_raw
        @test map_params["chisq_red"] ≈ sum(abs2, r_map) / (length(r_map) - 3)
        @test !haskey(map_params, "resid_lag1") && !haskey(map_params, "chisq_red_raw")   # residual statistics are a dev tool
        buf = IOBuffer()
        BAYSOL.write_report(buf, res; n_atoms = s.fw.n_atoms)
        txt = String(take!(buf))
        for needle in ("=== Run ===", "n_q_raw", "rebin", "channels", "=== Diagnostics ===", "divergence_rate")
            @test occursin(needle, txt)
        end
        @test !occursin("Residuals at the MAP", txt) && !occursin("=== Data (Shannon) ===", txt)
        @test occursin(r"^χ²\s+= "m, txt)                                  # the line the Tcl report parser reads is unchanged
        # section order: Run, Diagnostics, MAP, Quantiles, z-scores, Timing
        order = [first(findfirst(h, txt)) for h in ("=== Run ===", "=== Diagnostics ===", "=== MAP ===", "=== Quantiles", "=== Standard deviations", "=== Timing ===")]
        @test issorted(order)
    end
    @testset "shannon_data raises the rebin until the binning's worst-case bias is acceptable" begin
        D = 100.0
        q = collect(range(0.01, 0.30; length = 2000))
        I = 1000 .* exp.(-(q .* D / 3) .^ 2 ./ 3) .+ 1.0
        # a precise curve (0.01 % errors): at the default 12 bins per channel the bound is far above BIN_BIAS_MAX
        σ_precise = 1e-4 .* I
        pinned = shannon_data(q, I, σ_precise; D, rebin = 12, max_bin_bias = Inf)
        @test pinned.rebin == 12 && bin_bias_ratio(pinned) > BIN_BIAS_MAX
        auto = shannon_data(q, I, σ_precise; D, rebin = 12)
        @test auto.rebin > 12 && length(auto.q) > length(pinned.q)
        @test auto.rebin == 0 || bin_bias_ratio(auto) ≤ BIN_BIAS_MAX
        # a coarse curve (5 % errors) keeps the requested rebin
        σ_coarse = 5e-2 .* I
        @test shannon_data(q, I, σ_coarse; D, rebin = 12).rebin == 12
        # more precise than any binning can use: the curve is fitted as measured
        σ_extreme = 1e-9 .* I
        @test shannon_data(q, I, σ_extreme; D, rebin = 12).rebin == 0
        # a threshold of Inf (or a loose one) never raises it; a tighter one raises it further
        @test shannon_data(q, I, σ_precise; D, rebin = 12, max_bin_bias = 1e6).rebin == 12
        tighter = shannon_data(q, I, σ_precise; D, rebin = 12, max_bin_bias = 0.1)
        @test tighter.rebin ≥ auto.rebin
        # the bin map, band limit and channel count are those of the binning that was kept
        @test length(auto.bin) == length(q) && maximum(auto.bin) == length(auto.q)
        @test auto.lMax == auto_lmax(D, maximum(auto.q))
    end

end
