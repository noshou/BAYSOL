# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of what is read from the runs: Report (the log and text-report parsers) and the
# two tools of Results (the table and the comparison).

using Test

# --- Report

module TReport
using Test
using Dev
using Dev.Common
using Dev.Report
using .Main.Helpers

const R = Dev.Report

# The values of `ks` in the report `file` of the test data, as printed.
function fields(file, ks)
    r = parse_report(slurp8(joinpath(data_dir, file)))
    return [num_str(r[k]) for k in ks]
end

near(a, b) = abs(Float64(a) - Float64(b)) < 1e-9

@testset "the current report format" begin
    @test fields(
        "res_current.txt",
        [:chi2, :c1, :sat, :rhoE, :d1, :d2, :d3, :div, :steps,
            :depth, :accept, :ebfmi, :wall, :fwd, :map_s, :reprofile, :gc, :leapfrog,
            :msStep,
            :nuts, :z3, :nModes, :wall_ex],
    ) ==
          ["+0.868097", "+1.2486", "false", "+0.336156", "-1.09317", "+1.95561", "-5.67044",
        "0.0000", "5.70", "2.52", "0.9019", "0.9579", "15.37", "2.67", "3.05", "0.68",
        "4.2",
        "12170.0", "0.5", "6.11", "-0.792701", "2", "15.37"]
end

@testset "the v0.2.0 format: fields it lacks are empty, the others parse" begin
    @test fields(
        "res_v020.txt",
        [:chi2, :c1, :d1, :d2, :d3, :steps, :wall, :fwd, :map_s,
            :nModes, :leapfrog, :nuts, :z3, :wall_ex],
    ) ==
          ["+1.13124", "+1.12324", "+1.97557", "-2.15674", "-9.83588", "6.18", "56.43",
        "24.17", "", "", "15200.0", "27.27", "-2.11641", "56.43"]
end

@testset "a Shannon-binned report" begin
    @test fields("res_shannon.txt", [:chi2, :chi2_raw, :chi2_cmp, :c1, :d3]) ==
          ["+0.912345", "0.951234", "0.951234", "+1.2486", "-5.67044"]
end

@testset "chi2_cmp without raw" begin
    @test fields("res_current.txt", [:chi2_raw, :chi2_cmp]) == ["", "+0.868097"]
end

@testset "count suffixes" begin
    @test R.qty.(["496.68k", "12.4k", "1.2M", "750"]) ==
          [496680.0, 12400.0, 1200000.0, 750.0]
end

@testset "a number capture keeps all its digits" begin
    @test R.grab("meanNSteps   = 215.45", raw"^meanNSteps\s+= @N@") == "215.45"
end

@testset "every line of the report parses" begin
    @test fields(
        "res_chains.txt",
        [:nAtoms, :lMax, :nQRaw, :nQ, :nSamples, :nAdapt,
            :dmax, :channels, :rebin_per_chn, :rebinMeasured, :rebinFitted,
            :rebin_dropped,
            :iterations, :accept, :depth, :depth_max, :steps, :ebfmi, :cavityFrac, :sat,
            :div,
            :lgdn_MAP, :rho_e_MAP, :dro3_MAP, :chi2_MAP, :quantileLo, :quantileHi],
    ) ==
          ["2592", "32", "1803", "121", "1000", "300", "63.9", "10.0", "12", "1803", "121",
        "0", "700", "0.9094", "2.51", "3", "5.72", "1.1027", "0.0029", "false", "0.0000",
        "+152.294", "+0.336164", "-5.99051", "+0.873836", "16", "84"]
end

