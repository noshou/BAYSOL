# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl fits export`: the parts that read what a fitting test left (the folder
# LOG, the script's solutes, the datetime) and one real export into a scratch folder.

using Test
using Dev

const X = Dev.Fits.Export

@testset "LOG datetime to run name and instant" begin
    @test X.run_name("16-11-2026 18:19:34 -0500") == "18-19-34-000_LOC_-0500_2026-11-16"
    @test X.run_name("16-11-2026 18:19:34 +0000") == "18-19-34-000_UTC_+0000_2026-11-16"
    @test X.utc_of("16-11-2026 18:19:34 -0500") == "2026-11-16T23:19:34Z"
    @test_throws ErrorException X.run_name("yesterday")
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
end

@testset "export of SASDMJ9 into a scratch folder" begin
    mktempdir() do dir
        @test X.run(["SASDMJ9", "--out", dir, "--dry-run"]) == 0
        @test !ispath(joinpath(dir, "SASDMJ9"))
        @test X.run(["SASDMJ9", "--out", dir]) == 0
        project = joinpath(dir, "SASDMJ9")
        for f in ("data.tsv", "data.json", "buffer.json", "settings.json", "project.json")
            @test isfile(joinpath(project, f))
        end
        @test length(readdir(joinpath(project, "runs"))) == 1
        # a second export leaves the project alone
        before = readdir(joinpath(project, "runs"))
        @test X.run(["SASDMJ9", "--out", dir]) == 0
        @test readdir(joinpath(project, "runs")) == before
        # an unknown test is skipped and reported through the exit status
        @test X.run(["SASDNOPE", "--out", dir]) == 1
    end
end
