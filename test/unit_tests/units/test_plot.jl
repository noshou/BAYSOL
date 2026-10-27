# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Pipeline/Results.jl (`results`, `PlotStyle`, `Reference`
# and the data every figure is drawn from) and the plot stages in the timing
# table. The result of a fit is a synthetic stand-in with the fields the
# plots read, so no sampling runs; LaTeX is never run (`compile = false`).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using Random
using StaticArrays: SVector
using BAYSOL.Runtime: StageLog, tick, stage_seconds
using BAYSOL.Pipeline: results, PlotStyle, Reference, _curve_data, _residual_data,
    _histogram_data, _rgba, _log_ticks, _linear_ticks, _tick_labels,
    _fitting_ticks, _sheet_names,
    PLOT_COLOR_MAP,
    PLOT_HIST_BINS,
    PLOT_HIST_PARAMS

# a result with the shape `run_model` returns: (fit, divergence rate, (MAP params, MAP
# curve), (quantile params, curves)); `with_map = false` is the all-draws-diverged case
function synthetic_result(; n_draws = 300, with_map = true, seed = 1)
    rng = Xoshiro(seed)
    q = collect(range(0.02, 0.4; length = 30))
    I_true = 1000 .* exp.(-(q .* 25) .^ 2 ./ 3) .+ 5
    σ = 0.03 .* I_true
    I = I_true .+ σ .* randn(rng, length(q))
    samples = [
        SVector(0.335 + 0.003randn(rng), 1.0 + 0.3randn(rng), 0.5 + 0.2randn(rng),
            -1 + 0.5randn(rng)) for _ in 1:n_draws
    ]
    stats = [
        (; numerical_error = i % 50 == 0, acceptance_rate = 0.9, tree_depth = 3,
            n_steps = 7, hamiltonian_energy = randn(rng)) for i in 1:n_draws
    ]
    diagnostics = BAYSOL.Inference.ChainDiagnostics(3, zeros(3), fill(true, 3),
        fill("ok", 3), [1.001], [1000.0], [800.0], 0.0, ones(Int, 3), [1.0], [850.0],
        [0.02], false, 300, NaN, false, 0, BAYSOL.Inference.OptimumReport[])
    log = StageLog()
    fit = (; samples, stats, scale = 1 .+ 0.01randn(rng, n_draws),
        bkgrnd_corr = 0.1 .+ 0.01randn(rng, n_draws), c1 = 1 .+ 0.02randn(rng, n_draws),
        chisq_red = 1 .+ 0.1rand(rng, n_draws),
        chain = repeat(1:3, inner = n_draws ÷ 3),
        iteration = repeat(1:(n_draws÷3), 3), timing = log, diagnostics)
    mapp = Dict("log_density" => 1.0, "slvnt_e_dns" => 0.335, "delta_rho_1" => 1.0,
        "delta_rho_2" => 0.5, "delta_rho_3" => -1.0, "scale" => 1.0,
        "bkgrnd_corr" => 0.1,
        "excl_vol_corr" => 1.0, "chisq_red" => 1.1,
        "z_slvnt_e_dns" => 0.1, "z_delta_rho_1" => 0.2, "z_delta_rho_2" => -0.3,
        "z_delta_rho_3" => 0.4)
    qparams = Dict{String,Any}(
        k => Dict("quantiles" => (v - 0.1, v + 0.1), "bounds" => (v - 0.2, v + 0.2),
            "z" => (-1.0, 1.0)) for (k, v) in mapp if !startswith(k, "z_"))
    curves = Dict("bounds" => hcat(q, I_true .* 0.97, I_true .* 1.05),
        "quantiles" => hcat(q, I_true .* 0.99, I_true .* 1.03))
    result = (fit, 0.0, with_map ? (mapp, hcat(q, I_true .* 1.01)) : nothing,
        with_map ? (qparams, curves) : nothing)
    return result, (q, I, σ), I_true
end

# a real, tiny fit (16 atoms, 40 iterations) for what needs the whole report; built once
const _REAL = Ref{Any}(nothing)
function real_result()
    _REAL[] === nothing || return _REAL[]
    dir = mktempdir()
    path = joinpath(dir, "helix.pdb")
    open(path, "w") do io
        names, elems = ("N", "CA", "C", "O"), ("N", "C", "C", "O")
        for i in 0:15
            res, k = divrem(i, 4)
            x, y, z = 1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i
            println(
                io,
                rpad(
                    string("ATOM  ", lpad(i + 1, 5), " ", rpad(names[k+1], 4),
                        " ALA A", lpad(res + 1, 4), "    ",
                        lpad(string(round(x; digits = 3)), 8),
                        lpad(string(round(y; digits = 3)), 8),
                        lpad(string(round(z; digits = 3)), 8),
                        "  1.00  0.00          ", lpad(elems[k+1], 2)), 80),
            )
        end
        println(io, "END")
    end
    q = collect(range(0.02, 0.30; length = 60))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    solutes = BAYSOL.BulkElectronDensity.Solute[BAYSOL.BulkElectronDensity.NonBiological(
        0.15, 0.001, "sodium chloride")]
    seed = BAYSOL.seed_model(BAYSOL.MolecularStructure.LocalPathSource(path), 9000.0, q, I,
        0.02 .* I, 7.0, 0.1, solutes; add_hydrogens = false)
    result = redirect_stdout(devnull) do
        BAYSOL.run_model(seed, 40, 20; retry = false)
    end
    rm(dir; recursive = true, force = true)
    _REAL[] = (result, seed)
    return _REAL[]