@testset "the quantile, bound and z-score columns of every parameter" begin
    @test fields(
        "res_chains.txt",
        [:lgdn_QUANT_LO, :lgdn_QUANT_HI, :lgdn_BOUND_LO,
            :lgdn_BOUND_HI, :dro3_QUANT_LO, :dro3_BOUND_HI, :scale_QUANT_HI, :excl_BOUND_LO,
            :chi2_BOUND_HI, :rho_e_Z_MAP, :dro2_Z_QUANT_LO, :dro3_Z_QUANT_HI],
    ) ==
          ["+148.612", "+151.649", "+148.614", "+151.648", "-8.49667", "-2.09783",
        "+9.2958e-06", "+1.24652", "+0.876655", "+0.287019", "+3.90118", "-0.0218302"]
end

@testset "every stage of the timing table, the MAP search and NUTS metadata" begin
    @test fields(
        "res_chains.txt",
        [:static_build, :resloveStruct, :propka, :pdb2pqr,
            :loadMolecule, :sasa, :shannon, :fwd, :vac_excl, :hydration, :gram_rm,
            :seed_fitting, :sampling, :map_s, :nuts_setup, :nuts, :reprofile,
            :map_quantiles,
            :report_write, :unaccounted, :gc, :mapStartsOk, :mapStartsTot, :mapModes,
            :nuts_iters, :leapfrog, :ms_per_step, :draws],
    ) ==
          ["0.13", "6.4e-05", "9.4e-04", "1.1e-05", "6.8e-03", "0.03", "4.3e-03", "0.09",
        "0.07", "0.02", "6.7e-04", "1.8e-04", "0.72", "0.02", "2.0e-04", "0.64", "6.0e-03",
        "0.06", "0.11", "0.62", "0.01", "8", "8", "2", "4000", "18420.0", "0.1", "3000"]
end

@testset "the chain lines" begin
    @test fields(
        "res_chains.txt",
        [:chainsPooled, :chains_total, :chains_dropped, :rhatMax,
            :essMin, :essTailMin],
    ) == ["3", "4", "1", "1.0032", "1843", "1211"]
end

@testset "the modes line and the shares of the modes" begin
    @test fields("res_chains.txt", [:modes, :modeShareMax, :modeShareMin]) ==
          ["2", "0.81", "0.19"]
    # a mode with a tiny share is printed in scientific notation and still parsed
    @test fields("res_chains_negligible.txt", [:modes, :modeShareMax, :modeShareMin]) ==
          ["2", "1.0", "7.1e-10"]
end

@testset "optima" begin
    @test fields("res_optima.txt", [:optima]) == ["2"]
end

@testset "a report from before the chains has none of them" begin
    @test fields(
        "res_current.txt",
        [:chainsPooled, :chains_total, :rhatMax, :essMin,
            :essTailMin, :chains_dropped, :modes, :modeShareMax],
    ) ==
          ["", "", "", "", "", "0", "", ""]
end

@testset "keys keep their first-seen order" begin
    r = parse_report(slurp8(joinpath(data_dir, "res_current.txt")))
    ks = collect(keys(r))
    @test ks[1:3] == [:nAtoms, :lMax, :nQRaw]
    @test allunique(ks)
end

# The timing sections in data/timing_*.txt are the ones `Pipeline._write_timing` printed
# for a seed build (no sampling) of the fixtures 1EHZ (nucleic acid with modified
# nucleotides), 3HDD (protein + DNA) and 1CRN (protein only); note how a name longer than
# the label column touches its note.

# The text of res_current.txt before its timing section, then the timing section in the
# file `timing` of the test data.
report_with(timing) =
    split(slurp8(joinpath(data_dir, "res_current.txt")),
        r"(?m)^=== Timing ==="; limit = 2)[1] * slurp8(joinpath(data_dir, timing))

const NEW_STAGES = [:components, :compDwnld, :struct_chk, :classify,
    :moded_hyd, :heavy_atoms]

vals(r, ks) = [num_str(r[k]) for k in ks]

