# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of Pmv (`bysl extract pmv`, the port of the former Python tools): the number
# layout and the JSON writer and reader, the regression checks of the self-test, the
# ACCEPTANCE fit on the
# 88 calibration solutes against the numbers the Python tool printed (n 88, in-sample RMS
# 2.96 / 2.96, LOO RMS 3.52 / 3.53, compared to 1e-6 relative), the estimates, the note
# format the table checks parse, the row wiring on a scratch copy of the tables, and the
# parts of the 3D-RISM driver that need no AmberTools (commands, embedding, finished jobs).
# No 3D-RISM job is started.
using Test

module TPmv

using Test
using Dev: Platform
using Dev
using Dev.Common
using Base.ScopedValues: with
using .Main.Helpers

const P = Dev.Pmv
const L = Dev.Pmv.Layout

# RDKit_jll's Windows build of librdkitcffi.dll exports none of the functions that
# RDKitMinimalLib.jl calls (`get_mol`, ...; no newer JLL fixes it), so on Windows the tests
# that parse a SMILES are skipped with a message.
const RDKIT = try
    Dev.Pmv.Model.features("C")
    true
catch
    false
end

macro needs_rdkit(ex)
    name = ex.args[3]
    return esc(
        quote
            if RDKIT
                $ex
            else
                @info "skipped, RDKit cannot load on this platform: $($name)"
            end
        end,
    )
end

# The numbers the Python `fit` of the former tool printed on the calibration set + the
# results file (n = 88).
const PY_FIT = (in_rms_bayes = 2.9590903293066053, in_rms_ridge = 2.957966707197874,
    loo_rms_bayes = 3.518663804223542, loo_rms_ridge = 3.5263538018077885,
    loo_z_sd_bayes = 1.1730667475713974)

rel(a, b) = abs(a - b) / max(abs(a), abs(b), 1e-300)

@testset "number layout as Python prints it" begin
    @test L.pyfloat(2.0) == "2.0"
    @test L.pyfloat(0.001) == "0.001"
    @test L.pyfloat(1e-6) == "1e-06"
    @test L.pyfloat(1.5e-5) == "1.5e-05"
    @test L.pyfloat(1e16) == "1e+16"
    @test L.pyfloat(123456789.25) == "123456789.25"
    @test L.pyfloat(-0.5) == "-0.5"
    @test L.pyfloat(0.0) == "0.0"
    @test L.ff(2, NaN) == "nan" && L.ff(2, 3.14159) == "3.14"
    @test L.ffs(2, 1.0) == "+1.00" && L.ffs(1, -0.04) == "-0.0"
end

@testset "JSON writer and reader round-trip a Python-laid-out file" begin
    text = """{
 "a": [
  1,
  2.0,
  null
 ],
 "b": {
  "x": "q\\"uote",
  "y": true,
  "z": 1e-06
 },
 "empty": [],
 "none": {}
}"""
    v = L.loads(text)
    @test collect(keys(v)) == ["a", "b", "empty", "none"]
    @test v["a"] == Any[1, 2.0, nothing] && v["a"][2] isa Float64 && v["a"][1] isa Int
    @test L.dumps(v; indent = 1) == text
    @test L.loads("\"\\u00e9\\ud83d\\ude00\"") == "é😀"
end

@testset "tables: TSV rows, results.tsv, electrons" begin
    dir = scratch_dir()
    p = write_file(joinpath(dir, "t.tsv"), "a\tb\n1\t2\n\nshort\n")
    rows = P.read_tsv(p)
    @test length(rows) == 2 && rows[1] == Dict("a" => "1", "b" => "2")
    @test rows[2] == Dict("a" => "short")
    @test P.electrons("C22H42O11") == 262 && P.electrons("Na", 1) == 10
    @test isequal(P.read_results(joinpath(dir, "missing.tsv")), P.RESULTS)   # bundled base
end

@needs_rdkit @testset "the self-test passes" begin
    status, out = run_tool("extract", "pmv", "selftest")
    @test status == 0 && occursin("all checks passed", out)
    @test !occursin("FAIL", out)
end

# --- the acceptance fit and what is built on it, in one scratch output folder

const OUT = scratch_dir()

@needs_rdkit @testset "ACCEPTANCE: the 88-solute fit reproduces the Python numbers" begin
    status, out = run_tool("extract", "pmv", "--out", OUT, "fit")
    @test status == 0
    out_model = with(P.Config.OUT => OUT) do
        P.load_model()
    end
    @test out_model["n"] == 88
    for k in keys(PY_FIT)
        @test rel(out_model[string(k)], getfield(PY_FIT, k)) < 1e-6
    end
    # the numbers of the printed table: 2.96 / 2.96 in sample, 3.52 / 3.53 LOO
    @test round(out_model["in_rms_bayes"]; digits = 2) == 2.96
    @test round(out_model["in_rms_ridge"]; digits = 2) == 2.96
    @test round(out_model["loo_rms_bayes"]; digits = 2) == 3.52
    @test round(out_model["loo_rms_ridge"]; digits = 2) == 3.53
    @test occursin("'n': 88", out) && occursin("'loo_rms_bayes': 3.5186638", out)
    # every group feature of the Python run, in order
    @test collect(keys(out_model["bayes_mean"])) == P.Model.NAMES
    @test length(out_model["bayes_Vn"]) == 11
