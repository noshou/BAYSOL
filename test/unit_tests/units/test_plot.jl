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
    _histogram_data, _rgba, _write_timing, _log_ticks, _linear_ticks, _tick_labels,
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

    @testset "results: files, names and the TSV" begin
        result, data, I_true = synthetic_result()
        q = data[1]
        mktempdir() do dir
            files = results(result, data; dir, name = "res_x", preview = false,
                io = IOBuffer(),
                references = Reference("CRYSOL fit1", q, I_true .* 1.02))
            names = basename.(files)
            # the layout: .tex in plots/, TSV in data/, nothing else in the folder
            @test sort(readdir(dir)) == ["data", "plots"]
            tex_files = ["res_x.tex", "res_x_residuals.tex", "res_x_comparison.tex",
                ["res_x_hist_$(h[4]).tex" for h in PLOT_HIST_PARAMS]...]
            tsv_files = ["res_x_run.tsv", "res_x_map.tsv", "res_x_quantiles_16-84.tsv",
                "res_x_stdev_from_prior.tsv", "res_x_ref_CRYSOL_fit1.tsv",
                "res_x_data.tsv", "res_x_model.tsv", "res_x_residuals.tsv",
                "res_x_draws.tsv",
                ["res_x_hist_$(h[4]).tsv" for h in PLOT_HIST_PARAMS]...]
            for f in tex_files
                @test f in names && isfile(joinpath(dir, "plots", f))
            end
            for f in tsv_files
                @test f in names && isfile(joinpath(dir, "data", f))
            end
            @test sort(readdir(joinpath(dir, "plots"))) == sort(tex_files)
            @test sort(readdir(joinpath(dir, "data"))) == sort(tsv_files)
            @test !any(endswith(".pdf"), names)             # LaTeX is not run by default
            @test !("res_x_hist.tsv" in names)              # one TSV for each histogram
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
            lines = readlines(joinpath(dir, "data", "res_x_data.tsv"))
            @test lines[1] == "q\tI\tsigma" && length(lines) == length(q) + 1
            @test split(readlines(joinpath(dir, "data", "res_x_model.tsv"))[1], '\t') ==
                  ["q", "I_map", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"]
            # a histogram's TSV: its bins and counts,
            # which add up to the non-divergent draws
            hl = readlines(joinpath(dir, "data", "res_x_hist_rho_e.tsv"))
            @test hl[1] == "bin_lo\tbin_hi\tcount" && length(hl) == 1 + PLOT_HIST_BINS
            n_ok = count(s -> !s.numerical_error, result[1].stats)
            @test sum(parse(Int, split(l, '\t')[3]) for l in hl[2:end]) == n_ok
            dl = readlines(joinpath(dir, "data", "res_x_draws.tsv"))
            @test length(dl) == 301 &&
                  startswith(dl[1], "chain\titeration\tdivergent\trho_e")
            # every 50th diverged
            @test count(l -> split(l, '\t')[3] == "1", dl[2:end]) == 6
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
            @test !any(endswith(".tsv"), names)
            tex = read(joinpath(dir, "plots", "res.tex"), String)
            @test occursin("\\definecolor{bsmap}{RGB}{0,0,255}", tex)
            @test occursin("\\setmainfont{Some Text Font}", tex)
            @test occursin("\\setmathfont{Some Math Font}", tex)
        end
        mktempdir() do dir                                # tex = false writes no .tex
            files =
                results(
                    result,
                    data;
                    dir,
                    preview = false,
                    tex = false,
                )
            @test isempty(files) && isempty(readdir(dir))
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

    @testset "each histogram is a figure of its own; the TSV stays combined" begin
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
            # one TSV each
            @test count(contains("_hist_"), filter(endswith(".tsv"), files)) == 7
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
                tex = false,
                references = Reference("CRYSOL", seed.shannon.q, seed.shannon.I))
            @test basename.(files) == ["res_w.xlsx"]
            @test readdir(dir) == ["res_w.xlsx"]       # no data/ folder, no .part left over
            xf = XLSX.readxlsx(joinpath(dir, "res_w.xlsx"))
            sheets = XLSX.sheetnames(xf)
            @test sheets[1:4] == ["run", "map", "quantiles_16-84", "stdev_from_prior"]
            @test all(in(sheets), ["data", "model", "residuals", "draws", "ref_CRYSOL"])
            @test all(in(sheets), ["hist_" * h[4] for h in PLOT_HIST_PARAMS])
            # sheet and column names are plain ASCII
            @test all(isascii, sheets)
            @test all(isascii, string.(xf["draws"][:][1, :]))
            # run: a key and a number on every row, the binning and the chains among them
            run = xf["run"][:]
            @test string.(run[1, :]) == ["key", "value"]
            keys_ = string.(run[2:end, 1])
            for k in ("n_atoms", "lmax", "dmax", "rebin_channels", "rebin_measured",
                "rebin_fitted", "rebin_non_positive_dropped", "tree_depth_avg",
                "tree_depth_max", "ebfmi", "excl_vol_sat", "chains_pooled", "chains_run",
                "rhat_max", "ess_min", "ess_tail_min")
                @test k in keys_
            end
            @test all(x -> x isa Real, run[2:end, 2])
            # map and quantiles: one row for each reported quantity
            nk = length(BAYSOL.Pipeline._REPORT_KEYS)
            m = xf["map"][:]
            @test string.(m[1, :]) == ["parameter", "value"] && size(m, 1) == 1 + nk
            @test m[2, 1] == "log_density" && m[end, 1] == "chi2"
            q = xf["quantiles_16-84"][:]
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
            # write_timings prints the timing table and adds it as the `timings` sheet
            buf = IOBuffer()
            BAYSOL.write_timings(buf, result)
            text = String(take!(buf))
            @test startswith(text, "stage") && !occursin("=== ", text)
            xf = XLSX.readxlsx(joinpath(dir, "res_w.xlsx"))
            @test XLSX.sheetnames(xf)[end] == "timings"
            t = xf["timings"][:]
            @test string.(t[1, :]) == ["stage", "depth", "seconds", "percent_wall",
                "jit_seconds", "note"]
            @test startswith(t[2, 1], "wall clock") && t[2, 2] == 0 && t[2, 4] == 100.0
            @test string.(t[(end-2):end, 1]) == ["gc", "fit_timing", "plot_timing"]
            # the sheet and the text come from the same rows
            wall_text =
                parse(Float64, match(r"^wall clock.* (\S+) +100\.0"m, text).captures[1])
            @test isapprox(t[2, 3], wall_text; atol = 0.006)
            plot_text = parse(Float64, match(r"plot timing = (\S+) s", text).captures[1])
            @test isapprox(t[end, 3], plot_text; atol = 0.006)
            @test any(==("propka"), string.(t[:, 1])) ||
                  any(==("plotting"), string.(t[:, 1]))
            # a second call replaces the sheet instead of adding another
            BAYSOL.write_timings(IOBuffer(), result)
            xf = XLSX.readxlsx(joinpath(dir, "res_w.xlsx"))
            @test count(==("timings"), XLSX.sheetnames(xf)) == 1
        end
        # :both writes the workbook and the TSV files; :tsv no workbook; :none nothing
        for (mode, xlsx, tsv) in ((:both, true, true), (:tsv, false, true),
            (:none, false, false))
            mktempdir() do dir
                results(result, seed; dir, preview = false, tex = false, tables = mode)
                @test isfile(joinpath(dir, "res.xlsx")) == xlsx
                @test isfile(joinpath(dir, "data", "res_run.tsv")) == tsv
            end
        end
        @test_throws ArgumentError results(result, seed;)
    end

    @testset "tables: numbers carry TABLE_SIGFIGS significant figures" begin
        P = BAYSOL.Pipeline
        @test P.TABLE_SIGFIGS == 17
        x = 0.1 + 0.2
        @test parse(Float64, P._f(x)) === x                  # every bit is written
        @test P._f(2) == "2" && P._f(1.0e-8) == "1e-08"
        @test P._cell(x) === x && P._cell(7) === 7 && isnan(P._cell(NaN))
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
        # the files results and write_timings wrote are named, the wall clock is last
        mktempdir() do dir
            results(result, data; dir, preview = false)
            BAYSOL.write_timings(joinpath(dir, "res_timings.txt"), result)
            lines = BAYSOL.Pipeline._summary_lines(result)
            files = only(filter(contains("Results:"), lines))
            @test occursin("res.xlsx", files) && occursin("Figures: ", files) &&
                  occursin("plots/", files) && occursin("res_timings.txt", files)
            @test startswith(lines[end], "Wall clock: ")
            io = IOBuffer()
            BAYSOL.print_summary(io, result)
            @test String(take!(io)) == join(lines, '\n') * "\n"
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
            @test !("res_residuals.tex" in names) && !("res_model.tsv" in names)
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

    @testset "timing: stages of the plot group and the last two lines of the table" begin
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
        buf = IOBuffer()
        _write_timing(buf, log, tick())
        text = String(take!(buf))
        lines = split(strip(text), '\n')
        @test occursin(
            r"^  plotting\s+\d",
            lines[findfirst(startswith("  plotting"), lines)],
        )
        @test startswith(lines[end-1], "fit timing  = ") &&
              startswith(lines[end], "plot timing = ")
        fit_s = parse(Float64, match(r"= (\S+) s", lines[end-1]).captures[1])
        plot_s = parse(Float64, match(r"= (\S+) s", lines[end]).captures[1])
        wall =
            parse(Float64, match(r"(?m)^wall clock.*?\s(\S+)\s+100\.0", text).captures[1])
        @test plot_s ≈ pl atol = 0.01
        @test fit_s + plot_s ≈ wall atol = 0.02
        # without any plot stage there is no plotting group, and the plot timing is 0
        buf2 = IOBuffer()
        _write_timing(buf2, StageLog(), tick())
        t2 = String(take!(buf2))
        @test !occursin("plotting", t2) && endswith(strip(t2), "plot timing = 0 s")
    end
end