@testset "a nucleic-acid run: no PROPKA, the AMBER hydrogenation, modified residues" begin
    r = parse_report(report_with("timing_nucleic.txt"))
    @test vals(r, NEW_STAGES) == ["6.4e-04", "0", "0.01", "2.7e-03", "0.02", "0.03"]
    @test vals(r, [:propka, :pdb2pqr, :loadMolecule, :static_build, :wall]) ==
          ["", "0.01", "0.02", "0.20", "0.39"]
    # pdb2pqr (nucleic, none) is the pdb2pqr key; wall_ex drops only it
    @test near(0.38, r[:wall_ex])
end

@testset "a protein + nucleic run" begin
    r = parse_report(report_with("timing_mixed.txt"))
    @test vals(r, NEW_STAGES) == ["6.5e-04", "0", "4.3e-03", "1.5e-03", "", "9.7e-03"]
    @test vals(r, [:propka, :pdb2pqr]) == ["1.0e-03", "0.04"]
    @test near(0.32 - 0.001 - 0.04, r[:wall_ex])
end

@testset "a protein-only run" begin
    r = parse_report(report_with("timing_protein.txt"))
    @test vals(r, NEW_STAGES) == ["2.3e-04", "0", "8.0e-04", "3.0e-04", "", "1.9e-03"]
    @test near(0.91 - 0.89 - 0.000017, r[:wall_ex])
end

@testset "a component download counts as external time" begin
    text = report_with("timing_nucleic.txt")
    downloaded = replace(replace(text, "0 cache, 0 download]" => "0 cache, 1 download]"),
        "6.4e-04" => "0.25")
    r = parse_report(downloaded)
    @test vals(r, [:components, :compDwnld]) == ["0.25", "1"]
    @test near(0.39 - 0.01 - 0.25, r[:wall_ex])
    # 0 downloads: the table load stays in the wall clock
    @test near(0.38, parse_report(text)[:wall_ex])
end

@testset "a report without the new stages gives the numbers it always gave" begin
    r = parse_report(slurp8(joinpath(data_dir, "res_current.txt")))
    @test all(k -> r[k] == "", NEW_STAGES)
    @test r[:wall_ex] == 15.37
    # the same report, a nucleic run's stages added: only its pdb2pqr time goes
    r = parse_report(report_with("timing_nucleic.txt"))
    @test near(as_number(r[:wall]) - as_number(r[:pdb2pqr]), r[:wall_ex])
end

notes_of(file) = stage_notes(slurp8(joinpath(data_dir, file)))

@testset "stage notes parse" begin
    @test notes_of("timing_nucleic.txt") == Dict(
        "components" => "[17 residue names: 17 builtin, 0 cache, 0 download]",
        "structure checks" =>
            "[0 chains relabelled, 0 duplicate atoms dropped, " *
            "0 dummy-like findings]",
        "classify" => "[nucleic: AMBER, titration none]",
        "pdb2pqr (nucleic, none)" => "[cache hit]",
        "modified nucleotide hydrogens" =>
            "[14 residues: 14 hydrogenated through their " *
            "base, 0 without a base; 149 hydrogens placed, " *
            "232 in the free components' formulas]",
        "heavy atoms" => "[1821 in, 1821 out; 1 restored, 0 added by pdb2pqr]")
    pick(d, ks) = Dict(k => d[k] for k in ks)
    @test pick(
        notes_of("timing_mixed.txt"),
        ["classify", "propka", "pdb2pqr (mixed, propka)"],
    ) ==
          Dict("classify" => "[mixed: PARSE, titration propka]", "propka" => "[cache hit]",
        "pdb2pqr (mixed, propka)" => "[cache hit]")
    @test pick(notes_of("timing_protein.txt"), ["classify", "propka", "pdb2pqr"]) ==
          Dict("classify" => "[protein: PARSE, titration propka]",
        "propka" => "[cache miss]",
        "pdb2pqr" => "[cache hit]")
    @test notes_of("res_current.txt") == Dict("propka" => "[cache hit]",
        "pdb2pqr" => "[cache hit]")
    @test stage_notes("nAtoms = 3\n") == Dict{String,String}()
    r = parse_report(report_with("timing_nucleic.txt"))
    @test r.stage_notes["classify"] == "[nucleic: AMBER, titration none]"
    @test !(:stage_notes in keys(r))
