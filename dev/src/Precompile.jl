# SPDX-License-Identifier: LGPL-3.0-or-later

# What the package compiles ahead of time (PrecompileTools): the code paths every tool run
# goes through, on small made-up inputs, so that a fresh process and the first command of
# a new daemon do not pay to compile them.
using PrecompileTools: @compile_workload, @setup_workload

@setup_workload begin
    log_text = join(
        ["datetime\t01-01-2026 00:00:00 +0000", "", "=== run ===", "chi2\t1.5",
            "rho_e\t0.33", "", "--- timing ---",
            "stage  seconds  % wall  (JIT)  (GC)  notes",
            "wall clock  12.00  100.0  (4.0)  (0.7)  process start to end",
            "  NUTS  3.00  25.0  (0.0)  (0.0)  8k iters, 69.91k leapfrog, 0.016 ms/step",
            ""],
        "\n")
    report_text = "n_atoms = 10\nχ² = 1.5\nwall clock    12.0   100.0\n"
    @compile_workload begin
        redirect_stdio(stdout = devnull, stderr = devnull) do
            # the dispatcher, the help of every tool and the error path
            main("help", String[])
            for (name, _) in TASKS
                main(name, ["--help"])
            end
            main("fmt", ["--bogus"])
            # the helpers every tool uses
            Common.fmt("%.3g", 21.485)
            Common.num_str(12170.0)
            Common.split_args("t", ["--out"], ["--dry-run"], ["a", "--out", "x"])
            Common.take_threads(["a", "--threads", "4"])
            # the text rules of fmt
            Fmt.with_header("x = 1\n", ".jl")
            Fmt.reindent_scss("a {\ncolor: red;\n}\n")
            Fmt.reflow_lines(["# " * join(fill("word", 40), " ")], "jl")
            Fmt.trim_trailing_space("a  \nb\t\n")
            Fmt.version_problem("version = \"1\"\nrelease_name = \"x\"\n")
            # the readers of the run logs and the tools built on them
            Report.parse_log(log_text)
            Report.parse_report(report_text)
            Report.stage_notes(log_text)
            Results.Compare.median([3, 1, 2])
            Results.Compare.pct([1, 2, 3, 4], 0.5)
            Results.Compare.commas(4782.4, 0)
            Results.Table.table_cells("| a | b |\n|---|---|\n| 1 | 2 |")
        end
    end
end