end

@needs_rdkit @testset "estimate and the held-out table" begin
    with(P.Config.OUT => OUT) do
        status, out = run_tool("extract", "pmv", "estimate", "K002", "CCCO")
        @test status == 0
        @test strip(out) == "K002: R 65.44 correction +3.81 (sd 3.01) -> V 69.25 +- 4.00"
        dm = P.Model.ANCHOR_SMILES
        status, out = run_tool("extract", "pmv", "estimate", "DM", dm)
        @test strip(out) == "DM: R 368.91 correction +11.56 (sd 3.69) -> V 380.47 +- 4.34"
        status, out = run_tool("extract", "pmv", "estimate", "NOPE", "CCO")
        @test status == 1 && occursin("no finished run named NOPE", out)
        h = P.Model.holdout(P.load_model(), P.read_results())
        @test rel(h["sucrose"]["direct"], 212.4815588623991) < 1e-6
        @test rel(h["decyl maltoside (anchor, direct model)"]["direct"],
            380.4749867823702) < 1e-6
        @test h["sucrose"]["anchored_err"] ≈ 13.25 atol = 1e-6
    end
end

@needs_rdkit @testset "diagnostics: reports and the files they write" begin
    with(P.Config.OUT => OUT) do
        status, out = run_tool("extract", "pmv", "diagnostics", "coefficients")
        @test status == 0 && occursin("CH3_CH2", out) && occursin("1.94", out)
        status, out = run_tool("extract", "pmv", "diagnostics", "cv", "--repeats", "2")
        @test status == 0 && occursin("LOO", out) && occursin("3.52", out)
        status, out = run_tool("extract", "pmv", "diagnostics", "residuals")
        @test status == 0 && occursin("betaine", out)
        status, out = run_tool("extract", "pmv", "diagnostics", "conformers")
        @test status == 0 && occursin("single-conformer runs", out)
        status, out = run_tool("extract", "pmv", "diagnostics", "holdout")
        @test status == 0 && occursin("sucrose", out)
        status, out = run_tool("extract", "pmv", "diagnostics", "nosuch")
        @test status == 2
        for r in ("residuals_solutes", "residuals_groups", "cv", "coefficients",
            "conformers", "holdout")
            @test isfile(joinpath(OUT, "diagnostics", "$r.tsv"))
        end
        lines = readlines(joinpath(OUT, "diagnostics", "coefficients.tsv"))
        @test length(lines) == 12 && startswith(lines[1], "group\tprior_mean")
    end
end

@needs_rdkit @testset "the note of a row is what the table check parses" begin
    with(P.Config.OUT => OUT) do
        mdl = P.load_model()
        res = P.read_results()
        row = P.Rows.make_row("K002", "CCCO", ("n-Propanol", "propan-1-ol", "C3H8O", 0),
            ["propanol"], mdl, res)
        @test startswith(row["note"], "3D-RISM raw value 65.4 (SD 0.1 over 3 conformers)")
        @test occursin("bysl extract pmv", row["note"])
        m = match(P.Diagnostics.NOTE_RE, row["note"])
        @test m !== nothing && m[:n] == "3" && m[:corr] == "+3.8" && m[:psd] == "3.0"
        tab(; v = "69.25", sd = "4.0", note = row["note"]) = Dict("doi" => note,
            "v0_cm3_per_mol" => v, "uncertainty_cm3_per_mol" => sd)
        check(r; res = res, smiles = Dict("K002" => "CCCO")) =
            P.Diagnostics.check_row("polymers", r, res, smiles)
        s, run, _ = check(tab(; v = string(row["v"]), sd = string(row["sd"])))
        @test s == "OK" && run == "K002"
        s, _, detail = check(tab(; v = "80.0"))
        @test s == "MISMATCH" && occursin("raw+corr", detail)
        @test check(tab(; note = "hand-derived"))[1] == "FREE_TEXT"
        @test check(tab(); res = Dict("X" => (1, 1.0, 0.0)))[1] == "NO_RUN"
        # a single conformer writes `SD nan`, which the format and the reader accept
        one = P.Rows.make_row("K001", "CCO", ("e", "ethanol", "C2H6O", 0), String[], mdl,
            res)
        @test occursin("SD nan over 1 conformers", one["note"])
        @test match(P.Diagnostics.NOTE_RE, one["note"]) !== nothing
    end
