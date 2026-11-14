# SPDX-License-Identifier: LGPL-3.0-or-later

# Every setting of the catalog is a keyword of `seedModel`, `runModel` or `results`, so
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
    XLSX, InvalidSettingsError, _checkedValue, _settingNames,
    _settingDefault

const _KW_CRAMBIN = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")
const _KW_DEFAULTS = defaultSettings()

# the arguments of seedModel: a smooth curve of 30 points
function _kwArgs()
    q = collect(range(0.02, 0.30; length = 30))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
    return (LocalPathSource(_KW_CRAMBIN), 9000.0, q, I, 0.02 .* I, 7.0, 0.1, solutes)
end

quiet(f) = redirect_stdout(f, devnull)

@testset "the settings as keywords of the entry points" begin
    args = _kwArgs()
    s0 = BAYSOL.seedModel(args...; addHydrogens = false)

    @testset "seedModel: the helper on the default settings is the default call" begin
        # (the helper carries `addHydrogens` too, so the test's own comes last)
        sd = BAYSOL.seedModel(
            args...; BAYSOL.seedKeywords(_KW_DEFAULTS)..., addHydrogens = false,
        )
        @test sd.θ₀ == s0.θ₀ && sd.pr == s0.pr
        @test sd.fw.qvals == s0.fw.qvals && sd.fw.nAtoms == s0.fw.nAtoms
        @test sd.c1tab.cs == s0.c1tab.cs && sd.c1tab.g1 == s0.c1tab.g1
        @test all(
            f -> getfield(sd.wls, f) == getfield(s0.wls, f),
            fieldnames(typeof(sd.wls)),
        )
    end

    @testset "seedModel: changed settings reach the code that reads them" begin
        s1 = BAYSOL.seedModel(
            args...; addHydrogens = false, bounds_δρ₁₂ = (-6, 3), mode_δρ₁₂ = 0.5,
            φ_max = 1.1, exclVolCorrBounds = (0.9, 1.2), exclVolCorrEps = 0.025,
            shellAreaPerPoint = 8.0, shellMinPoints = 60, shellSample = 128,
            sasaNOcc = 64, beadRayRange = 10.0, beadRayDirs = 32,
        )
        @test (s1.pr.δρ₁Prior.μ, s1.pr.δρ₁Prior.σ) == (-6.0, 9.0)
        α, β = params(s1.pr.δρ₁Prior.ρ)
        @test s1.pr.δρ₁Prior.μ + s1.pr.δρ₁Prior.σ * (α - 1) / (α + β - 2) ≈ 0.5
        top3 = s1.pr.δρ₃Prior.μ + s1.pr.δρ₃Prior.σ
        @test top3 ≈ 0.1 * mean(s1.pr.ρₑPrior) / BAYSOL.Inference.UNIT_OF_δρ
        @test (s1.c1tab.cmin, s1.c1tab.cmax, s1.c1tab.eps) == (0.9, 1.2, 0.025)
        # a coarser shell: fewer beads, so a smaller forward model than the default
        @test s1.fw.nAtoms == s0.fw.nAtoms
        @test s1.fw.gc != s0.fw.gc
        # the run reads the window and the support from the seed, not from the constants
        res = quiet() do
            BAYSOL.runModel(s1, 40, 20; retry = false, nChains = 2)
        end
        mapParams = res[3][1]
        @test 0.9 - 0.025 ≤ mapParams["exclVolCorr"] ≤ 1.2 + 0.025
        @test -6 < mapParams["deltaRho1"] < 3 && -6 < mapParams["deltaRho2"] < 3
        @test mapParams["exclVolSat"] in (-1.0, 0.0, 1.0)
        @test all(-6 .< getindex.(res[1].samples, 2) .< 3)
    end

    @testset "seedModel: bad values are the errors of loadSettings" begin
        InvalidSettingsError = BAYSOL.InvalidSettingsError
        e = try
            BAYSOL.seedModel(args...; addHydrogens = false, sasaNOcc = 300)
        catch err
            err
        end
        @test e isa InvalidSettingsError &&
              occursin(
            "SASA_N_OCC = 300: must be at most SHELL_SAMPLE = 256",
            e.problems[1],
        )
        @test_throws InvalidSettingsError BAYSOL.seedModel(
            args...; addHydrogens = false, mode_δρ₁₂ = 7.0,
        )
        @test_throws InvalidSettingsError BAYSOL.seedModel(
            args...; addHydrogens = false, φ_max = -1.0,
        )
        @test_throws InvalidSettingsError BAYSOL.seedModel(
            args...; addHydrogens = false, exclVolCorrBounds = (1.3, 0.8),
        )
        # nothing was built for a bad value: the check comes first
        t = @elapsed try
            BAYSOL.seedModel(args...; shellSample = 0)
        catch
        end
        @test t < 5
    end

    @testset "runModel: the helpers on the default settings are the default call" begin
        a = quiet() do
            BAYSOL.runModel(s0, 40, 20; retry = false, nChains = 2)
        end
        @test BAYSOL.runArguments(_KW_DEFAULTS) == (nSamples = 1000, nAdapt = 300)
        c = quiet() do
            BAYSOL.runModel(
                s0, 40, 20;
                merge(
                    BAYSOL.runKeywords(_KW_DEFAULTS),
                    (; retry = false, nChains = 2),
                )...,
            )
        end
        @test a[1].samples == c[1].samples && a[3][1] == c[3][1]
    end

    @testset "runModel: changed settings reach the sampler, bad ones are refused" begin
        base = quiet() do
            BAYSOL.runModel(s0, 40, 20; retry = false, nChains = 2)
        end
        few = quiet() do
            BAYSOL.runModel(
                s0, 40, 20; retry = false, nChains = 2, mapNStarts = 4,
                mapJitterDirections = 1, mapJitterMaxOptima = 1,
                optimumChainCap = 0, chainStartRadii = (1.0, 2.0, 3.0),
            )
        end
        # fewer starts is another MAP search, so another run
        @test few[1].timing.info["mapModes"] ≥ 1
        @test few[1].diagnostics.nExtra == 0
        @test few[1].samples != base[1].samples
        e = try
            BAYSOL.runModel(s0, 40, 20; retry = false, mapNStarts = 0)
        catch err
            err
        end
        @test e isa BAYSOL.InvalidSettingsError &&
              occursin("MAP_N_STARTS = 0: must be at least 1", e.problems[1])
        @test_throws BAYSOL.InvalidSettingsError BAYSOL.runModel(
            s0, 40, 20; retry = false, optimumChainFraction = 2.0,
        )
        @test_throws BAYSOL.InvalidSettingsError BAYSOL.runModel(
            s0, 40, 20; retry = false, mapJitterRadii = (3.0, 0.0, 1.0),
        )
    end

    @testset "results: tableSigfigs" begin
        res = quiet() do
            BAYSOL.runModel(s0, 40, 20; retry = false, nChains = 2)
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
                io = devnull, tableSigfigs = 3,
            )
            cell(path) = XLSX.openxlsx(path) do xf
                xf["map"][2, 2]
            end
            xl(v) = only(filter(endswith(".xlsx"), v))
            @test cell(xl(short)) == round(cell(xl(full)); sigdigits = 3)
            @test cell(xl(short)) != cell(xl(full))
            @test_throws BAYSOL.InvalidSettingsError BAYSOL.results(
                res, s0; dir = joinpath(dir, "c"), name = "x", preview = false,
                tex = false, io = devnull, tableSigfigs = 0,
            )
        end
    end

    @testset "results: the terminal plots at several sizes" begin
        P = BAYSOL.Pipeline
        res = quiet() do
            BAYSOL.runModel(s0, 40, 20; retry = false, nChains = 2)
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
                tuiDir = joinpath(dir, "b"),
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
                tuiDir = joinpath(dir, "c"), plotTuiSizes = sizes2,
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
                tuiDir = joinpath(dir, "d"), plotTuiSizes = ((30, 3),),
            )
            tiny = plots(read(joinpath(dir, "d", "plots_30x3.txt"), String))
            @test length(tiny) == 9 && width(tiny[2]) > 30 && width(tiny[1]) <= 50
        end
    end

    @testset "results: the plot folder and the compiler" begin
        P = BAYSOL.Pipeline
        res = quiet() do
            BAYSOL.runModel(s0, 40, 20; retry = false, nChains = 2)
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
                io = devnull, plotDir = into,
            )
            @test sort(readdir(into)) == sort(basename.(tex))
            @test read(joinpath(into, basename(first(tex))), String) != "old"
            # a path is text without control characters
            @test_throws BAYSOL.InvalidSettingsError BAYSOL.results(
                res, s0; dir = joinpath(dir, "c"), name = "x", preview = false,
                io = devnull, tex = false, plotDir = "a\nb",
            )
            # the engine follows the compiler's own name; a path that is set is not replaced
            fake = joinpath(dir, "pdflatex")
            write(fake, "")
            @test P._engineKwargs(nothing, fake) == (; latex_engine = P.PGF.PDFLATEX)
            xe = joinpath(dir, "XeLaTeX.exe")
            write(xe, "")
            @test P._engineKwargs("TeX Gyre PagellaX", xe) ==
                  (; latex_engine = P.PGF.XELATEX)
            @test_throws ErrorException P._engineKwargs("TeX Gyre PagellaX", fake)
            @test_throws ErrorException P._engineKwargs(nothing, joinpath(dir, "nope"))
            other = joinpath(dir, "latex")
            write(other, "")
            @test_throws ErrorException P._engineKwargs(nothing, other)
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
        @test Set(r.setting for r in rows) == Set(_settingNames())
        @test length(rows) == 96
    end

    @testset "the keyword exists where the table says" begin
        for r in rows
            if r.entry === :seedModel
                @test r.keyword in kws(BAYSOL.seedModel)
            elseif r.entry === :runModel
                @test r.keyword in kws(BAYSOL.runModel)
            elseif r.entry === :results
                @test r.keyword in kws(BAYSOL.results)
            elseif r.entry === :runProject
                # a switch of the run alone (checked through runProject's overrides, in
                # tui/test/run-project.test.jl)
                @test !(r.keyword in kws(BAYSOL.results))
            elseif r.entry === :runModelArgs
                # the positional `nAdapt` of runModel; `nSamples` is N_ADAPT + N_DRAWS
                @test :nAdapt in positional(BAYSOL.runModel) &&
                      :nSamples in positional(BAYSOL.runModel)
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
            r -> r.entry in (:seedModel, :runModel, :results),
            filter(r -> r.check, rows),
        )
        # the 30 that had no keyword, 6 data ones, the terminal plot sizes, the plot dir,
        # the compiler
        @test count(r -> r.check, rows) == 39
    end

    defaults = defaultSettings()

    @testset "the helpers carry the defaults of the settings" begin
        for (helper, entry) in (
            (BAYSOL.seedKeywords, :seedModel), (BAYSOL.runKeywords, :runModel),
        )
            k = helper(defaults)
            mine = filter(r -> r.entry === entry, rows)
            @test collect(keys(k)) == [r.keyword for r in mine]
            for r in mine
                @test k[r.keyword] == _settingDefault(r.setting)
            end
        end
        rk = BAYSOL.resultsKeywords(defaults)
        @test rk.tableSigfigs == 17 && rk.tex == true && rk.compile == false
        @test rk.formats == (:pdf,) && rk.style == BAYSOL.PlotStyle()
        @test BAYSOL.runArguments(defaults) == (nSamples = 1000, nAdapt = 300)
        @test length(BAYSOL.seedKeywords(defaults)) == 24
        @test length(BAYSOL.runKeywords(defaults)) == 22
        # a changed setting is the keyword
        s = copy(defaults)
        s[:MAP_N_STARTS] = 9
        s[:SASA_N_OCC] = 100
        s[:N_ADAPT] = 50
        s[:N_DRAWS] = 70
        s[:PLOT_LW_MAP] = 3.5
        @test BAYSOL.runKeywords(s).mapNStarts == 9
        @test BAYSOL.seedKeywords(s).sasaNOcc == 100
        @test BAYSOL.runArguments(s) == (nSamples = 120, nAdapt = 50)
        @test BAYSOL.resultsKeywords(s).style.lwMap == 3.5
        # the run keywords build the sampler options the defaults build
        ck = P._checkedKeywords(
            :runModel,
            NamedTuple{Tuple(r.keyword for r in rows if r.entry === :runModel && r.check)}(
                Tuple(
                    BAYSOL.runKeywords(defaults)[r.keyword]
                    for r in rows if r.entry === :runModel && r.check
                )),
        )
        a, b = BAYSOL.Inference.SamplerOptions(; ck...), BAYSOL.Inference.SamplerOptions()
        @test all(f -> getfield(a, f) == getfield(b, f), fieldnames(typeof(a)))
    end

    @testset "the keywords are checked as loadSettings checks the settings" begin
        chk = P._checkedKeywords
        # the defaults pass and come back unchanged, in the types of the defaults
        ok = chk(
            :seedModel,
            (; shellSample = 256, sasaNOcc = 104, φ_max = 2,
                bounds_δρ₁₂ = (-10, 2), mode_δρ₁₂ = 1, exclVolCorrBounds = [0.8, 1.3]),
        )
        @test ok.shellSample === 256 && ok.φ_max === 2.0
        @test ok.bounds_δρ₁₂ === (-10.0, 2.0) && ok.exclVolCorrBounds === (0.8, 1.3)
        # one bad value, the line is the one loadSettings gives
        for (entry, kw, setting, words) in (
            (:runModel, (; mapNStarts = 0), "MAP_N_STARTS", "at least 1"),
            (:runModel, (; mapJitterRadii = (3.0, -1.0, 12.0)), "MAP_JITTER_RADII",
                "above 0"),
            (:runModel, (; optimumChainFraction = 1.5), "OPTIMUM_CHAIN_FRACTION",
                "at most 1"),
            (:runModel, (; chainStartRadii = (4.0, 10.0)), "CHAIN_START_RADII",
                "3 parts"),
            (:runModel, (; harvestCover = -1), "HARVEST_COVER", "at least 0"),
            (:runModel, (; basinRestartNats = NaN), "BASIN_RESTART_NATS", "finite"),
            (:runModel, (; retryNDraws = 1.5), "RETRY_N_DRAWS", "whole number"),
            (:seedModel, (; φ_max = 0), "φ_max", "above 0"),
            (:seedModel, (; shellMinPoints = 0), "SHELL_MIN_POINTS", "at least 1"),
            (:seedModel, (; beadRayRange = -2.0), "BEAD_RAY_RANGE", "above 0"),
            (:results, (; tableSigfigs = 0), "TABLE_SIGFIGS", "at least 1"),
            (:results, (; tableSigfigs = 18), "TABLE_SIGFIGS", "at most 17"),
        )
            e = try
                chk(entry, kw)
            catch err
                err
            end
            @test e isa InvalidSettingsError
            @test length(e.problems) == 1 && startswith(e.problems[1], setting * " = ")
            @test occursin(words, e.problems[1])
            # the same text as `loadSettings` for the same value
            name = Symbol(setting)
            msg = try
                _checkedValue(name, P._settingInput(first(values(kw))))
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
            ((; exclVolCorrBounds = (0.8, 0.82), exclVolCorrEps = 0.05),
                "EXCL_VOL_CORR_EPS", "at most the width"),
            ((; shellSample = 64, sasaNOcc = 100), "SASA_N_OCC",
                "at most SHELL_SAMPLE"),
        )
            e = try
                chk(:seedModel, kw)
            catch err
                err
            end
            @test e isa InvalidSettingsError
            @test any(p -> startswith(p, setting * " = ") && occursin(words, p), e.problems)
        end
        # all the problems at once; the error says the values were keywords
        e = try
            chk(:runModel, (; mapNStarts = 0, harvestCover = -1))
        catch err
            err
        end
        @test length(e.problems) == 2
        @test occursin("passed as keywords", sprint(showerror, e))
        # the settings-file error keeps its hint
        @test occursin("terminal interface", sprint(showerror, InvalidSettingsError(["x"])))
        # a valid pair is fine where each alone would not be
        @test chk(:seedModel, (; shellSample = 64, sasaNOcc = 64)).sasaNOcc == 64
        @test chk(:seedModel, (; bounds_δρ₁₂ = (-4, 6), mode_δρ₁₂ = 5)).mode_δρ₁₂ === 5.0
    end

    @testset "the overrides of runProject are checked together with the settings" begin
        s = copy(defaults)
        P._applyKeywords!(
            s,
            (; mapNStarts = 9, tex = nothing, formats = (:pdf, :svg),
                nDraws = 5, mode_δρ₁₂ = nothing),
        )
        @test s[:MAP_N_STARTS] == 9 && s[:N_DRAWS] == 5 && s[:TARGET_ACCEPT] == 95
        @test s[:FIGURES_FORMATS] == (:pdf, :svg)
        # a rule against a value of the file is caught too
        t = copy(defaults)
        t[:SHELL_SAMPLE] = 100
        @test_throws InvalidSettingsError P._applyKeywords!(t, (; sasaNOcc = 104))
        @test t[:SASA_N_OCC] == 104                       # unchanged on failure
        u = copy(defaults)
        @test_throws InvalidSettingsError P._applyKeywords!(u, (; thickness = -1.0))
        @test u[:SHELL_THICKNESS] == 3.0
    end
end
