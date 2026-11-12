# SPDX-License-Identifier: LGPL-3.0-or-later

# Every setting of the catalog is a keyword of `seed_model`, `run_model` or `results`, so
# that code that uses the library supplies what the terminal interface keeps in
# settings.json. Here the real entry points run on crambin: with the keywords at their
# constants (or from the helpers on the default settings) the result is that of the call
# without them, and non-default values reach the code that reads them (the support of the
# priors, the c1 window, the sampler's options, the precision of the tables).
# The table of settings and keywords is checked at the end of this file; the reading of
# settings.json is tested in tui/test/settings-file.test.jl.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
using Distributions: mean, params
using BAYSOL.Pipeline:
    XLSX, InvalidSettingsError, _checked_value, _setting_names,
    _setting_default

const _KW_CRAMBIN = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")
const _KW_DEFAULTS = default_settings()

# the arguments of seed_model: a smooth curve of 30 points
function _kw_args()
    q = collect(range(0.02, 0.30; length = 30))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
    return (LocalPathSource(_KW_CRAMBIN), 9000.0, q, I, 0.02 .* I, 7.0, 0.1, solutes)
end

quiet(f) = redirect_stdout(f, devnull)

@testset "the settings as keywords of the entry points" begin
    args = _kw_args()
    s0 = BAYSOL.seed_model(args...; add_hydrogens = false)

    @testset "seed_model: the helper on the default settings is the default call" begin
        # (the helper carries `add_hydrogens` too, so the test's own comes last)
        sd = BAYSOL.seed_model(
            args...; BAYSOL.seed_keywords(_KW_DEFAULTS)..., add_hydrogens = false,
        )
        @test sd.θ₀ == s0.θ₀ && sd.pr == s0.pr
        @test sd.fw.qvals == s0.fw.qvals && sd.fw.n_atoms == s0.fw.n_atoms
        @test sd.c1tab.cs == s0.c1tab.cs && sd.c1tab.g1 == s0.c1tab.g1
        @test all(
            f -> getfield(sd.wls, f) == getfield(s0.wls, f),
            fieldnames(typeof(sd.wls)),
        )
    end

    @testset "seed_model: changed settings reach the code that reads them" begin
        s1 = BAYSOL.seed_model(
            args...; add_hydrogens = false, bounds_δρ₁₂ = (-6, 3), mode_δρ₁₂ = 0.5,
            φ_max = 1.1, excl_vol_corr_bounds = (0.9, 1.2), excl_vol_corr_eps = 0.025,
            shell_area_per_point = 8.0, shell_min_points = 60, shell_sample = 128,
            sasa_n_occ = 64, bead_ray_range = 10.0, bead_ray_dirs = 32,
        )
        @test (s1.pr.δρ₁Prior.μ, s1.pr.δρ₁Prior.σ) == (-6.0, 9.0)
        α, β = params(s1.pr.δρ₁Prior.ρ)
        @test s1.pr.δρ₁Prior.μ + s1.pr.δρ₁Prior.σ * (α - 1) / (α + β - 2) ≈ 0.5
        top3 = s1.pr.δρ₃Prior.μ + s1.pr.δρ₃Prior.σ
        @test top3 ≈ 0.1 * mean(s1.pr.ρₑPrior) / BAYSOL.Inference.UNIT_OF_δρ
        @test (s1.c1tab.cmin, s1.c1tab.cmax, s1.c1tab.eps) == (0.9, 1.2, 0.025)
        # a coarser shell: fewer beads, so a smaller forward model than the default
        @test s1.fw.n_atoms == s0.fw.n_atoms
        @test s1.fw.Gc != s0.fw.Gc
        # the run reads the window and the support from the seed, not from the constants
        res = quiet() do
            BAYSOL.run_model(s1, 40, 20; retry = false, n_chains = 2)
        end
        map_params = res[3][1]
        @test 0.9 - 0.025 ≤ map_params["excl_vol_corr"] ≤ 1.2 + 0.025
        @test -6 < map_params["delta_rho_1"] < 3 && -6 < map_params["delta_rho_2"] < 3
        @test map_params["excl_vol_sat"] in (-1.0, 0.0, 1.0)
        @test all(-6 .< getindex.(res[1].samples, 2) .< 3)
    end

    @testset "seed_model: bad values are the errors of load_settings" begin
        InvalidSettingsError = BAYSOL.InvalidSettingsError
        e = try
            BAYSOL.seed_model(args...; add_hydrogens = false, sasa_n_occ = 300)
        catch err
            err
        end
        @test e isa InvalidSettingsError &&
              occursin(
            "SASA_N_OCC = 300: must be at most SHELL_SAMPLE = 256",
            e.problems[1],
        )
        @test_throws InvalidSettingsError BAYSOL.seed_model(
            args...; add_hydrogens = false, mode_δρ₁₂ = 7.0,
        )
        @test_throws InvalidSettingsError BAYSOL.seed_model(
            args...; add_hydrogens = false, φ_max = -1.0,
        )
        @test_throws InvalidSettingsError BAYSOL.seed_model(
            args...; add_hydrogens = false, excl_vol_corr_bounds = (1.3, 0.8),
        )
        # nothing was built for a bad value: the check comes first
        t = @elapsed try
            BAYSOL.seed_model(args...; shell_sample = 0)
        catch
        end
        @test t < 5
    end

    @testset "run_model: the helpers on the default settings are the default call" begin
        a = quiet() do
            BAYSOL.run_model(s0, 40, 20; retry = false, n_chains = 2)
        end
        @test BAYSOL.run_arguments(_KW_DEFAULTS) == (n_samples = 1000, n_adapt = 300)
        c = quiet() do
            BAYSOL.run_model(
                s0, 40, 20;
                merge(
                    BAYSOL.run_keywords(_KW_DEFAULTS),
                    (; retry = false, n_chains = 2),
                )...,
            )
        end
        @test a[1].samples == c[1].samples && a[3][1] == c[3][1]
    end

    @testset "run_model: changed settings reach the sampler, bad ones are refused" begin
        base = quiet() do
            BAYSOL.run_model(s0, 40, 20; retry = false, n_chains = 2)
        end
        few = quiet() do
            BAYSOL.run_model(
                s0, 40, 20; retry = false, n_chains = 2, map_n_starts = 4,
                map_jitter_directions = 1, map_jitter_max_optima = 1,
                optimum_chain_cap = 0, chain_start_radii = (1.0, 2.0, 3.0),
            )
        end
        # fewer starts is another MAP search, so another run
        @test few[1].timing.info["map_modes"] ≥ 1
        @test few[1].diagnostics.n_extra == 0
        @test few[1].samples != base[1].samples
        e = try
            BAYSOL.run_model(s0, 40, 20; retry = false, map_n_starts = 0)
        catch err
            err
        end
        @test e isa BAYSOL.InvalidSettingsError &&
              occursin("MAP_N_STARTS = 0: must be at least 1", e.problems[1])
        @test_throws BAYSOL.InvalidSettingsError BAYSOL.run_model(
            s0, 40, 20; retry = false, optimum_chain_fraction = 2.0,
        )
        @test_throws BAYSOL.InvalidSettingsError BAYSOL.run_model(
            s0, 40, 20; retry = false, map_jitter_radii = (3.0, 0.0, 1.0),
        )
    end

    @testset "results: table_sigfigs" begin
        res = quiet() do
            BAYSOL.run_model(s0, 40, 20; retry = false, n_chains = 2)
        end
        mktempdir() do dir
            full = BAYSOL.results(
                res, s0; dir = joinpath(dir, "a"), name = "x", preview = false,
                tex = false,
                io = devnull,
            )
            short = BAYSOL.results(
                res, s0; dir = joinpath(dir, "b"), name = "x", preview = false,
                tex = false,
                io = devnull, table_sigfigs = 3,
            )
            cell(path) = XLSX.openxlsx(path) do xf
                xf["map"][2, 2]
            end
            xl(v) = only(filter(endswith(".xlsx"), v))
            @test cell(xl(short)) == round(cell(xl(full)); sigdigits = 3)
            @test cell(xl(short)) != cell(xl(full))
            @test_throws BAYSOL.InvalidSettingsError BAYSOL.results(
                res, s0; dir = joinpath(dir, "c"), name = "x", preview = false,
                tex = false, io = devnull, table_sigfigs = 0,
            )
        end
    end

    @testset "results: the terminal plots at several sizes" begin
        P = BAYSOL.Pipeline
        res = quiet() do
            BAYSOL.run_model(s0, 40, 20; retry = false, n_chains = 2)
        end
        # the plots of a text: the blocks between blank lines, as the viewer cuts them
        plots(text) = split(strip(text), r"\n[ \t]*\n")
        width(b) = maximum(textwidth, split(b, '\n'))
        rows(b) = count('\n', b) + 1
        mktempdir() do dir
            sizes = P.PLOT_TUI_SIZES
            plain = IOBuffer()
            with = IOBuffer()
            BAYSOL.results(
                res, s0; dir = joinpath(dir, "a"), name = "x", io = plain, tex = false,
            )
            files = BAYSOL.results(
                res, s0; dir = joinpath(dir, "b"), name = "x", io = with, tex = false,
                tui_dir = joinpath(dir, "b"),
            )
            # the plot of the default size is what it always was, byte for byte
            @test String(take!(with)) == String(take!(plain))
            # nothing is written without a folder for it
            @test !any(f -> occursin("plots_", basename(f)), readdir(joinpath(dir, "a")))
            # a file of each size, in the files returned, the plots the viewer cuts out
            for (W, H) in sizes
                f = joinpath(dir, "b", "plots_$(W)x$(H).txt")
                @test f in files && isfile(f)
                text = read(f, String)
                @test !occursin('\e', text)
                bs = plots(text)
                @test length(bs) == 9               # fit, residuals, 7 histograms
                @test all(b -> width(b) <= W, bs)   # none wider than its size
                # the fit and the residuals are exactly that wide and H + 5 rows tall
                @test all(b -> width(b) == W && rows(b) == H + 5, bs[1:2])
                # a histogram has about H bins: not taller than H + 5 rows
                @test all(b -> rows(b) <= H + 5, bs[3:end])
                @test startswith(strip(replace(bs[1], "\u2800" => " ")), "fit")
                @test occursin("χ²", bs[1])
            end
            # the smallest default fits 76 columns by 10 rows (the viewer's window)
            small = plots(read(joinpath(dir, "b", "plots_76x5.txt"), String))
            @test sizes[1] == (76, 5)
            @test maximum(width, small) <= 76 && maximum(rows, small) <= 10
            # sizes of the caller, in the text of their own
            sizes2 = ((70, 4), (90, 7))
            BAYSOL.results(
                res, s0; dir = joinpath(dir, "c"), name = "x", io = devnull, tex = false,
                tui_dir = joinpath(dir, "c"), plot_tui_sizes = sizes2,
            )
            @test sort(filter(startswith("plots_"), readdir(joinpath(dir, "c")))) ==
                  ["plots_70x4.txt", "plots_90x7.txt"]
            @test all(
                b -> width(b) <= 70,
                plots(read(joinpath(dir, "c", "plots_70x4.txt"), String)),
            )
            # a size that is too small for the labels of a plot (the residuals need about
            # 60 columns) is still drawn, as wide as the plot needs: the width that run.json
            # records is the measured one
            BAYSOL.results(
                res, s0; dir = joinpath(dir, "d"), name = "x", io = devnull, tex = false,
                tui_dir = joinpath(dir, "d"), plot_tui_sizes = ((30, 3),),
            )
            tiny = plots(read(joinpath(dir, "d", "plots_30x3.txt"), String))
            @test length(tiny) == 9 && width(tiny[2]) > 30 && width(tiny[1]) <= 50
        end
    end

    @testset "results: the plot folder and the compiler" begin
        P = BAYSOL.Pipeline
        res = quiet() do
            BAYSOL.run_model(s0, 40, 20; retry = false, n_chains = 2)
        end
        mktempdir() do dir
            # no plot folder (the default ""): nothing is copied
            @test P.FIGURES_DIR == "" && P.FIGURES_COMPILER == ""
            files = BAYSOL.results(
                res, s0; dir = joinpath(dir, "a"), name = "x", preview = false,
                io = devnull,
            )
            tex = filter(endswith(".tex"), files)
            @test !isempty(tex)
            # with one: every `.tex` figure is also there, a file of the same name replaced
            into = joinpath(dir, "plots", "proj", "run", "m")
            mkpath(into)
            write(joinpath(into, basename(first(tex))), "old")
            BAYSOL.results(
                res, s0; dir = joinpath(dir, "b"), name = "x", preview = false,
                io = devnull, plot_dir = into,
            )
            @test sort(readdir(into)) == sort(basename.(tex))
            @test read(joinpath(into, basename(first(tex))), String) != "old"
            # a path is text without control characters
            @test_throws BAYSOL.InvalidSettingsError BAYSOL.results(
                res, s0; dir = joinpath(dir, "c"), name = "x", preview = false,
                io = devnull, tex = false, plot_dir = "a\nb",
            )
            # the engine follows the compiler's own name; a path that is set is not replaced
            fake = joinpath(dir, "pdflatex")
            write(fake, "")
            @test P._engine_kwargs(nothing, fake) == (; latex_engine = P.PGF.PDFLATEX)
            xe = joinpath(dir, "XeLaTeX.exe")
            write(xe, "")
            @test P._engine_kwargs("TeX Gyre PagellaX", xe) ==
                  (; latex_engine = P.PGF.XELATEX)
            @test_throws ErrorException P._engine_kwargs("TeX Gyre PagellaX", fake)
            @test_throws ErrorException P._engine_kwargs(nothing, joinpath(dir, "nope"))
            other = joinpath(dir, "latex")
            write(other, "")
            @test_throws ErrorException P._engine_kwargs(nothing, other)
        end
    end