end

# data/timing_protein_mse.txt is a protein with one MSE (HETATM, synthetic),
# data/timing_mixed_mse.txt SASDH39 (protein + DNA, 20 MSE); both are the unedited output
# of `Pipeline._write_timing`.
@testset "modified amino acids" begin
    r = parse_report(report_with("timing_protein_mse.txt"))
    @test vals(r, [:modedAaHyd, :moded_hyd]) == ["0.02", ""]
    @test vals(r, [:heavy_atoms, :pdb2pqr, :propka]) == ["0.03", "2.59", "8.6e-04"]
    @test near(3.39 - 0.00086 - 2.59, r[:wall_ex])
    r = parse_report(report_with("timing_mixed_mse.txt"))
    @test vals(r, [:modedAaHyd, :pdb2pqr]) == ["0.01", "7.56"]
    @test near(8.86 - 0.003 - 7.56, r[:wall_ex])
    r = parse_report(report_with("timing_nucleic.txt"))
    @test vals(r, [:moded_hyd, :modedAaHyd]) == ["0.02", ""]
    r = parse_report(report_with("timing_protein.txt"))
    @test vals(r, [:moded_hyd, :modedAaHyd]) == ["", ""]
    @test notes_of("timing_protein_mse.txt")["modified amino acid hydrogens"] ==
          "[1 residues: 1 hydrogenated through their parent, 0 without a parent; " *
          "9 hydrogens placed]"
    @test notes_of("timing_mixed_mse.txt")["modified amino acid hydrogens"] ==
          "[20 residues: 20 hydrogenated through their parent, 0 without a parent; " *
          "183 hydrogens placed]"
end

@testset "the note under its stage; a stage without one has none" begin
    @test notes_of("timing_notes_own_line.txt") == Dict(
        "components" => "[21 residue names: 21 builtin, 0 cache, 2 download]",
        "classify" => "[protein: PARSE, titration propka]",
        "pdb2pqr (nucleic, none)" => "[cache hit]")
    r = parse_report(report_with("timing_notes_own_line.txt"))
    @test vals(r, [:compDwnld, :components, :pdb2pqr]) == ["2", "2.7e-03", "0.04"]
    @test r[:sasa] == "0.10"
end

@testset "a note wrapped over lines is joined; the next stage is not swallowed" begin
    text =
        "=== Timing ===     seconds\n    heavy atoms        0.04\n" *
        "      [1821 in, 1821 out; 1 restored,\n      0 added by pdb2pqr]\n" *
        "    SASA               0.10\n"
    @test stage_notes(text) ==
          Dict("heavy atoms" => "[1821 in, 1821 out; 1 restored, 0 added by pdb2pqr]")
end

@testset "the last two lines of the timing table; plotting is left out of wall_ex" begin
    text = report_with("timing_protein.txt") * "fit timing  = 0.8 s\nplot timing = 0.1 s\n"
    r = parse_report(text)
    old = parse_report(report_with("timing_protein.txt"))
    @test vals(r, [:fit_timing, :plot_timing]) == ["0.8", "0.1"]
    # a report from before plotting has neither, and is read as it was
    @test vals(old, [:fit_timing, :plot_timing]) == ["", ""]
    @test near(old[:wall_ex] - 0.1, r[:wall_ex])
end

