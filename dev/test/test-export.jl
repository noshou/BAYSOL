# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl fits export`: the parts that read what a fitting test left (the folder
# LOG, the script's solutes, the datetime) and one real export into a scratch folder.

using Test
using Dev
using JSON3

const X = Dev.Fits.Export

@testset "LOG datetime to run name and instant" begin
    @test X.run_name("16-11-2026 18:19:34 -0500") == "18-19-34-000_LOC_-0500_2026-11-16"
    @test X.run_name("16-11-2026 18:19:34 +0000") == "18-19-34-000_UTC_+0000_2026-11-16"
    @test X.utc_of("16-11-2026 18:19:34 -0500") == "2026-11-16T23:19:34Z"
    @test_throws ErrorException X.run_name("yesterday")
end

@testset "the statistics log: a run's section is pulled in beside its LOG" begin
    mktempdir() do dir
        @test X.statistics_section(dir, "SASDXXX", "fit1") === nothing      # no file
        write(
            joinpath(dir, "statistics-SASDXXX.LOG"),
            "datetime\t16-11-2026 18:19:34 -0500\n\n=== fit1 ===\nattempts\t1\n\n" *
            "=== fit2 ===\nattempts\t2\n",
        )
        @test X.statistics_section(dir, "SASDXXX", "fit3") === nothing      # no section
        text = X.statistics_section(dir, "SASDXXX", "fit2")
        @test text == "datetime\t16-11-2026 18:19:34 -0500\n\n=== fit2 ===\nattempts\t2\n"
        # the run log's reader sees only that one section, as for the LOG
        write(joinpath(dir, "s.LOG"), text)
        log = X.read_log(joinpath(dir, "s.LOG"))
        @test first.(log.sections) == ["fit2"] &&
              X.row_of(log.sections[1][2], "attempts") == "2"
    end
end

@testset "solutes of a script" begin
    text = """
    const SOLUTES = Solute[
        NonBiological(0.2, 0.002, "sodium chloride"),  # a comment with ] and "
        Polymer(0.001 * 5, 1e-4, "digitonin"),
    ]
    """
    rows = X.script_solutes(text)
    @test [r["name"] for r in rows] == ["sodium chloride", "digitonin"]
    @test rows[1]["mM"] == 200 && rows[1]["sigmaMm"] == 2
    @test rows[2]["kind"] == "polymer" && rows[2]["mM"] == 5
    @test_throws ErrorException X.script_solutes("nothing here")
    @test_throws ErrorException X.arith("run(`rm`)")
    # a script with one block per fit names it SOLUTES_FIT1, SOLUTES_FIT2, ...
    fit1 = "const SOLUTES_FIT1 = Solute[\n    NonBiological(0.1, 0.001, \"urea\"),\n]"
    @test [r["name"] for r in X.script_solutes(fit1)] == ["urea"]
end

@testset "the sampler overrides of a script reach settings.json" begin
    @test X.script_overrides("res = BAYSOL.runModel(s, n, m)") == Dict()
    o = X.script_overrides(
        "res = BAYSOL.runModel(s, nSamples, nAdapt; δ = 70, retryNAdapt = 6000,\n" *
        "    retryNDraws = 8000, chainStartRadii = (1.0, 2.0, 3.0)) # a comment, δ = 1\n",
    )
    @test o == Dict(
        "TARGET_ACCEPT" => 70, "RETRY_N_ADAPT" => 6000, "RETRY_N_DRAWS" => 8000,
        "CHAIN_START_RADII" => [1.0, 2.0, 3.0],
    )
    text =
        "runModel(\n s, n, m;\n δ = 99,\n ladder = (\n divergent = ((name = " *
        "\"sample c1\", overrides = (SAMPLE_C1 = true,)),),\n ),\n)"
    o = X.script_overrides(text, Dict{String,Any}("stepCollapse" => Any[]))
    @test o["TARGET_ACCEPT"] == 99
    @test o["LADDER"]["divergent"][1]["overrides"]["SAMPLE_C1"] === true
    @test haskey(o["LADDER"], "stepCollapse")
    @test_throws ErrorException X.script_overrides("runModel(s, n, m; bogus = 3)")
    # settings.json holds them per sheet, each as {"value": ...}, never flat
    @test X.settings_table(Dict{String,Any}()) == Dict()
    t = X.settings_table(Dict("TARGET_ACCEPT" => 70, "LADDER" => Dict("generic" => Any[])))
    @test t == Dict(
        "sampler" => Dict(
            "TARGET_ACCEPT" => Dict("value" => 70),
            "LADDER" => Dict("value" => Dict("generic" => Any[])),
        ),
    )
