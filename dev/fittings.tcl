#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the end-to-end fitting tests (test/fitting_tests/<ID>/): each is a script
# that fits one SASBDB entry and writes its report and figures next to it.
#
#     tclsh dev/fittings.tcl [ID ...] [--no-fit] [--bench] [--approved] [--report]
#         [--table] [--fixme] [--trace-compile FILE] [--dry-run]
#
#   ID         the fitting-test folders to run (SASDMJ9, SASDBS6, ...). Every one
#              must exist, or nothing runs. With none given, every fitting test runs.
#   --bench    also run the cold / steady-state benchmark on the selected fits
#              (test/utils/bench.tcl)
#   --approved  with --bench: the owner has approved this benchmark run. Without it
#              the benchmark is a no-op that only prints its plan. Why: timings
#              need a quiet machine, and AI agents tend to start a benchmark
#              without checking for one, so the owner's per-run approval (their
#              confirmation that nothing else is running) is a small safeguard.
#              (The slow validations are run by validate.tcl.)
#   --no-fit   skip the fits themselves (the later steps do not need them rerun)
#   --report   afterwards, print the Results-table rows of the selected fits
#              (test/utils/results_table.tcl)
#   --table    afterwards, rewrite the Results table in test/fitting_tests/README.md
#              from all the reports (test/utils/results_table.tcl --update); covers
#              every fit, whatever IDs are named
#   --fixme    afterwards, run the sampler diagnostics on the selected fits
#              (dev/diagnose.tcl --report)
#   --trace-compile FILE  run the fits with Julia's --trace-compile=FILE (the
#              methods each fit's process compiles at run time, which a precompile
#              workload should have covered; one file for all the fits, appended)
#   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
#              4,1); default one
#   --dry-run  print what would be run, run nothing
#
# The steps run in that order: the fits, the benchmark, the report, the
# table, the diagnostics. A failing fit does not stop the others; the
# exit status is 1 if any step failed. The fits rewrite the res*.txt
# and figures in their folders. Needs Tcl 9 and `julia` on the PATH (or
# JULIA=/path/to/julia); shared helpers are in test/utils/common.tcl.

source [file join [file dirname [info script]] .. test utils common.tcl]
set SCRIPT [info script]

namespace eval fittings {
    namespace path ::util

    variable FLAGS {--bench --approved --no-fit --report --table --fixme --dry-run}
    variable VALUED {--trace-compile} ;# options that take a value

    # Entry point.
    proc run {argv} {
        global ROOT
        variable FLAGS
        if {"--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }

        variable VALUED
        lassign [split_args fittings.tcl $VALUED $FLAGS $argv {one of}] opts flags requested
        set trace ""
        if {[dict exists $opts --trace-compile]} {
            set trace [file normalize [dict get $opts --trace-compile]]
        }
        if {"--approved" in $flags && "--bench" ni $flags} {
            fail fittings.tcl "--approved only applies together with --bench"
        }
        set dry [expr {"--dry-run" in $flags}]

        # the folders to run: every one asked for must
        # exist; none asked for means all of them
        check_folders fittings.tcl $requested 0
        set selected [expr {[llength $requested] ? $requested : [ids]}]

        if {[catch {find_julia} julia]} {
            fail fittings.tcl $julia
        }
        set tclsh [info nameofexecutable]
        set utils [file join $ROOT test utils]
        set failed {}

        # 1. the fits
        foreach id [expr {"--no-fit" in $flags ? {} : $selected}] {
            puts "\n=== fit: $id"
            set jl [list $julia --startup-file=no]
            if {$trace ne ""} {
                lappend jl --trace-compile=$trace
            }
            set project [file join $ROOT test fitting_tests]
            if {![sh $dry {*}$jl --project=$project [script_of $id]]} {
                lappend failed "fit $id"
            }
        }

        # 2. the benchmark (a no-op that prints its plan unless --approved is given)
        if {"--bench" in $flags} {
            puts "\n=== benchmark"
            set cmd [list $tclsh [file join $utils bench.tcl]]
            if {"--approved" in $flags} {
                lappend cmd --approved
            }
            if {![sh $dry {*}$cmd {*}[specs_of $selected]]} {
                lappend failed benchmark
            }
        }

        # 3. the report: the Results-table rows of the selected fits
        if {"--report" in $flags} {
            puts "\n=== report"
            if {![sh $dry $tclsh [file join $utils results_table.tcl] {*}$requested]} {
                lappend failed report
            }
        }

        # 3b. the Results table of the fitting tests' README
        if {"--table" in $flags} {
            puts "\n=== table"
            if {![sh $dry $tclsh [file join $utils results_table.tcl] --update]} {
                lappend failed table
            }
        }

        # 4. the diagnostics
        if {"--fixme" in $flags} {
            puts "\n=== diagnostics"
            if {
                ![sh $dry $tclsh [file join $ROOT dev diagnose.tcl] --report \
                    {*}[specs_of $selected]]
            } {
                lappend failed diagnostics
            }
        }

        if {[llength $failed]} {
            puts stderr "\nfittings.tcl: failed: [join $failed {, }]"
            exit 1
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main fittings::run $argv
}
