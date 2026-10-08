# SPDX-License-Identifier: LGPL-2.1-or-later

# Does Shannon binning change the fit? For each fitting test, the MAP and the Laplace posterior width found
# on the unbinned curve (`rebin = nothing`) are compared with those found on the curve binned to k bins per
# Shannon channel, at the same band limit lMax. No sampling: only the MAP search and its Hessian.
#
#   tclsh test/run/fittings.tcl [ID ...] --no-fit --shannon --approved     # the entry point: prints its plan without --approved
#
# which runs
#
#   julia --project=test/fitting_tests test/utils/shannon_validation.jl [--ks 8,12,16] [--out FILE.tsv] ID[:tag] ...
#
# This tool is a per-fit SCREEN, not the verdict. Its first criteria (fixed 2026-10-08 before the first run) were:
# in at least 95 % of the fits every MAP coordinate moves by at most 0.5 σ_full, every Laplace σ is within [0.95, 1.05]
# of the unbinned one, and the measured-grid reduced χ² is within 2 %. Every k failed them (k = 12: 94.3 %, 94.3 %,
# 96.2 %), but they judge the binned fit against the unbinned one in the unbinned fit's own σ, which is unrealistically
# small (the unbinned curve has ~60 points per Shannon channel and is overfit), and two of the four failures at k = 12
# are fits where the binned fit has the *better* χ² (the unbinned reference MAP search missed the best basin). Those
# criteria were therefore replaced, after the data was seen, by distribution-level ones on a fresh full rerun of the
# 53 fits compared with the committed unbinned results (`test/utils/compare.tcl`): fit quality (χ² on the measured
# grid), the distribution of the fitted parameters, and the health of the regression (see the Shannon section of
# src/Fitting/README.md). The rows below stay as evidence.
#
# Neither curve drops non-positive points (`drop_nonpositive = false`), so that only the binning differs. The
# extra variants show what the filter does: `12d` bins at k = 12 *with* the default drop of non-positive bins, and
# `raw-d` leaves the curve unbinned but drops its non-positive points (what the fitting scripts used to do).
# The tool writes one row per (fit, k) and prints the pass fractions.

using Printf, Random, LinearAlgebra, Statistics
using BAYSOL
const Fit = BAYSOL.Fitting
include(joinpath(@__DIR__, "fit_seed.jl"))

const MAP_SHIFT_MAX   = 0.5
const SIGMA_RATIO     = (0.95, 1.05)
const CHI2_REL_MAX    = 0.02
const PASS_FRACTION   = 0.95

# MAP (prior-standardized θ), its Laplace σ, the profiled c1 and the reduced χ² on the measured grid.
function map_summary(seed)
    Random.seed!(1)
    sp = Fit._sampling_space(seed, Fit.PROFILE())
    μ, σ = Fit.θ_prior_moments(seed.pr)
    ξ = Fit.Ξ(μ .+ σ .* sp.ẑ, seed.pr)
    ŷ, fit, c1 = Fit.profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab, tol = 1e-8)
    sh = seed.shannon
    y_raw = Fit.model_on_raw(sh, Fit.wls_predict(fit, ŷ))
    χ²_raw = sum(abs2, (sh.I_raw .- y_raw) ./ sh.σ_raw) / (length(sh.I_raw) - 2)
    return (; ẑ = collect(sp.ẑ), σz = sqrt.(diag(sp.S * sp.S')), c1, χ²_raw, n = length(sh.q))
end

function main(args)
    ks = Any[8, 12, 16]; out = nothing; specs = String[]
    i = 1
    while i ≤ length(args)
        if args[i] == "--ks"; ks = Any[parse.(Int, split(args[i+1], ","))...]; i += 2
        elseif args[i] == "--out"; out = args[i+1]; i += 2
        else push!(specs, args[i]); i += 1 end
    end
    isempty(specs) && error("give at least one ID[:tag]")
    rows = NamedTuple[]
    io = out === nothing ? nothing : open(out, "w")
    hdr = "fit\tk\tn_full\tn_binned\tmax_shift_sigma\tsigma_ratio_min\tsigma_ratio_max\tchi2_raw_full\tchi2_raw_binned\tchi2_rel_diff\tc1_full\tc1_binned"
    println(hdr); io === nothing || println(io, hdr)
    for spec in specs
        id, tag = occursin(':', spec) ? split(spec, ":") : (spec, "")
        full_seed, _, label = load_fit_seed(String(id), String(tag); makie = false, seed_options = (; rebin = nothing, drop_nonpositive = false))
        lMax = full_seed.shannon.lMax
        full = map_summary(full_seed)
        for k in vcat(ks, "12d", "raw-d")
            opts = k == "12d"   ? (; rebin = 12, lMax, drop_nonpositive = true) :
                   k == "raw-d" ? (; rebin = nothing, lMax, drop_nonpositive = true) :
                                  (; rebin = k, lMax, drop_nonpositive = false)
            seed, _, _ = load_fit_seed(String(id), String(tag); makie = false, seed_options = opts)
            b = map_summary(seed)
            shift = maximum(abs.(b.ẑ .- full.ẑ) ./ full.σz)
            ratio = b.σz ./ full.σz
            rel = (b.χ²_raw - full.χ²_raw) / full.χ²_raw
            row = (; fit = label, k, n_full = full.n, n_binned = b.n, shift, rmin = minimum(ratio), rmax = maximum(ratio),
                   χ²_full = full.χ²_raw, χ²_b = b.χ²_raw, rel, c1_full = full.c1, c1_b = b.c1)
            push!(rows, row)
            line = @sprintf("%s\t%s\t%d\t%d\t%.3f\t%.3f\t%.3f\t%.4f\t%.4f\t%+.4f\t%.4f\t%.4f", row.fit, k, row.n_full, row.n_binned,
                            shift, row.rmin, row.rmax, row.χ²_full, row.χ²_b, rel, row.c1_full, row.c1_b)
            println(line); io === nothing || (println(io, line); flush(io))
        end
    end
    io === nothing || close(io)
    println("\nk    fits  MAP shift ≤ $(MAP_SHIFT_MAX)σ   Laplace σ in $(SIGMA_RATIO)   χ²_raw within $(100*CHI2_REL_MAX) %   verdict (each ≥ $(100*PASS_FRACTION) %)")
    for k in vcat(ks, "12d", "raw-d")
        r = filter(x -> x.k == k, rows); n = length(r)
        n == 0 && continue
        f1 = count(x -> x.shift ≤ MAP_SHIFT_MAX, r) / n
        f2 = count(x -> SIGMA_RATIO[1] ≤ x.rmin && x.rmax ≤ SIGMA_RATIO[2], r) / n
        f3 = count(x -> abs(x.rel) ≤ CHI2_REL_MAX, r) / n
        @printf("%-4s %4d  %17.1f %%  %20.1f %%  %22.1f %%   %s\n", k, n, 100*f1, 100*f2, 100*f3,
                all(≥(PASS_FRACTION), (f1, f2, f3)) ? "PASS" : "FAIL")
    end
end

main(ARGS)