# a run log as `BAYSOL.writeLog` writes it: the stamp, then a section for each run: flat
# rows (cells padded with spaces, then a tab), the timing table as a person reads it (the
# notes in a column of their own), the machine last
const LOG_LINES = ["datetime\t27-10-2026 14:09:33 -0400", "", "=== fit1 ===",
    "revision        \t2d144a8", "refChi2        \tCRYSOL 1.5",
    "structure       \tnucleic",
    "pdb2pqrCache   \tmiss", "compDwnld\t2", "nAtoms         \t2592",
    "chi2            \t0.874", "rhoE           \t0.3362", "deltaRho1     \t-1.079",
    "deltaRho3     \t-5.49", "zDeltaRho3   \t0.4", "c1              \t1.2483",
    "c1Sat          \t1", "divergenceRate \t0.002", "leapfrog        \t69910",
    "mapStartsOk   \t70", "mapModes       \t3", "", "--- timing ---",
    "stage  seconds  % wall  (JIT)  (GC)  notes",
    "wall clock  12.00  100.0  (4.0)  (0.7)  process start to end",
    "  startup  2.00  16.7  (1.0)  (0.1)  process start to seedModel",
    "  static build  4.00  33.3  (1.0)  (0.1)",
    "    components  0.50  4.2  (0.0)  (0.0)  19 residue names, 2 download",
    "    propka  1.00  8.3  (0.0)  (0.0)  cache hit",
    "    pdb2pqr  0.40  3.3  (0.0)  (0.0)  nucleic, none; cache miss",
    "  sampling  5.00  41.7  (2.0)  (0.2)",
    "    MAP search + whitening  0.50  4.2  (0.0)  (0.0)  70/70 starts, 3 modes",
    "    NUTS  3.00  25.0  (0.0)  (0.0)  8k iters, 69.91k leapfrog, 0.016 ms/step",
    "    optima from the draws  0.18  1.5  (0.2)  (0.0)  0 extra chains",
    "    per-draw c1 re-profile + curves  0.20  1.7  (0.0)  (0.0)  8000 draws",
    "  plotting  1.00  8.3  (0.5)  (0.1)", "  report write  0.01  0.1  (0.0)  (0.0)",
    "  unaccounted  0.66  5.5  (0.4)  (0.2)", "GC: 0.60 s", "fit timing  = 11.00 s",
    "plot timing = 1.00 s", "", "--- machine ---", "machine.cpus    \t8", "",
    "=== fit2 ===", "chi2            \t2.5", "divergenceRate \t0"]

const LOG_TEXT = join(LOG_LINES, "\n") * "\n"

@testset "parse_log" begin
    runs = parse_log(LOG_TEXT)
    (t1, r1), (t2, r2) = runs
    @test [t1, t2] == ["fit1", "fit2"]
    @test [r1[k] for k in [:chi2_cmp, :rhoE, :d1, :d3, :c1, :div, :nAtoms]] ==
          ["0.874", "0.3362", "-1.079", "-5.49", "1.2483", "0.002", "2592"]
    @test r1[:refChi2] == "CRYSOL 1.5"
    @test r1[:dro3_MAP] == "-5.49"
    @test r1[:z3] == "0.4"
    @test r1[:sat] == "true"
    @test parse_log("=== x ===\nc1Sat\t0\n")[1][2][:sat] == "false"
    @test [r1[k] for k in [:mapStartsOk, :mapModes, :nModes]] == ["70", "3", "3"]
    @test r1[:leapfrog] == "69910"
    @test [
        r1[k] for k in [:wall, :startup, :propka, :pdb2pqr, :nuts, :plot_timing, :gc,
            :fit_timing]
    ] == ["12.00", "2.00", "1.00", "0.40", "3.00", "1.00", "0.60", "11.00"]
    # what a label carries: the NUTS iterations are not in the stats rows
    @test [r1[:msStep], r1[:draws]] == ["0.016", "8000"]
    # 12 - 2 (startup) - 1 (propka) - 0.4 (pdb2pqr) - 0.5 (components, 2 of them downloaded)
    # - 1 (plot)
    @test abs(7.1 - r1[:wall_ex]) < 1e-9
    @test r1.stage_notes == Dict("wall clock" => "[process start to end]",
        "startup" => "[process start to seedModel]",
        "components" => "[19 residue names, 2 download]", "propka" => "[cache hit]",
        "pdb2pqr" => "[nucleic, none; cache miss]",
        "MAP search + whitening" => "[70/70 starts, 3 modes]",
        "NUTS" => "[8k iters, 69.91k leapfrog, 0.016 ms/step]",
        "optima from the draws" => "[0 extra chains]",
        "per-draw c1 re-profile + curves" => "[8000 draws]")
    @test [r2[:d1], r2[:wall], r2[:refChi2]] == ["", "", ""]
    @test r2[:chi2] == "2.5"
    @test length(runs) == 2
    @test isempty(parse_log("datetime\t1\n\n"))
    @test first(keys(r1)) == :nAtoms
