# SPDX-License-Identifier: LGPL-3.0-or-later

# The command lines of the tools that start Julia processes or LaTeX: a wrong argument
# must stop with a message and the documented exit status BEFORE anything starts, and
# --dry-run must print the commands without running anything.

using Test

# --- Cli

module TCli
using Test
using Dev.Common: ids, specs_of
using .Main.Helpers

@testset "fonts check names against TeX Live" begin
    if Sys.which("luaotfload-tool") !== nothing
        ok = run_tool("plots", "fonts", "Latin Modern Roman")
        no = run_tool("plots", "fonts", "No Such Font Zzz")
        both = run_tool("plots", "fonts", "Latin Modern Roman", "No Such Font Zzz")
        @test ok[1] == 0 && says(ok[2], "Latin Modern Roman: true")
        @test no[1] == 1 && says(no[2], "No Such Font Zzz: false")
        @test both[1] == 1
        @test says(both[2], "Latin Modern Roman: true", "No Such Font Zzz: false")
    end
    @test run_tool("plots", "fonts")[1] == 2
    @test run_tool("plots", "fonts", "--list", "Some Font")[1] == 2
    @test run_tool("plots", "fonts", "--bogus")[1] == 2
end

@testset "vis list and unknown" begin
    listing = run_tool("vis", "--list")
    unknown = run_tool("vis", "nonsense")
    @test listing[1] == 0 && says(listing[2], "sasa_hydro_report")
    @test unknown[1] == 2 && says(unknown[2], "no visual check named: nonsense")
    dry = run_tool("vis", "--dry-run", "plastic_2d")
    @test dry[1] == 0 && says(dry[2], "=== plastic_2d", "vis_plastic_points_2D(2000)")
end

@testset "profile" begin
    @test run_tool("fits", "profile")[1] == 2
    r = run_tool("fits", "profile", "NOPE", "--dry-run")
    @test r[1] == 2 && says(r[2], "no fitting test folder for: NOPE")
    r = run_tool("fits", "profile", "SASDMJ9", "--delay", "0.001", "--nuts", "--dry-run")
    @test r[1] == 0 && says(r[2], "profile_seed.jl --delay 0.001 --nuts SASDMJ9")
end

@testset "render-plots command line" begin
    @test run_tool("plots", "render")[1] == 2
    @test run_tool("plots", "render", "/nonexistent")[1] == 2
    r = run_tool("plots", "render", scratch_dir(), "--type", "bad")
    @test r[1] == 2 && says(r[2], "unknown --type bad")
end

@testset "linelen" begin
    scratch = scratch_dir()
    write_file(joinpath(scratch, "ok.jl"), "x = 1\n")
    write_file(joinpath(scratch, "long.jl"), "# " * "a"^95 * "\n\tx = 1\n")
    r = run_tool("fmt", "--lines", joinpath(scratch, "ok.jl"))
    @test r[1] == 0 && says(r[2], "layout: 1 code files")
    r = run_tool("fmt", "--lines", joinpath(scratch, "long.jl"))
    @test r[1] == 1 && says(r[2], "97 characters", "tab character")
    @test run_tool("fmt", "--lines", "--nope")[1] == 2
end

@testset "diagnose: unknown id, tags and numbers" begin
    r = run_tool("fits", "diagnose", "--report", "NOPE")
    @test r[1] == 2 && says(r[2], "no fitting test 'NOPE'")
    r = run_tool("fits", "diagnose", "--report", "SASDEP6")
    @test r[1] == 2 && says(r[2], "SASDEP6 needs a tag, one of: fit1_model1, fit1_model2")
    r = run_tool("fits", "diagnose", "--report", "SASDMJ9:x")
    @test r[1] == 2 && says(r[2], "SASDMJ9 has a single run and takes no tag")
    @test [run_tool("fits", "diagnose", "--chains", "--retry", "2", "SASDMJ9")[1],
        run_tool("fits", "diagnose", "--chains", "--seeds", "1,x", "SASDMJ9")[1],
        run_tool("fits", "diagnose", "--report", "--samples", "0", "SASDMJ9")[1],
    ] == [2, 2, 2]
end

@testset "fits list" begin
    status, out = run_tool("fits", "list")
    @test status == 0
    # one line per fitting-test folder (derived: the folders are the source)
    @test length(split(strip(out), '\n')) ==
          count(
        n -> startswith(n, "SASD"),
        readdir(joinpath(repo_dir, "test", "fitting_tests")),
    )
    @test says(out, "SASDBS6  fit2_model1 fit2_model2", "SASDMJ9  (single run, no tag)")