end

@testset "the depositor's reference label" begin
    @test X.reference_label("CRYSOL 1.523") == ("CRYSOL", "1.523")
    @test X.reference_label("FoXS 2") == ("FoXS", "2")
    @test X.reference_label("CRYSOL") == ("CRYSOL", "")        # no trailing number
    @test X.reference_label(nothing) == ("", "")
end

@testset "the script of a fitting test" begin
    mktempdir() do root
        @test X.fit_script(joinpath(root, "Manifest.toml"), "Manifest.toml") === nothing
        dir = mkpath(joinpath(root, "SASDXXX"))
        @test X.fit_script(dir, "SASDXXX") === nothing                      # no script
        write(joinpath(dir, "SASDXXX_fit2.jl"), "")
        @test basename(X.fit_script(dir, "SASDXXX")) == "SASDXXX_fit2.jl"   # the only one
        write(joinpath(dir, "other.jl"), "")
        @test X.fit_script(dir, "SASDXXX") === nothing                      # ambiguous
        write(joinpath(dir, "SASDXXX.jl"), "")
        # named for the ID
        @test basename(X.fit_script(dir, "SASDXXX")) == "SASDXXX.jl"
    end
end

# The workbook (`res*.xlsx`, git-ignored) is what a fit leaves; without a run there is
# nothing to export, on any platform.
@testset "export of SASDMJ9 into a scratch folder" begin
    if isempty(X.workbooks(joinpath(Dev.Common.root(), X.FIT_DIR, "SASDMJ9")))
        @info "no workbook of SASDMJ9 (the fit has not been run): export test skipped"
    else
        mktempdir() do dir
            @test X.run(["SASDMJ9", "--out", dir, "--dry-run"]) == 0
            @test !ispath(joinpath(dir, "SASDMJ9"))
            @test X.run(["SASDMJ9", "--out", dir]) == 0
            project = joinpath(dir, "SASDMJ9")
            for f in ("data.tsv", "data.json", "buffer.json", "settings.json", "project.json")
                @test isfile(joinpath(project, f))
            end
            @test length(readdir(joinpath(project, "runs"))) == 1
            # the reference fit of the workbook: packed curves and the label of the model
            if isfile(joinpath(project, "reference-fit.7z"))
                refs = JSON3.read(
                    read(joinpath(project, "model-references.json"), String),
                    Dict{String,Any},
                )
                @test haskey(refs, "*") && haskey(refs["*"], "fit")
                members = read(`7z l -slt $(joinpath(project, "reference-fit.7z"))`, String)
                @test occursin("Path = $(refs["*"]["fit"])\n", members)
            end
            # the run keeps its own copy of the inputs, for the logs menu's restore options
            runArchive = joinpath(project, "runs", only(readdir(joinpath(project, "runs"))))
            listing = read(`7z l -slt $runArchive`, String)
            for f in ("settings.json", "buffer.json", "data.tsv", "data.json")
                @test occursin("Path = $f\n", listing)
            end
            # a second export leaves the project alone
            before = readdir(joinpath(project, "runs"))
            @test X.run(["SASDMJ9", "--out", dir]) == 0
            @test readdir(joinpath(project, "runs")) == before
            # an unknown test is skipped and reported through the exit status
            @test X.run(["SASDNOPE", "--out", dir]) == 1
        end
    end
end