end

@testset "row wiring on a scratch copy of the tables is idempotent" begin
    dir = scratch_dir()
    mkpath(joinpath(dir, "src", "bulk-electron-density"))
    for sub in ("polymers", "non-biological")
        cp(joinpath(repo_dir, "src", "bulk-electron-density", sub),
            joinpath(dir, "src", "bulk-electron-density", sub))
    end
    Common.ROOT_OVERRIDE[] = dir
    try
        js = joinpath(P.Config.POLYMERS(), "polymers.json")
        before = read(js, String)
        # the file may hold 4.30, dumps writes 4.3
        norm = L.dumps(L.loads(before); indent = 2)
        @test L.dumps(L.loads(norm); indent = 2) == norm
        row = Dict{String,Any}("common" => "Test X", "iupac" => "test x iupac",
            "formula" => "C3H8O", "charge" => 0, "v" => 70.12, "sd" => 4.0,
            "basis" => "estimated", "note" => "a note", "aliases" => ["tx-alias"])
        out = capture_stdout(() -> P.Rows.wire([row], false))
        @test occursin("row Test X: Z 34, V 70.12 +- 4.0", out)
        @test read(js, String) == before   # no --apply: nothing is written
        capture_stdout(() -> P.Rows.wire([row], true))
        sel = L.loads(read(js, String))
        @test sel["test x iupac"] == Any[34, 70.12, 4.0]
        tsv = read(joinpath(P.Config.POLYMERS(), "polymers.tsv"), String)
        @test endswith(
            tsv,
            "Test X\ttest x iupac\tC3H8O\t0\t70.12\t4.0\testimated\ta note\n",
        )
        look = read(joinpath(P.Config.POLYMERS(), "polymers_lookup.json"), String)
        @test occursin("\"tx-alias\": \"test x iupac\"", look) && endswith(look, "\n}")
        again = capture_stdout(() -> P.Rows.wire([row], true))
        @test occursin("skip existing test x iupac", again)
        @test read(joinpath(P.Config.POLYMERS(), "polymers.tsv"), String) == tsv
        @test read(joinpath(P.Config.POLYMERS(), "polymers_lookup.json"), String) == look
    finally
        Common.ROOT_OVERRIDE[] = nothing
    end
end

@testset "the 3D-RISM driver: commands, embedding and finished jobs (no AmberTools)" begin
    @test P.Rism.antechamber_command(-1) ==
          "antechamber -i x.mol -fi mdl -o x.mol2 -fo mol2 -c bcc -nc -1 " *
          "-at gaff2 -rn MOL -s 0 -pf y"
    cmd = P.Rism.rism_command("/amber/x.xvv")
    @test occursin("--xvv /amber/x.xvv --closure kh --buffer 25 --grdspc 0.5,0.5,0.5", cmd)
    @test occursin("--tolerance 1e-6 --maxstep 5000 --centering 2 --verbose 1", cmd)
    @test occursin("source leaprc.gaff2", P.Rism.LEAP_INPUT)
    with(P.Config.AMBER => "/opt/amber") do
        @test P.Config.amber_home() == "/opt/amber"
        @test P.Rism.xvv() ==
              joinpath("/opt/amber", "dat", "rism1d", "cSPCE", "cSPCE_kh.xvv")
        @test first(P.Config.amber_env()) == ("PATH" => "/opt/amber/bin:" * ENV["PATH"])
    end
    if RDKIT
        block = P.Rism.embed("CCO", 7)
        @test block isa String && occursin("V2000", block)
        @test count(l -> occursin(r"^\s+-?\d+\.\d+\s+-?\d+\.\d+\s+-?\d+\.\d+ [A-Z]", l),
            split(block, "\n")) == 9   # 3 heavy atoms + 6 hydrogens
        @test P.Rism.embed("CCO", 7) == block   # a seed is reproducible
        @test P.Rism.embed("not a smiles", 1) === nothing
    end
    dir = scratch_dir()
    # a finished job is read back without any molecule or program
    write(joinpath(dir, "result.txt"), "123.5")
    @test P.Rism.conformer_volume(dir, () -> error("not called"), 0) == 123.5
    # the shell wrapper runs in its folder with the environment and logs the output
    @test P.Rism.sh_log("echo \$AMBERHOME; pwd; echo err 1>&2", dir, "x.log") == 0
    log = read(joinpath(dir, "x.log"), String)
    @test occursin(string(P.Config.amber_home()), log) && occursin("err", log)
    @test P.Rism.sh_log("exit 3", dir, "y.log") == 3
    # a failed embedding is a failed conformer, not an error
    @test P.Rism.conformer_volume(scratch_dir(), () -> nothing, 0) === nothing
end

