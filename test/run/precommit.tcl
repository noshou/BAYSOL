#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Everything to check before committing, in one command:
#
#     tclsh test/run/precommit.tcl [--quick] [--dry-run]
#
# The steps, in order (all of them run even if one fails; the exit status is 1 if any failed):
#   whitespace     no trailing whitespace or conflict markers in what you changed (`git diff --check HEAD` for
#                  tracked files, a scan of the untracked, unignored text files for new ones)
#   results-table  the Results table in test/fitting_tests/README.md equals the one generated from the
#                  reports (`results_table.tcl --check`)
#   tcl-tests      the tests of the Tcl tools (`test/run/tcltests.tcl`)
#   unit-tests     the unit and integration suite (`julia --project=test test/run/unittests.jl`, ~90 s)
#   docs-build     the strict documentation build (`julia --project=docs docs/make.jl`, ~20 s); it also
#                  regenerates the copies of the READMEs under docs/src/, and the files it changed are listed
#                  so they go into the commit
#
#   --quick     skip the two Julia steps (unit-tests, docs-build): the checks that take a second
#   --dry-run   print what would run, run nothing
#
# It never runs a fitting test or a benchmark (those need a quiet machine and the owner's approval). Needs Tcl 9
# and Tcllib; the Julia steps need `julia` on the PATH (or JULIA=/path/to/julia).

source [file join [file dirname [info script]] .. utils common.tcl]
set SCRIPT [info script]

namespace eval precommit {
    namespace path ::util

    # File types scanned for trailing whitespace in untracked files.
    variable TEXT_EXTENSIONS {.jl .tcl .test .md .tsv .toml .json .yml}

    # `git diff --check HEAD` plus a scan of the untracked files. Prints the offending lines (at most 12) and
    # returns true when there are none.
    proc whitespace {} {
        global ROOT
        set problems {}
        # exec turns a non-zero exit (problems found) into an error whose message is git's output
        catch {exec git -C $ROOT -c core.quotepath=false diff --check HEAD} out
        foreach line [split $out "\n"] {
            if {[regexp {^\S.*:\d+: } $line]} { lappend problems $line }
        }
        foreach f [split [git -c core.quotepath=false ls-files -o --exclude-standard] "\n"] {
            variable TEXT_EXTENSIONS
            if {$f eq "" || [file extension $f] ni $TEXT_EXTENSIONS} continue
            set n 0
            foreach line [split [slurp [file join $ROOT $f]] "\n"] {
                incr n
                if {[regexp {[ \t]+$} $line]} { lappend problems "$f:$n: trailing whitespace (untracked file)" }
                if {[regexp {^(<<<<<<<|>>>>>>>) } $line]} { lappend problems "$f:$n: conflict marker" }
            }
        }
        foreach p [lrange $problems 0 11] { puts "  $p" }
        if {[llength $problems] > 12} { puts "  ... and [expr {[llength $problems] - 12}] more" }
        return [expr {![llength $problems]}]
    }

    # Runs a command with our terminal; true when it succeeded.
    proc sh {args} {
        puts "\$ [join $args { }]"
        return [expr {![catch {exec {*}$args <@stdin >@stdout 2>@stderr}]}]
    }

    # Files under docs/src/guides and docs/src/testing that differ from the index (the build regenerates them
    # from the READMEs): they belong in the commit.
    proc docs_copies_changed {} {
        global ROOT
        set out {}
        foreach line [split [git status --porcelain -- docs/src/guides docs/src/testing] "\n"] {
            if {$line ne ""} { lappend out [string trim [string range $line 2 end]] }
        }
        return $out
    }

    # Entry point.
    proc run {argv} {
        global ROOT
        if {"--help" in $argv || "-h" in $argv} { ::usage $::SCRIPT; return }
        foreach a $argv {
            if {$a ni {--quick --dry-run}} { puts stderr "precommit.tcl: unknown option $a (one of: --quick, --dry-run)"; exit 2 }
        }
        set quick [expr {"--quick" in $argv}]
        set dry [expr {"--dry-run" in $argv}]
        set tclsh [info nameofexecutable]
        set utils [file join $ROOT test utils]
        set run [file join $ROOT test run]

        # name, runs in --quick, how to run it ("" = the whitespace proc)
        set steps [list \
            [list whitespace 1 {}] \
            [list results-table 1 [list $tclsh [file join $utils results_table.tcl] --check]] \
            [list tcl-tests 1 [list $tclsh [file join $run tcltests.tcl]]] \
            [list unit-tests 0 [list JULIA --startup-file=no --project=[file join $ROOT test] [file join $run unittests.jl]]] \
            [list docs-build 0 [list JULIA --startup-file=no --project=[file join $ROOT docs] [file join $ROOT docs make.jl]]]]
        if {!$dry && !$quick} { set julia [find_julia] }

        set results {}
        foreach step $steps {
            lassign $step name in_quick cmd
            if {$quick && !$in_quick} { lappend results [list $name skipped 0]; continue }
            puts "\n=== $name"
            if {$dry} {
                puts [expr {$cmd eq "" ? "(scan the changed files for trailing whitespace and conflict markers)" : "\$ [join $cmd { }]"}]
                continue
            }
            if {[lindex $cmd 0] eq "JULIA"} { set cmd [concat [list $julia] [lrange $cmd 1 end]] }
            set t0 [clock milliseconds]
            set ok [expr {$cmd eq "" ? [whitespace] : [sh {*}$cmd]}]
            lappend results [list $name [expr {$ok ? "ok" : "FAILED"}] [expr {([clock milliseconds] - $t0) / 1000.0}]]
            if {$name eq "docs-build" && $ok} {
                set changed [docs_copies_changed]
                if {[llength $changed]} {
                    puts "the build regenerated or created these copies of the READMEs (add them to the commit):"
                    foreach f $changed { puts "  $f" }
                }
            }
        }
        if {$dry} return

        puts "\n=== summary"
        set failed 0
        foreach r $results {
            lassign $r name state secs
            puts [format "  %-14s %-8s %s" $name $state [expr {$state eq "skipped" ? "" : [format %.1f\ s $secs]}]]
            if {$state eq "FAILED"} { set failed 1 }
        }
        puts [expr {$failed ? "NOT ready to commit" : ($quick ? "quick checks passed (the unit suite and the docs build were skipped)" : "ready to commit")}]
        if {$failed} { exit 1 }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main precommit::run $argv
}