end

# ---------------------------------------------------------------------------
# every setting is a keyword of an entry point (the owner's rule: a user of the library
# passes what the terminal interface keeps in settings.json)
# ---------------------------------------------------------------------------

@testset "every setting is a keyword of an entry point" begin
    P = BAYSOL.Pipeline
    rows = P.SETTING_KEYWORDS
    # the keyword names of all methods of `f`
    kws(f) = Set(reduce(vcat, [Base.kwarg_decl(m) for m in methods(f)]))
    positional(f) = Set(reduce(vcat, [Base.method_argnames(m)[2:end] for m in methods(f)]))

    @testset "the table covers the catalog exactly" begin
        @test allunique(r.setting for r in rows)
        @test Set(r.setting for r in rows) == Set(_setting_names())
        @test length(rows) == 96
    end

    @testset "the keyword exists where the table says" begin
        for r in rows
            if r.entry === :seed_model
                @test r.keyword in kws(BAYSOL.seed_model)
            elseif r.entry === :run_model
                @test r.keyword in kws(BAYSOL.run_model)
            elseif r.entry === :results
                @test r.keyword in kws(BAYSOL.results)
            elseif r.entry === :run_project
                # a switch of the run alone (checked through run_project's overrides, in
                # tui/test/run-project.test.jl)
                @test !(r.keyword in kws(BAYSOL.results))
            elseif r.entry === :run_model_args
                # the positional `n_adapt` of run_model; `n_samples` is N_ADAPT + N_DRAWS
                @test :n_adapt in positional(BAYSOL.run_model) &&
                      :n_samples in positional(BAYSOL.run_model)
            elseif r.entry === :PlotStyle
                @test r.keyword in fieldnames(BAYSOL.PlotStyle)
            else
                @test false
            end
        end
        @test :style in kws(BAYSOL.results)
        @test :font in kws(BAYSOL.results)
        # checked keywords (the new ones) are exactly the ones validated at the entry
        @test all(
            r -> r.entry in (:seed_model, :run_model, :results),
            filter(r -> r.check, rows),
        )
        # the 30 that had no keyword, 6 data ones, the terminal plot sizes, the plot dir,
        # the compiler
        @test count(r -> r.check, rows) == 39
    end

    defaults = default_settings()

    @testset "the helpers carry the defaults of the settings" begin
        for (helper, entry) in (
            (BAYSOL.seed_keywords, :seed_model), (BAYSOL.run_keywords, :run_model),
        )
            k = helper(defaults)
            mine = filter(r -> r.entry === entry, rows)
            @test collect(keys(k)) == [r.keyword for r in mine]
            for r in mine
                @test k[r.keyword] == _setting_default(r.setting)
            end
        end
        rk = BAYSOL.results_keywords(defaults)
        @test rk.table_sigfigs == 17 && rk.tex == true && rk.compile == false
        @test rk.formats == (:pdf,) && rk.style == BAYSOL.PlotStyle()
        @test BAYSOL.run_arguments(defaults) == (n_samples = 1000, n_adapt = 300)
        @test length(BAYSOL.seed_keywords(defaults)) == 24
        @test length(BAYSOL.run_keywords(defaults)) == 22
        # a changed setting is the keyword
        s = copy(defaults)
        s[:MAP_N_STARTS] = 9
        s[:SASA_N_OCC] = 100
        s[:N_ADAPT] = 50
        s[:N_DRAWS] = 70
        s[:PLOT_LW_MAP] = 3.5
        @test BAYSOL.run_keywords(s).map_n_starts == 9
        @test BAYSOL.seed_keywords(s).sasa_n_occ == 100
        @test BAYSOL.run_arguments(s) == (n_samples = 120, n_adapt = 50)
        @test BAYSOL.results_keywords(s).style.lw_map == 3.5
        # the run keywords build the sampler options the defaults build
        ck = P._checked_keywords(
            :run_model,
            NamedTuple{Tuple(r.keyword for r in rows if r.entry === :run_model && r.check)}(
                Tuple(
                    BAYSOL.run_keywords(defaults)[r.keyword]
                    for r in rows if r.entry === :run_model && r.check
                )),
        )
        a, b = BAYSOL.Inference.SamplerOptions(; ck...), BAYSOL.Inference.SamplerOptions()
        @test all(f -> getfield(a, f) == getfield(b, f), fieldnames(typeof(a)))
    end

    @testset "the keywords are checked as load_settings checks the settings" begin
        chk = P._checked_keywords
        # the defaults pass and come back unchanged, in the types of the defaults
        ok = chk(
            :seed_model,
            (; shell_sample = 256, sasa_n_occ = 104, φ_max = 2,
                bounds_δρ₁₂ = (-10, 2), mode_δρ₁₂ = 1, excl_vol_corr_bounds = [0.8, 1.3]),
        )
        @test ok.shell_sample === 256 && ok.φ_max === 2.0
        @test ok.bounds_δρ₁₂ === (-10.0, 2.0) && ok.excl_vol_corr_bounds === (0.8, 1.3)
        # one bad value, the line is the one load_settings gives
        for (entry, kw, setting, words) in (
            (:run_model, (; map_n_starts = 0), "MAP_N_STARTS", "at least 1"),
            (:run_model, (; map_jitter_radii = (3.0, -1.0, 12.0)), "MAP_JITTER_RADII",
                "above 0"),
            (:run_model, (; optimum_chain_fraction = 1.5), "OPTIMUM_CHAIN_FRACTION",
                "at most 1"),
            (:run_model, (; chain_start_radii = (4.0, 10.0)), "CHAIN_START_RADII",
                "3 parts"),
            (:run_model, (; harvest_cover = -1), "HARVEST_COVER", "at least 0"),
            (:run_model, (; basin_restart_nats = NaN), "BASIN_RESTART_NATS", "finite"),
            (:run_model, (; retry_n_draws = 1.5), "RETRY_N_DRAWS", "whole number"),
            (:seed_model, (; φ_max = 0), "φ_max", "above 0"),
            (:seed_model, (; shell_min_points = 0), "SHELL_MIN_POINTS", "at least 1"),
            (:seed_model, (; bead_ray_range = -2.0), "BEAD_RAY_RANGE", "above 0"),
            (:results, (; table_sigfigs = 0), "TABLE_SIGFIGS", "at least 1"),
            (:results, (; table_sigfigs = 18), "TABLE_SIGFIGS", "at most 17"),
        )
            e = try
                chk(entry, kw)
            catch err
                err
            end
            @test e isa InvalidSettingsError
            @test length(e.problems) == 1 && startswith(e.problems[1], setting * " = ")
            @test occursin(words, e.problems[1])
            # the same text as `load_settings` for the same value
            name = Symbol(setting)
            msg = try
                _checked_value(name, P._setting_input(first(values(kw))))
                ""
            catch err
                err.msg
            end
            # (a rule between settings, not a limit of one, is the relations' text)
            @test isempty(msg) || endswith(e.problems[1], ": " * msg)
        end
        # the relations between settings, with the same lines
        for (kw, setting, words) in (
            ((; bounds_δρ₁₂ = (-10.0, 2.0), mode_δρ₁₂ = 5.0), "MODE_δρ₁₂",
                "strictly inside BOUNDS_δρ₁₂"),
            ((; bounds_δρ₁₂ = (2.0, -10.0), mode_δρ₁₂ = 1.0), "BOUNDS_δρ₁₂",
                "first part below its second"),
            ((; excl_vol_corr_bounds = (0.8, 0.82), excl_vol_corr_eps = 0.05),
                "EXCL_VOL_CORR_EPS", "at most the width"),
            ((; shell_sample = 64, sasa_n_occ = 100), "SASA_N_OCC",
                "at most SHELL_SAMPLE"),
        )
            e = try
                chk(:seed_model, kw)
            catch err
                err
            end
            @test e isa InvalidSettingsError
            @test any(p -> startswith(p, setting * " = ") && occursin(words, p), e.problems)
        end
        # all the problems at once; the error says the values were keywords
        e = try
            chk(:run_model, (; map_n_starts = 0, harvest_cover = -1))
        catch err
            err
        end
        @test length(e.problems) == 2
        @test occursin("passed as keywords", sprint(showerror, e))
        # the settings-file error keeps its hint
        @test occursin("terminal interface", sprint(showerror, InvalidSettingsError(["x"])))
        # a valid pair is fine where each alone would not be
        @test chk(:seed_model, (; shell_sample = 64, sasa_n_occ = 64)).sasa_n_occ == 64
        @test chk(:seed_model, (; bounds_δρ₁₂ = (-4, 6), mode_δρ₁₂ = 5)).mode_δρ₁₂ === 5.0
    end

    @testset "the overrides of run_project are checked together with the settings" begin
        s = copy(defaults)
        P._apply_keywords!(
            s,
            (; map_n_starts = 9, tex = nothing, formats = (:pdf, :svg),
                n_draws = 5, mode_δρ₁₂ = nothing),
        )
        @test s[:MAP_N_STARTS] == 9 && s[:N_DRAWS] == 5 && s[:TARGET_ACCEPT] == 95
        @test s[:FIGURES_FORMATS] == (:pdf, :svg)
        # a rule against a value of the file is caught too
        t = copy(defaults)
        t[:SHELL_SAMPLE] = 100
        @test_throws InvalidSettingsError P._apply_keywords!(t, (; sasa_n_occ = 104))
        @test t[:SASA_N_OCC] == 104                       # unchanged on failure
        u = copy(defaults)
        @test_throws InvalidSettingsError P._apply_keywords!(u, (; thickness = -1.0))
        @test u[:SHELL_THICKNESS] == 3.0
    end
end