end

end

# --- Table

module TTable
using Test
using Dev
using Dev.Report: Run
using OrderedCollections: OrderedDict
using .Main.Helpers

const RT = Dev.Results.Table

# A parsed run with sensible defaults, overridden by the key/value pairs.
function report_dict(; kvs...)
    d = OrderedDict{Symbol,Any}(:chi2 => "+21.485", :chi2_cmp => "+21.485",
        :rhoE => "+0.34", :d1 => "+0.04", :d2 => "+1.67", :d3 => "+0.50",
        :c1 => "+1.201",
        :sat => "false", :div => "0.0000")
    for (k, v) in kvs
        d[k] = v
    end
    return Run(d, Dict{String,String}())
end

@testset "nothing at a bound: no bold, a true minus sign, 3 significant digits" begin
    @test RT.row("SASDX one", report_dict(d1 = "-0.37", d3 = "-2.5"), "EOM 11.3") ==
          ["SASDX one", "21.5", "EOM 11.3", "−0.37", "1.67", "−2.50", "1.201", "0"]
end

@testset "the table shows the comparison chi2" begin
    @test RT.row("r", report_dict(chi2 = "+0.9", chi2_cmp = "+1.2"), "-")[2] == "1.2"
end

@testset "contrasts within tolerance of their bounds are bold" begin
    # rhoE 0.34 puts the delta-rho3 bounds at -11.33 and 2.833
    @test RT.row("r", report_dict(d1 = "+1.99", d2 = "-9.97", d3 = "+2.83"), "-") ==
          ["r", "21.5", "-", "**1.99**", "**−9.97**", "**2.83**", "1.201", "0"]
    @test RT.row("r", report_dict(d3 = "-11.30"), "-")[6] == "**−11.30**"
end

@testset "saturated c1" begin
    @test RT.row("r", report_dict(c1 = "+0.780", sat = "true"), "-")[7] ==
          "**0.780 (saturated)**"
end

@testset "divergences print as a percentage, bold above 5 %" begin
    @test [
        RT.row("r", report_dict(div = d), "-")[8] for d in ["0.0030", "0.0600", "0.0500"]
    ] ==
          ["0.3 %", "**6.0 %**", "5.0 %"]
end

@testset "table cells normalisation" begin
    @test RT.table_cells("| A   |  b  | c |\n| --- | :-: | -- |\n|  1  | 2   |  3 |") ==
          RT.table_cells("|A|b|c|\n|---|---|---|\n|1|2|3|")
    @test RT.table_cells("| a | 1 |") != RT.table_cells("| a | 2 |")
end

@testset "run labels from a folder and a section title" begin
    @test [RT.run_label("SASDMJ9", "SASDMJ9"), RT.run_label("SASDTK5", "fit2_model1")] ==
          ["SASDMJ9 —", "SASDTK5 fit2_model1"]
end

@testset "the Results table of fitting_tests/README.md is up to date" begin
    status, out = run_tool("results", "table", "--check")
    @test status == 0 && says(out, "is up to date")
    @test run_tool("results", "table", "--check", "SASDMJ9")[1] == 2