@testset "batch: resume, tiers, failures and niceness (no AmberTools)" begin
    dir = scratch_dir()
    out = joinpath(dir, "out")
    mkpath(out)
    res = joinpath(out, "results.tsv")
    write(res, "DONE1\t1\t10.0\tnan\t25\t0.5\t1e-6\n")
    spec = joinpath(dir, "queue.tsv")
    write(
        spec,
        join(
            ["id\tsmiles\tcharge\tnconf\ttier",
                "DONE1\tCCO\t0\t1\t1", "BAD2\t((not a smiles\t0\t1\t2",
                "BAD3\t((not a smiles\t0\t1\t3"], "\n") * "\n",
    )
    with(P.Config.OUT => out) do
        # the finished id is skipped; tiers keep only the named ones, in file order
        @test redirect_stdio(; stdout = devnull, stderr = devnull) do
            P.Rism.batch(spec, ["1"])
        end == String[]
        @test redirect_stdio(; stdout = devnull, stderr = devnull) do
            P.Rism.batch(spec, ["2", "3"])
        end == ["BAD2", "BAD3"]
        status = redirect_stdio(; stdout = devnull, stderr = devnull) do
            run_tool("extract", "pmv", "--out", out,
                "batch", spec, "--tier", "3", "--nice", "19")[1]
        end
        @test status == 1                      # a failed job is a non-zero status
    end
    if !Platform.iswindows()
        # the level reaches the programs of a command
        with(P.Config.NICE => 7) do
            @test P.Rism.sh_log("nice", dir, "n.log") == 0
        end
        base = parse(Int, readchomp(`nice`))   # nice adds to the level this process has
        @test parse(Int, strip(read(joinpath(dir, "n.log"), String))) == min(19, base + 7)
    end
    status, out = run_tool("extract", "pmv", "batch", spec, "--nice", "40")
    @test status == 2 && occursin("--nice must be 0 to 19", out)
end

@testset "embedded tables equal the old data files" begin
    # Snapshots of the files the tables replaced: calibration.tsv as it was in HEAD (before
    # the aligned layout), and the kept runs of results.tsv (floats written with repr).
    data = joinpath(@__DIR__, "data")
    old = [split(l, '\t') for l in eachline(joinpath(data, "pmv-calibration-old.tsv"))]
    head, rows = old[1], old[2:end]
    cal = P.calibration_table()
    @test length(cal) == length(rows) == 90
    for (r, c) in zip(rows, cal), (k, v) in zip(head, r)
        @test c[k] == v
    end
    @test [c["id"] for c in cal] == [r[1] for r in rows]
    res = [split(l, '\t') for l in eachline(joinpath(data, "pmv-results-old.tsv"))][2:end]
    @test length(P.RESULTS) == length(res) == 196
    @test collect(keys(P.RESULTS)) == [r[1] for r in res]
    for r in res
        @test P.RESULTS[r[1]][1] == parse(Int, r[2])
        @test isequal(P.RESULTS[r[1]][2], parse(Float64, r[3]))
        @test isequal(P.RESULTS[r[1]][3], parse(Float64, r[4]))
    end
end

@needs_rdkit @testset "calibration set, results and required --out" begin
    cal = P.calibration_table()
    @test length(cal) == 90 && count(r -> r["fit"] == "1", cal) == 88
    @test cal[1]["id"] == "K001" && cal[1]["smiles"] == "CCO" && cal[1]["v_meas"] == "55.10"
    @test all(r -> length(r) == 8 && !isempty(r["provenance"]), cal)
    # long SMILES survive the line joins of the source text
    @test any(r -> length(r["smiles"]) > 80, cal)
    # the bundled results have a finished run for every calibration solute and the anchor
    res = P.read_results()
    @test length(res) == 196 && haskey(res, "TRIS0") && isnan(res["K001"][3])
    @test all(r -> haskey(res, r["id"]), cal)
    # no folder inside the repository by default: --out is required
    @test_throws ToolError P.Config.out_dir()
    @test_throws ToolError P.Config.work_dir()
    @test_throws ToolError P.Config.results_path()
    status, out = run_tool("extract", "pmv", "fit")
    @test status == 2 && occursin("--out DIR is required", out)
    with(P.Config.OUT => "/x/o") do
        @test P.Config.work_dir() == "/x/o/work"
        @test P.Config.results_path() == "/x/o/results.tsv"
    end
end

@testset "the command line" begin
    status, out = run_tool("extract", "pmv", "--help")
    @test status == 0 && occursin("run NAME SMILES NCONF CHARGE", out)
    status, out = run_tool("extract", "pmv", "nosuch")
    @test status == 2 && occursin("unknown subcommand nosuch", out)
    status, out = run_tool("extract", "pmv", "run", "X")
    @test status == 2 && occursin("usage: run NAME", out)
    status, out = run_tool("extract", "pmv", "diagnostics")
    @test status == 0 && occursin("residuals", out)
end

end