end

@testset "Plot" begin
    @testset "PlotStyle: defaults are the module constants, every one overridable" begin
        @test PlotStyle().color_map == PLOT_COLOR_MAP
        @test PlotStyle().hist_bins == PLOT_HIST_BINS
        s = PlotStyle(; color_map = "blue", hist_bins = 10, lw_map = 3)
        @test s.color_map == "blue" && s.hist_bins == 10 && s.lw_map == 3.0
        @test PlotStyle().font == BAYSOL.Pipeline.PLOT_FONT
        @test PlotStyle().font == ("TeX Gyre PagellaX", "TeX Gyre Pagella Math")
    end

    @testset "colours: names, hex strings and (colour, opacity) tuples" begin
        @test _rgba(:crimson) == (220, 20, 60, 1.0)
        @test _rgba("#0000ff") == (0, 0, 255, 1.0)
        @test _rgba((:darkorange, 0.15)) == (255, 140, 0, 0.15)
        @test_throws Exception _rgba("not a colour")
    end

    @testset "Reference: unusable points are dropped" begin
        r = Reference("CRYSOL", [0.0, 0.1, 0.2, 0.5, NaN], [1.0, 2.0, -1.0, 3.0, 4.0];
            q_max = 0.4)
        @test r.q == [0.1] && r.I == [2.0]
        @test r.name == "CRYSOL"
        @test_throws ArgumentError Reference("x", [0.1, 0.2], [1.0])
        @test_throws ArgumentError Reference("x", [0.1], [-1.0])
    end

    @testset "_curve_data: positive points, log-symmetric error bars, floored band" begin
        result, (q, I, σ), I_true = synthetic_result()
        I[3] = -1.0                                  # not drawable on a log axis
        c = _curve_data(result, (q, I, σ), PlotStyle())
        @test length(c.q) == length(q) - 1 && all(c.I .> 0)
        @test all(c.err_lo .< c.I .< c.err_hi) && all(c.err_lo .> 0)
        @test all(@. abs(sqrt(c.err_lo * c.err_hi) / c.I - 1) < 1e-12)  # centred in log
        @test c.ylim == (minimum(c.I) * 0.7, maximum(c.I) * 1.3)
        @test all(c.band.lo .≥ minimum(c.I) / 2)
        @test c.map !== nothing && all(c.map.I .> 0)
        # a non-positive model value is a gap, not an error
        result2, data2, _ = synthetic_result()
        result2[3][2][5, 2] = -3.0
        @test isnan(_curve_data(result2, data2, PlotStyle()).map.I[5])
        # no MAP, no quantiles
        none, d, _ = synthetic_result(with_map = false)
        cn = _curve_data(none, d, PlotStyle())
        @test cn.map === nothing && cn.band === nothing && cn.quant === nothing
        @test _residual_data(none, d, PlotStyle()) === nothing
        @test_throws ArgumentError _curve_data(result, (q, -abs.(I), σ), PlotStyle())
    end

    @testset "_residual_data: data minus MAP, band minus MAP" begin
        result, (q, I, σ), I_true = synthetic_result()
        r = _residual_data(result, (q, I, σ), PlotStyle())
        @test r.resid ≈ I .- 1.01 .* I_true
        @test r.band.lo ≈ 0.97 .* I_true .- 1.01 .* I_true
        lo, hi = extrema(r.resid)
        @test r.ylim[1] ≈ lo - 0.3 * (hi - lo) && r.ylim[2] ≈ hi + 0.3 * (hi - lo)
    end

    @testset "_histogram_data: every non-divergent draw is counted once" begin
        result, data, _ = synthetic_result(n_draws = 300)
        hs = _histogram_data(result, PlotStyle())
        @test length(hs) == length(PLOT_HIST_PARAMS)
        n_ok = count(s -> !s.numerical_error, result[1].stats)
        for h in hs
            @test sum(h.counts) == n_ok
            @test length(h.edges) == PLOT_HIST_BINS + 1 && issorted(h.edges)
        end
        @test hs[1].label == "ρₑ" && hs[1].map_value == 0.335
        @test _histogram_data(result, PlotStyle(; hist_bins = 7))[1].counts |> length == 7
        # a parameter with a single value still gets bins
        const_fit = merge(result[1], (; c1 = fill(1.0, 300)))
        hc = _histogram_data((const_fit, result[2:end]...), PlotStyle())
        @test sum(hc[end].counts) == n_ok && issorted(hc[end].edges)
    end

    @testset "_log_ticks: round values inside the range" begin
        t = _log_ticks(0.0185, 0.432)
        @test t ≈ [0.02, 0.03, 0.05, 0.1, 0.2, 0.3]
        @test all(0.0185 .≤ t .≤ 0.432)
        @test length(_log_ticks(1.0, 1.9)) ≥ 2           # a narrow range falls back
    end

    @testset "_linear_ticks: round values whose labels tell them apart" begin
        # a narrow range far from zero needs more digits than three
        ticks, labels = _linear_ticks(0.3399, 0.3424, 5)
        @test length(ticks) ≥ 3 && allunique(labels)
        @test all(startswith("\$0.34"), labels)
        # a parameter of the size of 1e-6 is not a column of zeros
        ticks, labels = _linear_ticks(1.17e-6, 1.49e-6, 5)
        @test length(ticks) ≥ 3 && allunique(labels)
        @test all(l -> occursin("\\times10^{-6}", l), labels)
        # negative values, whole steps, zero and a constant
        @test _tick_labels([-11.2], 0.2) == ["\$-11.2\$"]
        @test _tick_labels([0.3, 0.32, 0.34], 0.02) == ["\$0.30\$", "\$0.32\$", "\$0.34\$"]
        @test _tick_labels([0.0, 2.0, 12.0], 2.0) == ["\$0\$", "\$2\$", "\$12\$"]
        # far from 1: one exponent for the whole axis, one number of decimals
        @test _tick_labels([6e-6, 8e-6, 1e-5], 2e-6) ==
              ["\$0.6\\times10^{-5}\$", "\$0.8\\times10^{-5}\$", "\$1.0\\times10^{-5}\$"]
        @test _linear_ticks(1.0, 1.0, 5) == (Float64[], String[])
        # the ticks lie inside the range and are evenly spaced
        ticks, _ = _linear_ticks(-11.4, -9.7, 5)
        @test all(-11.4 .≤ ticks .≤ -9.7) &&
              length(unique(round.(diff(ticks); digits = 9))) == 1
    end

    @testset "_fitting_ticks: long labels get fewer ticks" begin
        short, _ = _fitting_ticks(0.30, 0.40, 10.0)
        long_, labels = _fitting_ticks(5.9e-6, 1.15e-5, 10.0)
        @test length(short) ≥ length(long_) ≥ 3
        @test allunique(labels)
        # a narrow axis gets no more ticks than a wide one
        @test length(first(_fitting_ticks(5.9e-6, 1.15e-5, 4.0))) ≤ length(long_)
    end

    @testset "results: files, names and the workbook" begin
        result, data, I_true = synthetic_result()
        q = data[1]
        XLSX = BAYSOL.Pipeline.XLSX
        mktempdir() do dir
            files = results(result, data; dir, name = "res_x", preview = false,
                io = IOBuffer(),
                references = Reference("CRYSOL fit1", q, I_true .* 1.02))
            names = basename.(files)
            # the layout: .tex in plots/, the numbers in one workbook; no log unless asked
            @test sort(readdir(dir)) == ["plots", "res_x.xlsx"]
            tex_files = ["res_x.tex", "res_x_residuals.tex", "res_x_comparison.tex",
                ["res_x_hist_$(h[4]).tex" for h in PLOT_HIST_PARAMS]...]
            for f in tex_files
                @test f in names && isfile(joinpath(dir, "plots", f))
            end
            @test "res_x.xlsx" in names
            @test sort(readdir(joinpath(dir, "plots"))) == sort(tex_files)
            @test !any(endswith(".pdf"), names)             # LaTeX is not run by default
            @test !any(endswith(".tsv"), names)             # the numbers: the workbook only
            tex = read(joinpath(dir, "plots", "res_x.tex"), String)
            @test occursin("\\begin{axis}", tex) &&
                  occursin("\\definecolor{bsmap}{RGB}{220,20,60}", tex)
            @test occursin("name path={bslo}", tex) && occursin("fill between", tex)
            # the error bars ride on an invisible plot: `only marks` would leave a pale
            # default-sized marker on every point
            @test occursin("draw={none}", tex) && !occursin("only marks, mark={none}", tex)
            @test occursin("error bars/error bar style={color=bserrorbar", tex)
            @test occursin(
                "CRYSOL fit1",
                read(joinpath(dir, "plots", "res_x_comparison.tex"), String),
            )
            # the workbook's sheets
            xf = XLSX.readxlsx(joinpath(dir, "res_x.xlsx"))
            sheets = XLSX.sheetnames(xf)
            for s in ("run", "map", "quantiles_2sigma", "stdev_from_prior",
                "ref_CRYSOL_fit1", "data", "model", "residuals", "draws",
                ["hist_$(h[4])" for h in PLOT_HIST_PARAMS]...)
                @test s in sheets
            end
            @test !("hist" in sheets)                       # one sheet for each histogram
            d = xf["data"][:]
            @test string.(d[1, :]) == ["q", "I", "sigma"] && size(d, 1) == length(q) + 1
            @test string.(xf["model"][:][1, :]) ==
                  ["q", "I_map", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"]
            # a histogram's sheet: its bins and counts, which add up to the non-divergent
            # draws
            h = xf["hist_rho_e"][:]
            @test string.(h[1, :]) == ["bin_lo", "bin_hi", "count"] &&
                  size(h, 1) == 1 + PLOT_HIST_BINS
            n_ok = count(s -> !s.numerical_error, result[1].stats)
            @test sum(h[2:end, 3]) == n_ok
            dr = xf["draws"][:]
            @test size(dr, 1) == 301 &&
                  string.(dr[1, 1:4]) == ["chain", "iteration", "divergent", "rho_e"]
            # every 50th diverged
            @test count(==(1), dr[2:end, 3]) == 6
        end
    end

    @testset "results: a file per reference; the style reaches the .tex" begin
        result, data, I_true = synthetic_result()
        q = data[1]
        mktempdir() do dir
            files = results(result, data; dir, preview = false,
                style = PlotStyle(;
                    color_map = "#0000ff",
                    font = ("Some Text Font", "Some Math Font"),
                ),
                references = [
                    Reference("CRYSOL fit1", q, I_true),
                    Reference("Fo/XS", q, I_true),
                ],
            )
            names = basename.(files)
            @test "res_comparison_CRYSOL_fit1.tex" in names &&
                  "res_comparison_Fo_XS.tex" in names
            @test !("res_comparison.tex" in names)
            @test count(endswith(".xlsx"), names) == 1
            tex = read(joinpath(dir, "plots", "res.tex"), String)
            @test occursin("\\definecolor{bsmap}{RGB}{0,0,255}", tex)
            @test occursin("\\setmainfont{Some Text Font}", tex)
            @test occursin("\\setmathfont{Some Math Font}", tex)
        end
        mktempdir() do dir                                # tex = false: the workbook only
            files =
                results(
                    result,
                    data;
                    dir,
                    preview = false,
                    tex = false,
                )
            @test basename.(files) == ["res.xlsx"] && readdir(dir) == ["res.xlsx"]
        end
    end

    @testset "results: the terminal preview" begin
        result, data, I_true = synthetic_result()
        mktempdir() do dir
            io = IOBuffer()
            results(result, data; dir, io, tex = false,
                references = Reference("CRYSOL", data[1], I_true))
            out = String(take!(io))
            for s in ("fit", "residuals", "ρₑ", "δρ₃", "bkgrnd_corr", "MAP", "log₁₀ q")
                @test occursin(s, out)
            end
            @test occursin("fit   χ² = 1.1", out) && occursin("residuals   χ² = 1.1", out)
            # the bounds and the reference curves are for the .tex only
            @test !occursin("bounds", out) && !occursin("comparison", out)
            @test !occursin("CRYSOL", out)
            io = IOBuffer()
            results(
                result,
                data;
                dir,
                io,
                preview = false,
                tex = false,
            )
            @test isempty(take!(io))
        end
    end

    @testset "each histogram is a figure of its own and a sheet of its own" begin
        result, data, _ = synthetic_result()
        mktempdir() do dir
            files =
                basename.(results(result, data; dir, preview = false))
            tex = filter(f -> startswith(f, "res_hist_") && endswith(f, ".tex"), files)
            @test length(tex) == length(PLOT_HIST_PARAMS) == 7
            @test "res_hist_rho_e.tex" in tex && "res_hist_c1.tex" in tex
            @test !("res_hist.tex" in files)                     # the group plot is gone
            src = read(joinpath(dir, "plots", "res_hist_delta_rho_2.tex"), String)
            @test count("\\begin{axis}", src) == 1 && !occursin("\\begin{groupplot}", src)
            @test occursin("\\delta\\rho_2", src)
            # one sheet each
            xf = BAYSOL.Pipeline.XLSX.readxlsx(joinpath(dir, "res.xlsx"))
            @test count(startswith("hist_"), BAYSOL.Pipeline.XLSX.sheetnames(xf)) == 7
        end
    end

    @testset "_sheet_names: Excel's limits" begin
        long = "ref_" * "x"^40
        names = _sheet_names([long, long, "data", "data"])
        @test all(≤(31) ∘ length, names) && allunique(names)
        @test names[3] == "data" && names[4] == "data_2"
        @test names[2] ≠ names[1] && startswith(names[2], "ref_xxx") &&
              endswith(names[2], "_2")
    end

    @testset "results: the workbook" begin
        result, seed = real_result()
        XLSX = BAYSOL.Pipeline.XLSX
        mktempdir() do dir
            files = results(result, seed; dir, name = "res_w", preview = false,
                tex = false, run_log = true,
                references = Reference("CRYSOL", seed.shannon.q, seed.shannon.I))
            @test basename.(files) == ["res_w.xlsx", basename(dir) * ".LOG"]
            # the workbook and the log, no data/ folder, no .part left over
            @test sort(readdir(dir)) == sort(["res_w.xlsx", basename(dir) * ".LOG"])
            xf = XLSX.readxlsx(joinpath(dir, "res_w.xlsx"))
            sheets = XLSX.sheetnames(xf)
            @test sheets[1:4] == ["run", "map", "quantiles_2sigma", "stdev_from_prior"]
            @test all(in(sheets), ["data", "model", "residuals", "draws", "ref_CRYSOL"])
            @test all(in(sheets), ["hist_" * h[4] for h in PLOT_HIST_PARAMS])
            # sheet and column names are plain ASCII
            @test all(isascii, sheets)
            @test all(isascii, string.(xf["draws"][:][1, :]))
            # run: section | name | value | unit | meaning; a number on every row, the
            # binning and the chains among them, the rows grouped by section, each explained
            run = xf["run"][:]
            @test string.(run[1, :]) == ["section", "name", "value", "unit", "meaning"]
            keys_ = string.(run[2:end, 2])
            for k in ("n_atoms", "lmax", "dmax", "rebin_channels", "rebin_measured",
                "rebin_fitted", "rebin_non_positive_dropped", "tree_depth_avg",
                "tree_depth_max", "ebfmi", "excl_vol_sat", "chains_pooled", "chains_run",
                "rhat_max", "ess_min", "ess_tail_min")
                @test k in keys_
            end
            # numbers all, the seed too (a fresh one has 53 bits, exact as a number); a
            # statistic that could not be computed (E-BFMI of a very short chain can be NaN)
            # is an empty cell, never text
            @test all(x -> x isa Real || ismissing(x), run[2:end, 3])
            @test run[findfirst(==("rng_seed"), string.(run[:, 2])), 3] isa Real
            sections = string.(run[2:end, 1])
            P = BAYSOL.Pipeline
            @test all(in(P._RUN_SECTIONS), sections)
            idx = [findfirst(==(x), P._RUN_SECTIONS) for x in sections]
            @test issorted(idx)                                # grouped, in the set order
            @test all(k -> haskey(P._RUN_INFO, k), keys_)      # every row is explained
            @test all(m -> m isa AbstractString && length(m) > 10, run[2:end, 5])
            # map and quantiles: one row for each reported quantity
            nk = length(BAYSOL.Pipeline._REPORT_KEYS)
            m = xf["map"][:]
            @test string.(m[1, :]) == ["parameter", "value"] && size(m, 1) == 1 + nk
            @test m[2, 1] == "log_density" && m[end, 1] == "chi2"
            q = xf["quantiles_2sigma"][:]
            @test string.(q[1, :]) ==
                  ["parameter", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"]
            @test size(q, 1) == 1 + nk
            # the four parameters with a prior have z-scores
            z = xf["stdev_from_prior"][:]
            @test string.(z[1, :]) ==
                  ["parameter", "z_map", "z_quantile_lo", "z_quantile_hi"]
            @test string.(z[2:end, 1]) ==
                  ["rho_e", "delta_rho_1", "delta_rho_2", "delta_rho_3"]
            @test all(x -> x isa Real, z[2:end, 2:end])
            # every draw is a row of `draws`
            @test size(xf["draws"][:], 1) == 1 + length(result[1].samples)
            # the timings are in the run's log, not in the workbook
            @test !("timings" in XLSX.sheetnames(xf))
            logfile = joinpath(dir, basename(dir) * ".LOG")
            @test isfile(logfile) && contains(read(logfile, String), "\n=== w ===\n")
            @test endswith(
                only(filter(contains("Log:"), BAYSOL.Pipeline._summary_lines(result))),
                basename(dir) * ".LOG")
        end
        # something that is not a font is refused before anything is written
        mktempdir() do dir
            @test_throws ArgumentError results(result, seed; dir, font = 3)
            @test isempty(readdir(dir))
        end
    end

    @testset "a statistic that cannot be computed: empty cell, no log row" begin
        # a constant energy makes E-BFMI 0/0: NaN, whatever the random state of the run
        result, data, _ = synthetic_result()
        flat = [merge(s, (; hamiltonian_energy = 1.0)) for s in result[1].stats]
        result = (merge(result[1], (; stats = flat)), result[2:end]...)
        XLSX = BAYSOL.Pipeline.XLSX
        mktempdir() do dir
            results(result, data; dir, preview = false, tex = false, run_log = true)
            run = XLSX.readxlsx(joinpath(dir, "res.xlsx"))["run"][:]
            @test ismissing(run[findfirst(==("ebfmi"), string.(run[:, 2])), 3])
            @test !any(x -> isequal(x, "NaN"), run[:, 3])
            log = read(joinpath(dir, basename(dir) * ".LOG"), String)
            @test !occursin("ebfmi", log) && occursin("rhat_max", log)
        end
    end

    @testset "write_log: one file for a folder, a section for each run, aligned" begin
        P = BAYSOL.Pipeline
        # a cell with another after it is padded with spaces to a width that is a multiple
        # of 8 and followed by one tab; the last cell is not padded
        lines = P._tab_lines([["a", "1"], ["longer_name", "2", "3"], ["abcdefgh", "4"]])
        @test lines == [
            "a" * " "^15 * "\t1",
            "longer_name" * " "^5 * "\t2" * " "^7 * "\t3",
            "abcdefgh" * " "^8 * "\t4",
        ]
        # a section is replaced where it stands, a new one goes last, the blank lines
        # inside a section stay
        mktempdir() do dir
            path = joinpath(dir, "x.LOG")
            P._update_log(path, "m1", ["k\t1", "", "--- block ---", "z"])
            P._update_log(path, "m2", ["k\t2"])
            P._update_log(path, "m2", ["k\t3"])
            text = read(path, String)
            # the stamp of the write is the first line, once; then the sections
            @test occursin(r"^datetime\t\d\d-\d\d-\d{4} \d\d:\d\d:\d\d [+-]\d{4}\n", text)
            @test count("datetime", text) == 1
            @test endswith(
                text,
                "\n=== m1 ===\nk\t1\n\n--- block ---\nz\n\n=== m2 ===\nk\t3\n",
            )
            @test readdir(dir) == ["x.LOG"]                    # no .part left over
        end
        result, data, _ = synthetic_result()
        mktempdir() do dir
            results(result, data; dir, name = "res_fit1", preview = false, tex = false,
                run_log = true, ref_chi2 = "CRYSOL 1.5")
            results(result, data; dir, name = "res_fit2", preview = false, tex = false,
                run_log = true)
            logfile = joinpath(dir, basename(dir) * ".LOG")
            text = read(logfile, String)
            # a section for each run, named after it
            @test [m.captures[1] for m in eachmatch(r"^=== (.*) ===$"m, text)] ==
                  ["fit1", "fit2"]
            body = split(split(text, "=== fit1 ===\n")[2], "\n=== fit2 ===")[1]
            lines = split(chomp(body), '\n')
            i_time = findfirst(==("--- timing ---"), lines)
            i_mach = findfirst(==("--- machine ---"), lines)
            # the run first, then the timings, the machine last
            @test 1 < i_time < i_mach < length(lines)
            stats, timing, machine =
                lines[1:(i_time-2)], lines[(i_time+1):(i_mach-2)], lines[(i_mach+1):end]
            kv(ls) = Dict(
                strip(first(split(l, '\t'))) => strip.(split(l, '\t')[2:end])
                for l in ls
            )
            one = kv(stats)
            @test first(stats) |> l -> startswith(l, "revision")
            @test one["ref_chi2"] == ["CRYSOL 1.5"]
            for k in ("revision", "julia", "chi2", "rho_e", "c1", "delta_rho_3",
                "z_delta_rho_3", "divergence_rate", "n_divergent", "rhat_max", "ess_min",
                "ebfmi", "chains_pooled", "modes")
                @test haskey(one, k)
            end
            @test one["chi2"] == ["1.1"] && one["n_divergent"] == ["6"]
            @test all(l -> startswith(l, "machine."), machine)
            @test all(
                k -> haskey(kv(machine), k),
                ("machine.os", "machine.cpu", "machine.cpus", "machine.threads",
                    "machine.memory_gib", "machine.load_start"))
            # the timing table, as a person reads it: a header, the wall clock, the startup
            # (with its note in a column of its own), the groups, then GC and the two halves
            @test startswith(timing[1], "stage") && endswith(timing[1], "notes")
            row(prefix) = only(filter(l -> startswith(l, prefix), timing))
            nums(l) = parse.(
                Float64,
                match(
                    r"(-?[\d.e-]+)\s+(-?[\d.]+)\s+\(([\d.e-]+)\)\s+\(([\d.e-]+)\)",
                    l).captures,
            )
            wall = nums(row("wall clock"))
            @test wall[2] == 100.0 && length(wall) == 4
            @test all(p -> length(nums(row(p))) == 4,
                ("  startup", "  plotting", "  report write", "  unaccounted"))
            @test endswith(row("  startup"), "process start to seed_model")   # its note
            @test startswith(timing[end-2], "GC: ")
            fit = parse(Float64, match(r"= (\S+) s", timing[end-1]).captures[1])
            plot = parse(Float64, match(r"= (\S+) s", timing[end]).captures[1])
            @test startswith(timing[end-1], "fit timing  = ")
            @test startswith(timing[end], "plot timing = ")
            @test fit + plot ≈ wall[1] atol = 0.02
            # the value column starts at the same character of every row of the run and of
            # the machine, at any tab width
            for tabw in (2, 4, 8)
                col(l) = (n = length(first(split(l, '\t'))); tabw * (n ÷ tabw + 1))
                @test length(unique(col.(filter(l -> contains(l, '\t'), stats)))) == 1
                @test length(unique(col.(filter(l -> contains(l, '\t'), machine)))) == 1
            end
            # a second call replaces the run's section instead of adding another
            BAYSOL.write_log(result)
            text2 = read(logfile, String)
            @test count("=== fit2 ===", text2) == 1 && count("=== fit1 ===", text2) == 1
            @test count("--- timing ---", text2) == 2
        end
    end


    @testset "tables: numbers carry TABLE_SIGFIGS significant figures" begin
        P = BAYSOL.Pipeline
        @test P.TABLE_SIGFIGS == 17
        x = 0.1 + 0.2
        @test P._cell(x) === x && P._cell(7) === 7
        # a number that is not finite is an empty cell, not the text "NaN"
        @test ismissing(P._cell(NaN)) && ismissing(P._cell(Inf)) && ismissing(P._cell(-Inf))
    end

    @testset "print_summary: the verdict, the checks, the files and the wall clock" begin
        result, data, _ = synthetic_result()
        lines = BAYSOL.Pipeline._summary_lines(result)
        @test lines[1] == "Fit finished: reduced χ² = 1.10 on the measured points"
        @test startswith(lines[2], "  ρₑ = 0.335 (0.235–0.435)    δρ₁ = 1 (0.9–1.1)")
        @test occursin("δρ₃ = −1 (−1.1 – −0.9)", lines[2])
        @test lines[3] ==
              "  Checks: converged (R̂ 1.001), no divergent transitions, 3 of 3 chains used"
        @test startswith(lines[end], "Wall clock: ") && endswith(lines[end], " s")
        @test length(lines) == 4                      # no file written yet, no notes
        # a failed check adds a note in words
        bad = (result[1], 0.05, result[3], result[4])
        blines = BAYSOL.Pipeline._summary_lines(bad)
        @test occursin("5.0 % divergent transitions", blines[3])
        @test any(startswith("  Note: more than 1 % of the transitions diverged"), blines)
        # no MAP: the verdict says so
        nomap = BAYSOL.Pipeline._summary_lines(synthetic_result(; with_map = false)[1])
        @test occursin("every draw diverged", nomap[1])
        # the files results wrote are named, the wall clock is last
        mktempdir() do dir
            results(result, data; dir, preview = false, run_log = true)
            lines = BAYSOL.Pipeline._summary_lines(result)
            files = only(filter(contains("Results:"), lines))
            @test occursin("res.xlsx", files) && occursin("Figures: ", files) &&
                  occursin("plots/", files) && occursin(".LOG", files)
            @test startswith(lines[end], "Wall clock: ")
            io = IOBuffer()
            BAYSOL.print_summary(io, result)
            # the same lines, but for the wall clock, which has moved on
            printed = split(chomp(String(take!(io))), '\n')
            @test printed[1:(end-1)] == lines[1:(end-1)]
            @test startswith(printed[end], "Wall clock: ")
        end
    end

    @testset "ticks: black, inward, four sides, major and minor; slanted, padded" begin
        P = BAYSOL.Pipeline
        @test PlotStyle().xtick_angle == P.PLOT_XTICK_ANGLE == 45.0
        @test PlotStyle().lw_tick == P.PLOT_LW_TICK
        @test PlotStyle().minor_ticks == P.PLOT_MINOR_TICKS
        result, data, I_true = synthetic_result()
        mktempdir() do dir
            files = results(result, data; dir, preview = false,
                references = Reference("CRYSOL", data[1], I_true))
            tex = filter(endswith(".tex"), files)
            # fit, residuals, 7 histograms, comparison
            @test length(tex) == 10
            for f in tex
                src = read(f, String)
                @test occursin("xtick pos={both}", src) && occursin("ytick pos={both}", src)
                @test occursin("tick style={{black, line width=0.8pt}}", src)
                @test occursin("axis line style={{black, line width=1.2pt}}", src)
                @test occursin("yticklabel style={xshift=-4.0pt}", src)
                # the x labels are drawn: a stub (4 pt) and an elbow (6 pt at 45°) to a
                # label slanted by 45°; pgfplots prints none, and clips each plot only
                @test occursin("xticklabels={{}}", src) &&
                      occursin("clip mode={individual}", src)
                @test occursin("++(0pt,-4.0pt) -- ++(-4.24", src)
                @test occursin("node[anchor=east, rotate=45.0, inner sep=2pt", src)
            end
            # minor ticks: a linear axis (a histogram, the residuals) counts them,
            # a log axis (the fit) has its own
            hist = read(joinpath(dir, "plots", "res_hist_rho_e.tex"), String)
            @test occursin("minor x tick num={4}", hist) &&
                  occursin("minor y tick num={4}", hist)
            @test !occursin("minor x tick num", read(first(tex), String))
            # the log axis labels are rounded: 0.3, not 0.30000000000000004
            @test !occursin(r"\{\$0\.30+\d+\$\}", read(first(tex), String))
            @test occursin("{\$0.3\$};", read(first(tex), String))
            # an angle of 0: the tick stays straight and the label sits level below it
            files = results(result, data; dir, preview = false,
                style = PlotStyle(; xtick_angle = 0))
            src = read(first(filter(endswith(".tex"), files)), String)
            @test !occursin("rotate=0", src) && occursin("node[anchor=north, inner", src)
            @test !occursin("rotate=45", src) && !occursin("-- ++(-", src)
        end
    end

    @testset "a log axis starts and ends where the data do, with a small legend" begin
        result, data, I_true = synthetic_result()
        q = data[1]
        mktempdir() do dir
            results(result, data; dir, preview = false,
                references = Reference("CRYSOL", q, I_true))
            for f in ("res.tex", "res_comparison.tex")
                src = read(joinpath(dir, "plots", f), String)
                @test occursin("xmin={$(minimum(q))}", src)
                @test occursin("xmax={$(maximum(q))}", src)
                @test occursin("font=\\footnotesize", src)
            end
        end
    end

    @testset "a histogram's legend: MAP (solid) and μ (dotted), with their values" begin
        P = BAYSOL.Pipeline
        @test P._tex_number(-5.4871) == "-5.487" && P._tex_number(0.0) == "0"
        @test P._tex_number(6.2e-6) == "6.2\\times10^{-6}"
        # μ is the middle of the tallest bin; the skewness says where the tail is
        h = (; edges = [0.0, 1.0, 2.0, 3.0, 4.0], counts = [1, 5, 2, 1])
        @test P._hist_mode(h) == 1.5 && P._hist_skew(h) > 0
        @test P._hist_skew((; edges = h.edges, counts = reverse(h.counts))) < 0
        # a narrow posterior prints more digits, so that MAP and μ differ
        @test P._tex_number(0.336153; sigfigs = 6) == "0.336153"
        result, data, _ = synthetic_result()
        mktempdir() do dir
            results(result, data; dir, preview = false)
            src = read(joinpath(dir, "plots", "res_hist_delta_rho_3.tex"), String)
            # the two lines, the MAP value in its own colour, μ dotted, both in the legend
            @test occursin("\\addlegendentry {\$\\mathrm{MAP} = -1.0\$}", src)
            @test occursin("\\addlegendentry {\$\\mu = ", src)
            @test occursin("dotted", src) && occursin("draw=black, fill=white", src)
            @test occursin("legend pos={north", src)
            # only the histograms carry them
            fit = read(joinpath(dir, "plots", "res.tex"), String)
            @test !occursin("\\mu = ", fit) && !occursin("mathrm{MAP} =", fit)
        end
    end

    @testset "the page keeps a border round every figure" begin
        result, data, _ = synthetic_result()
        mktempdir() do dir
            results(result, data; dir, preview = false)
            @test occursin("\\documentclass[tikz,border=8.0pt]{standalone}",
                read(joinpath(dir, "plots", "res.tex"), String))
            results(result, data; dir, preview = false,
                style = PlotStyle(; border_pt = 3))
            @test occursin("border=3.0pt]", read(joinpath(dir, "plots", "res.tex"), String))
            @test !occursin("border=8.0pt", read(joinpath(dir, "plots", "res.tex"), String))
        end
    end

    @testset "results: the font option" begin
        result, data, _ = synthetic_result()
        tex_of(; kw...) = mktempdir() do dir
            results(result, data; dir, preview = false, kw...)
            read(joinpath(dir, "plots", "res.tex"), String)
        end
        # the default is TeX Gyre PagellaX with the Pagella math font
        tex = tex_of()
        @test occursin("\\usepackage{unicode-math}", tex)
        @test occursin("\\setmainfont{TeX Gyre PagellaX}", tex)
        @test occursin("\\setmathfont{TeX Gyre Pagella Math}", tex)
        # any font name: a single name is the text font and leaves the math font alone
        tex = tex_of(font = "Any Installed Font")
        @test occursin("\\setmainfont{Any Installed Font}", tex)
        @test !occursin("setmathfont", tex)
        # a pair gives both, and the keyword beats the style's font
        @test occursin("\\setmathfont{M}", tex_of(font = ("T", "M")))
        @test occursin("\\setmainfont{Z}",
            tex_of(style = PlotStyle(; font = nothing), font = "Z"))
        # nothing leaves the LaTeX default, which every engine compiles
        @test !occursin("unicode-math", tex_of(font = nothing))
        @test !occursin("setmainfont", tex_of(style = PlotStyle(; font = nothing)))
        # something that is not a font name is refused before anything is written
        mktempdir() do dir
            @test_throws ArgumentError results(result, data; dir, font = 3)
            @test_throws ArgumentError results(
                result,
                data;
                dir,
                font = ("a", "b", "c"),
            )
            @test isempty(readdir(dir))
        end
    end

    @testset "font_available asks the TeX Live installation" begin
        if Sys.which("luaotfload-tool") === nothing
            @test_throws ErrorException BAYSOL.font_available("Latin Modern Roman")
        else
            @test BAYSOL.font_available("Latin Modern Roman") === true
            @test BAYSOL.font_available("latin modern roman") === true     # case and spaces
            @test BAYSOL.font_available("No Such Font Zzz") === false
        end
    end

    @testset "results: no MAP (all diverged) skips the residuals, not the run" begin
        result, data, _ = synthetic_result(with_map = false)
        mktempdir() do dir
            files = results(result, data; dir, preview = false)
            names = basename.(files)
            @test "res.tex" in names && "res_hist_c1.tex" in names
            @test !("res_residuals.tex" in names)
            sheets = BAYSOL.Pipeline.XLSX.sheetnames(
                BAYSOL.Pipeline.XLSX.readxlsx(joinpath(dir, "res.xlsx")))
            @test "data" in sheets && !("model" in sheets) && !("residuals" in sheets)
        end
    end

    @testset "results: bad input" begin
        result, (q, I, σ), _ = synthetic_result()
        @test_throws ArgumentError results(
            result,
            (q, I[1:(end-1)], σ);
            preview = false,
        )
    end

    @testset "timing: the stages of the plot group and the plotting row" begin
        result, data, I_true = synthetic_result()
        log = result[1].timing
        mktempdir() do dir
            results(result, data; dir, preview = false,
                references = Reference("CRYSOL", data[1], I_true))
        end
        top = [s.name for s in log.stages if s.group === :plot && s.depth == 1]
        @test top == [
            "summary data", "fit", "residuals", "histogram data",
            ["histogram " * h[4] for h in PLOT_HIST_PARAMS]..., "comparison CRYSOL",
            "data files",
        ]
        child = [s.name for s in log.stages if s.group === :plot && s.depth == 2]
        @test all(in(("data", "tex")), child)             # no preview, no LaTeX
        pl = first(stage_seconds(log, :plot))
        @test pl > 0
        t = BAYSOL.Pipeline._timing_table(log, tick())
        plotting = only(filter(r -> r.name == "plotting", t.rows))
        @test plotting.depth == 1 && plotting.secs ≈ pl
        @test t.plot ≈ pl atol = 0.01
        @test t.fit + t.plot ≈ t.rows[1].secs
        # without any plot stage there is no plotting group, and the plot timing is 0
        t2 = BAYSOL.Pipeline._timing_table(StageLog(), tick())
        @test !any(r -> r.name == "plotting", t2.rows) && t2.plot == 0
    end
end