end

@testset "diagnose: every part by default, each with only its own options" begin
    status, out =
        run_tool("fits", "diagnose", "--seeds", "1,2", "--samples", "50", "--out",
            "/nowhere", "--dry-run", "SASDMJ9")
    @test status == 0
    @test length(collect(eachmatch(r"=== diagnose: ", out))) == 3
    @test occursin(
        r"(?s)=== diagnose: report.*=== diagnose: residuals.*=== diagnose: chains",
        out)
    @test says(out,
        "diagnose.jl --chains --seeds 1,2 --samples 50 --out /nowhere/chains.txt SASDMJ9",
        "diagnose.jl --report --samples 50 --out /nowhere/report.txt SASDMJ9")
end

@testset "diagnose: every fit by default; parts can be selected" begin
    status, out = run_tool("fits", "diagnose", "--residuals", "--dry-run")
    @test status == 0
    @test length(collect(eachmatch(r"SASD\w+(?::\w+)?", last(split(strip(out), '\n'))))) ==
          length(specs_of(ids()))
    status, out =
        run_tool("fits", "diagnose", "--chains", "--residuals", "--dry-run", "SASDMJ9")
    @test status == 0
    @test length(collect(eachmatch(r"=== diagnose: ", out))) == 2
    @test !occursin("diagnose.jl --report", out)
end

@testset "fitting-tests: unknown id, list, dry runs" begin
    r = run_tool("fits", "run", "NOPE", "SASDMJ9", "--dry-run")
    @test r[1] == 2 && says(r[2], "no fitting test folder for: NOPE") &&
          !occursin("=== fit", r[2])
    status, out = run_tool("fits", "list")
    lines = split(strip(out), '\n')
    @test status == 0 && lines == sort(lines) && all(l -> occursin(r"^SASD\w+ ", l), lines)
    @test any(startswith("SASDMJ9 "), lines) && !occursin("=== fit", out)
    @test run_tool("fits", "run", "SASDMJ9", "--approved", "--dry-run")[1] == 2
    status, out = run_tool("fits", "run", "SASDMJ9", "SASDEP6", "--bench", "--report",
        "--fixme", "--dry-run")
    @test status == 0 && length(collect(eachmatch(r"=== fit:", out))) == 2
    @test says(out, "bysl fits bench SASDMJ9 SASDEP6:fit1_model1 SASDEP6:fit1_model2",
        "bysl results table SASDMJ9 SASDEP6",
        "bysl fits diagnose --report SASDMJ9 SASDEP6:fit1_model1")
    @test !occursin("--approved", out)
    status, out = run_tool("fits", "run", "SASDMJ9", "--bench", "--approved", "--dry-run")
    @test status == 0 && occursin("bysl fits bench --approved SASDMJ9", out)
    status, out =
        run_tool("fits", "run", "SASDMJ9", "--trace-compile", "/tmp/x.jl", "--dry-run")
    @test status == 0 &&
          occursin(r"--trace-compile=/tmp/x.jl.*SASDMJ9.jl", replace(out, "\n" => " "))
    r = run_tool("fits", "run", "SASDMJ9", "--trace-compile")
    @test r[1] == 2 && says(r[2], "needs a value")
    status, out = run_tool("fits", "run", "SASDMJ9", "--no-fit", "--table", "--dry-run")
    @test status == 0 && occursin("bysl results table --update", out)
end

end

# --- Precommit: its whitespace step on a scratch git repository: trailing whitespace on
# changed lines is stripped (and only there), untracked files are stripped whole, a
# conflict marker is a failure.

module TPrecommit

using Test
using Dev
using Dev.Common
using .Main.Helpers

const P = Dev.Checks.Precommit

# A scratch repository with one committed file (a.jl: three lines, the second already ends
# in blanks); its path.
function scratch_repo()
    dir = scratch_dir()
    git(args...) = run(
        pipeline(Cmd(`git -C $dir -c user.name=t -c user.email=t@t $(collect(args))`);
            stdout = devnull, stderr = devnull),
    )
    git("init", "-q")
    write_file(joinpath(dir, "a.jl"), "one\ntwo  \nthree\n")
    git("add", "a.jl")
    git("commit", "-q", "-m", "init")
    return dir
end

visible(s) = replace(s, "\n" => "|")

function in_repo(f, dir)
    Common.ROOT_OVERRIDE[] = dir
    try
        return f()
    finally
        Common.ROOT_OVERRIDE[] = nothing
    end
end