end

end

# --- Compare

module TCompare
using Test
using Dev
using Dev.Common
using Dev.Report
using OrderedCollections: OrderedDict
using .Main.Helpers

const C = Dev.Results.Compare

@testset "median" begin
    @test [C.median([3, 1, 2]), C.median([4, 1, 3, 2])] == [2, 2.5]
end

@testset "pct: linear interpolation between order statistics" begin
    @test [C.pct([1, 2, 3, 4, 5], 0.5), C.pct([1, 2, 3, 4, 5], 0.25),
        C.pct([1, 2, 3, 4, 5], 1.0), C.pct([7], 0.3)] == [3.0, 2.0, 5.0, 7.0]
end

@testset "commas: thousands separators" begin
    @test [C.commas(4782.4, 0), C.commas(1234567.891, 2), C.commas(12.3, 1),
        C.commas(-4782.4, 0)] == ["4,782", "1,234,567.89", "12.3", "-4,782"]
end

@testset "ratio, or n/a when a side is missing or zero" begin
    @test [C.ratio(6, 3), C.ratio(nothing, 3), C.ratio(6, 0), C.ratio(0, 3)] ==
          ["2.00x", "n/a", "n/a", "n/a"]
end

@testset "dash: formatting with a dash for empty" begin
    @test [C.dash("%.2f", 3.14159), C.dash("%.2f", ""), C.dash("%.2f", nothing)] ==
          ["3.14", "-", "-"]
end

@testset "total: a sum over reports, nothing when no report has the field" begin
    mk(x) = Run(OrderedDict{Symbol,Any}(:x => x, :y => ""), Dict{String,String}())
    reports = C.ResultSet("a" => mk("1.5"), "b" => mk("2.5"))
    @test (C.total(reports, :x), C.total(reports, :y)) == (4.0, nothing)
    # a key a report lacks entirely (a log has no `chains_dropped`) adds nothing
    @test C.total(reports, :nokey) === nothing
end

@testset "the per-fit CSV for three fixed revisions equals the verified golden file" begin
    if git_history()
        out = joinpath(scratch_dir(), "cmp.csv")
        status, _ =
            run_tool("results", "compare", "30f55ea", "81cf301", "24af397", "--no-tree",
                "--csv", out)
        @test status == 0
        @test slurp8(joinpath(data_dir, "compare_golden.csv")) == slurp8(out)
    end
end

@testset "an unknown revision stops with status 1 and names the tags" begin
    status, out = run_tool("results", "compare", "no-such-rev")
    @test status == 1 && occursin("unknown git revision 'no-such-rev'", out)
end

@testset "with no revision the baseline is the latest release tag" begin
    if git_history()
        status, out = run_tool("results", "compare")
        @test status == 0 &&
              occursin("baseline: $(latest_release()), the latest release", out)
    end
end

# The timing sections in data/timing_*.txt (see test-report.jl).
function report_with(timing)
    text = slurp8(joinpath(data_dir, "res_current.txt"))
    timing === nothing && return parse_report(text)
    head = split(text, r"(?m)^=== Timing ==="; limit = 2)[1]
    return parse_report(head * slurp8(joinpath(data_dir, timing)))
end

# The timing table `compare` prints for the revisions `names` (name -> one fit).
function timing_text(names, reports)
    agg = Dict(n => C.ResultSet("fit" => r) for (n, r) in zip(names, reports))
    return capture_stdout(() -> C.timing_table(agg, names))
end

# The cells of the table row labelled `label` in `text`.
function cells_of(text, label)
    for line in split(text, '\n')
        cells = strip.(split(line, '|'))
        length(cells) >= 2 && cells[2] == label && return cells[3:end]
    end
    return nothing
end

