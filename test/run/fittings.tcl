#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the end-to-end fitting tests (test/fitting_tests/<ID>/): each is a script that fits one SASBDB entry
# and writes its report and figures next to it.
#
#     tclsh test/run/fittings.tcl [ID ...] [--no-fit] [--bench] [--shannon] [--approved] [--report] [--table] [--fixme] [--dry-run]
#
#   ID         the fitting-test folders to run (SASDMJ9, SASDBS6, ...). Every one must exist, or nothing runs.
#              With none given, every fitting test runs.
#   --bench    also run the cold / steady-state benchmark on the selected fits (test/utils/bench.tcl)
#   --shannon  also run the Shannon-binning validation on the selected fits (test/utils/shannon_validation.jl):
#              the MAP and Laplace width on the unbinned curve against k = 8, 12, 16 bins per Shannon channel, no
#              sampling, against the criteria in that file's header; writes test/baselines/results/shannon-<stamp>.tsv
#   --approved  with --bench or --shannon: the owner has approved this run. Without it these steps are no-ops
#              that only print their plan. Why: they take minutes of one core (a benchmark's timings also need a
#              quiet machine), and AI agents tend to start them unasked, so the owner's per-run approval is a
#              small safeguard.
#   --no-fit   skip the fits themselves (the later steps do not need them rerun)
#   --report   afterwards, print the Results-table rows of the selected fits (test/utils/results_table.tcl)
#   --table    afterwards, rewrite the Results table in test/fitting_tests/README.md from all the reports
#              (test/utils/results_table.tcl --update); covers every fit, whatever IDs are named
#   --fixme    afterwards, run the sampler diagnostics on the selected fits (test/utils/diagnose.tcl report)
#   --dry-run  print what would be run, run nothing
#
# The steps run in that order: the fits, the benchmark, the Shannon validation, the report, the table, the diagnostics. A failing fit does not
# stop the others; the exit status is 1 if any step failed. The fits rewrite the res*.txt and figures
# in their folders. Needs Tcl 9 and `julia` on the PATH (or JULIA=/path/to/julia); shared helpers are in
# test/utils/common.tcl.

source [file join [file dirname [info script]] .. utils common.tcl]
set SCRIPT [info script]

namespace eval fittings {
    namespace path ::util

    variable FLAGS {--bench --shannon --approved --no-fit --report --table --fixme --dry-run}

    # Stops with a message (and exit status 2) when the command line is wrong.
    proc fail {msg} { puts stderr "fittings.tcl: $msg"; exit 2 }

    # Prints a command and, unless $dry, runs it with our terminal. True when it succeeded.
    proc sh {dry args} {
        puts "\$ [join $args { }]"
        if {$dry} { return 1 }
        return [expr {![catch {exec {*}$args <@stdin >@stdout 2>@stderr}]}]
    }

    # The `ID[:tag]` specs of the fitting tests $selected: one per tag, or the bare ID for a single-run script.
    proc specs_of {selected} {
        set out {}
        foreach id $selected {
            foreach tag [tags_of $id] { lappend out [expr {$tag eq "" ? $id : "$id:$tag"}] }
        }
        return $out
    }

    # Entry point.
    proc run {argv} {
        global ROOT
        variable FLAGS
        if {"--help" in $argv || "-h" in $argv} { ::usage $::SCRIPT; return }

        set flags {}
        set requested {}
        foreach a $argv {
            if {[string match --* $a]} {
                if {$a ni $FLAGS} { fail "unknown option $a (one of: [join $FLAGS {, }])" }
                lappend flags $a
            } else {
                lappend requested $a
            }
        }
        if {"--approved" in $flags && "--bench" ni $flags && "--shannon" ni $flags} { fail "--approved only applies together with --bench or --shannon" }
        set dry [expr {"--dry-run" in $flags}]

        # the folders to run: every one asked for must exist; none asked for means all of them
        set missing {}
        foreach id $requested { if {$id ni [ids]} { lappend missing $id } }
        if {[llength $missing]} {
            fail "no fitting test folder for: [join $missing {, }] (available: [join [ids] { }])"
        }
        set selected [expr {[llength $requested] ? $requested : [ids]}]

        if {[catch {find_julia} julia]} { fail $julia }
        set tclsh [info nameofexecutable]
        set utils [file join $ROOT test utils]
        set failed {}

        # 1. the fits
        foreach id [expr {"--no-fit" in $flags ? {} : $selected}] {
            puts "\n=== fit: $id"
            if {![sh $dry $julia --startup-file=no --project=[file join $ROOT test fitting_tests] [script_of $id]]} {
                lappend failed "fit $id"
            }
        }

        # 2. the benchmark (a no-op that prints its plan unless --approved is given)
        if {"--bench" in $flags} {
            puts "\n=== benchmark"
            set cmd [list $tclsh [file join $utils bench.tcl]]
            if {"--approved" in $flags} { lappend cmd --approved }
            if {![sh $dry {*}$cmd {*}[specs_of $selected]]} { lappend failed benchmark }
        }

        # 2b. the Shannon validation (a no-op that prints its plan unless --approved is given)
        if {"--shannon" in $flags} {
            puts "\n=== Shannon validation"
            set out [file join $ROOT test baselines results shannon-[clock format [clock seconds] -format %Y%m%d-%H%M].tsv]
            set cmd [list $julia --startup-file=no --project=[file join $ROOT test fitting_tests] \
                [file join $utils shannon_validation.jl] --out $out {*}[specs_of $selected]]
            if {"--approved" in $flags} {
                file mkdir [file dirname $out]
                if {![sh $dry {*}$cmd]} { lappend failed shannon }
            } else {
                puts "Shannon validation: not running. It runs the MAP search and Hessian of every selected fit on the unbinned\ncurve and at k = 8, 12, 16 (minutes of one core for the whole suite) and writes only a TSV. Each run needs the\nrepository owner's explicit approval; re-run with --approved once it has been approved.\nPlanned: [join $cmd { }]"
            }
        }

        # 3. the report: the Results-table rows of the selected fits
        if {"--report" in $flags} {
            puts "\n=== report"
            if {![sh $dry $tclsh [file join $utils results_table.tcl] {*}$requested]} { lappend failed report }
        }

        # 3b. the Results table of the fitting tests' README
        if {"--table" in $flags} {
            puts "\n=== table"
            if {![sh $dry $tclsh [file join $utils results_table.tcl] --update]} { lappend failed table }
        }

        # 4. the diagnostics
        if {"--fixme" in $flags} {
            puts "\n=== diagnostics"
            if {![sh $dry $tclsh [file join $utils diagnose.tcl] report {*}[specs_of $selected]]} { lappend failed diagnostics }
        }

        if {[llength $failed]} { puts stderr "\nfittings.tcl: failed: [join $failed {, }]"; exit 1 }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main fittings::run $argv
}