@testset "changed and untracked lines are stripped, an unchanged line is not" begin
    dir = scratch_repo()
    # lines 1 and 3 changed with blanks, line 2 untouched
    write_file(joinpath(dir, "a.jl"), "one \ntwo  \nthree\t\nfour\n")
    write_file(joinpath(dir, "new.md"), "x  \ny\n")
    ok = in_repo(dir) do
        capture_stdout(P.whitespace)
    end
    @test visible(read(joinpath(dir, "a.jl"), String)) == "one|two  |three|four|"
    @test visible(read(joinpath(dir, "new.md"), String)) == "x|y|"
end

@testset "a conflict marker in an untracked file is reported and fails" begin
    dir = scratch_repo()
    write_file(joinpath(dir, "b.jl"), "ok\n<<<<<<< HEAD\nx\n")
    result = Ref(true)
    out = in_repo(dir) do
        capture_stdout(() -> result[] = P.whitespace())
    end
    @test !result[] && occursin("b.jl:2: conflict marker", out)
end

@testset "nothing to strip: true and the files are byte for byte the same" begin
    dir = scratch_repo()
    before = read(joinpath(dir, "a.jl"), String)
    result = Ref(false)
    in_repo(dir) do
        capture_stdout(() -> result[] = P.whitespace())
    end
    @test result[] && read(joinpath(dir, "a.jl"), String) == before
end

@testset "a trailing tab in a .tsv is an empty last field, not whitespace" begin
    dir = scratch_repo()
    tsv = "a\tb\tc\nx\ty\t\n"
    write_file(joinpath(dir, "t.tsv"), tsv)
    @test P.strip_lines(joinpath(dir, "t.tsv"), :all) == 0
    @test read(joinpath(dir, "t.tsv"), String) == tsv
end

end

# --- Bench: no benchmark is run. The approval guard is tested by running the tool WITHOUT
# --approved (it must print its plan and do nothing), the rest are the pure functions.

module TBench

using Test
using Dev
using .Main.Helpers

const B = Dev.Fits.Bench

@testset "without --approved the tool refuses and says what it would run" begin
    status, out = run_tool("fits", "bench", "--state", "cold", "SASDMJ9")
    @test status == 0 && says(out, "not running", "Planned: --state cold SASDMJ9")
    @test !occursin("cold state in", out)
    # the warm state needs approval too
    status, out =
        run_tool("fits", "bench", "--state", "warm", "SASDMJ9", "SASDBS6:fit2_model3")
    @test status == 0 && occursin("not running", out)
end

@testset "options with a value, the --keep flag, and positional specs" begin
    r = B.parse_args(["--state", "cold", "--keep", "--samples", "5", "SASDMJ9",
        "SASDBS6:fit2_model3"])
    @test r.opts == Dict("state" => "cold", "keep" => 1, "samples" => "5")
    @test r.specs == ["SASDMJ9", "SASDBS6:fit2_model3"]
    status, out = run_tool("fits", "bench", "--approved", "SASDMJ9", "--out")
    @test status == 2 && occursin("option --out needs a value", out)
end

@testset "what the cold state's repository copy leaves out" begin
    @test B.excluded.(["docs/x.md", "test/visualize/xyz/a.xyz",
        "test/baselines/results/r.json",
        "test/fitting_tests/SASDMJ9/res.txt", "test/fitting_tests/SASDMJ9/res_hist.png",
        "test/fitting_tests/SASDMJ9/SASDMJ9.jl", "src/Inference/Inference.jl",
        "test/baselines/README.md", "dev/src/Fits.jl"]) ==
          [true, true, true, true, true, false, false, false, false]
end

@testset "the cold depot links source dirs and has no compiled/ cache" begin
    scratch = scratch_dir()
    mkpath(joinpath(scratch, "real", "packages"))
    mkpath(joinpath(scratch, "real", "compiled"))
    mkpath(joinpath(scratch, "real", "artifacts"))
    B.make_depot(joinpath(scratch, "depot"), joinpath(scratch, "real"))
    @test sort(readdir(joinpath(scratch, "depot"))) == ["artifacts", "packages"]
    @test islink(joinpath(scratch, "depot", "packages"))
end

@testset "the child's JSON is its last {...} line, whatever came before it" begin
    @test B.json_line(
        "Transaction\n\n  Prefix: /x\n\nTransaction finished\n\n" *
        "{\"a\":1,\"b\":{\"c\":2}}\n",
    ) == "{\"a\":1,\"b\":{\"c\":2}}"
    @test B.json_line("Transaction finished\nsomething else\n") === nothing
end

end