@testset "the timing table with the new stages" begin
    old = report_with(nothing)
    text = timing_text(["old", "new"], [old, report_with("timing_nucleic.txt")])
    for label in ["components", "structure checks", "classify",
        "modified nucleotide hydrogens", "heavy atoms"]
        cells = cells_of(text, label)
        @test (cells[1], cells[3]) == ("-", "n/a")
    end
    @test cells_of(text, "components")[2] == "0.00 s"
    @test cells_of(text, "modified nucleotide hydrogens")[2] == "0.02 s"
    @test cells_of(text, "pdb2pqr (any variant)")[1:2] == ["0.00 s", "0.01 s"]
    @test cells_of(text, "propka")[2] == "-"
    @test cells_of(text, "wall clock excl. PROPKA/pdb2pqr/downloads")[2] == "0.38 s"
end

@testset "the judged revision lacks a stage the old one has" begin
    text =
        timing_text(["old", "new"], [report_with("timing_mixed.txt"), report_with(nothing)])
    @test cells_of(text, "heavy atoms")[1:2] == ["0.01 s", "-"]
    @test cells_of(text, "heavy atoms")[3] == "n/a"
end

@testset "a benchmark run without a stage shows it missing; variants are summed" begin
    fit = Dict(
        :stageName =>
            ["propka", "pdb2pqr (mixed, propka)", "pdb2pqr (nucleic, none)",
                "loadMolecule"], :stageSeconds => [1.0, 2.0, 3.0, 4.0])
    @test C.stage_total(fit, :stageSeconds, "pdb2pqr") == 5.0
    @test C.stage_total(fit, :stageSeconds, "components") === nothing
    @test C.stage_total(fit, :stageSeconds, "propka") == 1.0
    @test C.dash("%.2f", C.stage_total(Dict{Symbol,Any}(), :stageSeconds, "propka")) == "-"
end

@testset "the notes table" begin
    shown(pairs) = capture_stdout(() -> C.notes_table(C.ResultSet(pairs), "new"))
    nucleic = report_with("timing_nucleic.txt")
    mixed = report_with("timing_mixed.txt")
    hit = replace(
        slurp8(joinpath(data_dir, "timing_protein.txt")),
        "cache miss" => "cache hit",
    )
    protein_hit = parse_report(
        split(slurp8(joinpath(data_dir, "res_current.txt")),
            r"(?m)^=== Timing ==="; limit = 2)[1] * hit,
    )
    text = shown(["fitting_tests/A/res.txt" => nucleic, "fitting_tests/B/res.txt" => mixed])
    @test occursin("[nucleic: AMBER, titration none]", text)
    @test occursin("[mixed: PARSE, titration propka]", text)
    @test occursin("14 residues: 14 hydrogenated through their base", text)
    @test occursin("[17 residue names: 17 builtin, 0 cache, 0 download]", text)
    @test occursin("every fit is protein-only",
        shown(["p" => protein_hit, "o" => report_with(nothing)]))
    @test occursin("[cache miss]", shown(["p" => report_with("timing_protein.txt")]))
end

@testset "modified amino acids in the table and the notes" begin
    text = timing_text(
        ["old", "new"],
        [report_with(nothing),
            report_with("timing_protein_mse.txt")],
    )
    cells = cells_of(text, "modified amino acid hydrogens")
    @test cells[1:3] == ["-", "0.02 s", "n/a"]
    @test cells_of(text, "modified nucleotide hydrogens")[1] == "-"
    fit = Dict(
        :stageName =>
            ["modified nucleotide hydrogens", "modified amino acid hydrogens"],
        :stageSeconds => [1.0, 2.0])
    @test [C.stage_total(fit, :stageSeconds, "modified nucleotide hydrogens"),
        C.stage_total(fit, :stageSeconds, "modified amino acid hydrogens")] == [1.0, 2.0]
    r = report_with("timing_mixed_mse.txt")
    out = capture_stdout(() -> C.notes_table(C.ResultSet("fit" => r), "new"))
    @test occursin("20 hydrogenated through their parent", out)
end

end
