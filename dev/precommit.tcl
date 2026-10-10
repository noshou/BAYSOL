#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Everything to check before committing, in one command:
#
#     tclsh dev/precommit.tcl [--quick] [--dry-run]
#
# The steps, in order (all of them run even if
# one fails; the exit status is 1 if any failed):
#   tcl-tests      the tests of the Tcl tools (`dev/tcltests.tcl`)
#   unit-tests     the unit and integration suite
#                  (`julia --project=test dev/unittests.jl`, ~90 s)
#   concurrency-tests  the concurrency and race tests again with six Julia threads
#                  and an interactive one (`julia -t 6,1 dev/unittests.jl
#                  concurrency parallel gcpause cache`, ~1 min): the full
#                  unit-tests step runs with the thread count given by `--threads`
#                  (default one), where the parallel paths are not exercised by
#                  real threads
#   whitespace     trailing whitespace on the lines you changed is stripped
#                  (`git diff --check HEAD` finds the lines of tracked files; every
#                  line of an untracked, unignored text file is stripped) and
#                  reported, never a failure; a leftover conflict marker cannot be
#                  fixed by a tool and is a failure
#   tcl-format     every .tcl/.test file is formatted by tclfmt (`format.tcl --check --tcl`)
#   julia-format   every .jl file is formatted by JuliaFormatter.jl
#                  (`format.tcl --check --julia`, settings in .JuliaFormatter.toml);
#                  `format.tcl --apply` fixes both
#   line-length    no line of code (.jl .tcl .test .scss .yml) is longer than 92
#                  characters (`linelen.tcl --check`); a violation refuses the commit
#   results-table  the Results table in test/fitting_tests/README.md equals the one
#                  generated from the reports (`results_table.tcl --check`)
#   docs-build     the strict documentation build (`julia --project=docs
#                  docs/make.jl`, ~20 s); it also regenerates the (gitignored)
#                  copies of the READMEs under docs/src/guides and docs/src/testing
#
#   --quick     skip the Julia steps (unit-tests, concurrency-tests, julia-format,
#               docs-build): the checks that take a second
#   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
#               4,1); default one
#   --dry-run   print what would run, run nothing
#
# It never runs a fitting test or a benchmark (those need a quiet
# machine and the owner's approval). Needs Tcl 9 and Tcllib; the
# Julia steps need `julia` on the PATH (or JULIA=/path/to/julia).

source [file join [file dirname [info script]] .. test utils common.tcl]
set SCRIPT [info script]

namespace eval precommit {
    namespace path ::util

    # File types scanned for trailing whitespace in untracked files.
    variable TEXT_EXTENSIONS {.jl .tcl .test .md .tsv .toml .json .yml}

    # Strips the trailing blanks (spaces and tabs) from the lines of $path listed
    # in $only (1-based; the word `all` for every line), leaving everything else,
    # line endings included, untouched. Returns how many lines changed.
    proc strip_lines {path only} {
        set ch [open $path rb]
        fconfigure $ch -encoding utf-8 -translation binary
        set text [read $ch]
        close $ch
        set lines [split $text "\n"]
        set n 0
        set i 0
        foreach line $lines {
            incr i
            if {$only ne "all" && $i ni $only} {
                continue
            }
            set stripped [regsub {[ \t]+(\r?)$} $line {\1}]
            if {$stripped ne $line} {
                lset lines [expr {$i - 1}] $stripped
                incr n
            }
        }
        if {$n} {
            set ch [open $path wb]
            fconfigure $ch -encoding utf-8 -translation binary
            puts -nonewline $ch [join $lines "\n"]
            close $ch
        }
        return $n
    }

    # Strips trailing whitespace from the lines you changed (`git diff --check HEAD`
    # names them in the tracked files; an untracked, unignored text file is stripped
    # whole) and says what it did. Conflict markers are the one problem it cannot
    # fix: they are listed (at most 12) and make it return false. Otherwise true.
    proc whitespace {} {
        global ROOT
        variable TEXT_EXTENSIONS
        set problems {}
        set stripped [dict create]
        # exec turns a non-zero exit (problems found)
        # into an error whose message is git's output
        catch {exec git -C $ROOT -c core.quotepath=false diff --check HEAD} out
        set at [dict create]
        foreach line [split $out "\n"] {
            if {[regexp {^(\S.*?):(\d+): trailing whitespace\.$} $line -> f n]} {
                dict lappend at $f $n
            } elseif {[regexp {^\S.*:\d+: } $line]} {
                lappend problems $line
            }
        }
        dict for {f lines} $at {
            set n [strip_lines [file join $ROOT $f] $lines]
            dict set stripped $f $n
        }
        set untracked [git -c core.quotepath=false ls-files -o --exclude-standard]
        foreach f [split $untracked "\n"] {
            if {$f eq "" || [file extension $f] ni $TEXT_EXTENSIONS} {
                continue
            }
            set n [strip_lines [file join $ROOT $f] all]
            if {$n} {
                dict set stripped $f $n
            }
            set i 0
            foreach line [split [slurp [file join $ROOT $f]] "\n"] {
                incr i
                if {[regexp {^(<<<<<<<|>>>>>>>) } $line]} {
                    lappend problems "$f:$i: conflict marker"
                }
            }
        }
        if {[dict size $stripped]} {
            set total 0
            dict for {f n} $stripped {
                incr total $n
            }
            puts "  stripped trailing whitespace from $total lines in\
                [dict size $stripped] files:"
            foreach f [lrange [dict keys $stripped] 0 11] {
                puts "    $f ([dict get $stripped $f])"
            }
            if {[dict size $stripped] > 12} {
                puts "    ... and [expr {[dict size $stripped] - 12}] more"
            }
        }
        foreach p [lrange $problems 0 11] {
            puts "  $p"
        }
        if {[llength $problems] > 12} {
            puts "  ... and [expr {[llength $problems] - 12}] more"
        }
        return [expr {![llength $problems]}]
    }

    # Entry point.
    proc run {argv} {
        global ROOT
        if {"--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }
        foreach a $argv {
            if {$a ni {--quick --dry-run}} {
                puts stderr "precommit.tcl: unknown option $a (one of: --quick, --dry-run)"
                exit 2
            }
        }
        set quick [expr {"--quick" in $argv}]
        set dry [expr {"--dry-run" in $argv}]
        set tclsh [info nameofexecutable]
        set utils [file join $ROOT test utils]
        set run [file join $ROOT dev]

        # name, runs in --quick, how to run it ("" = the whitespace proc)
        set steps [list \
            [list tcl-tests 1 [list \
                $tclsh [file join $run tcltests.tcl]]] \
            [list unit-tests 0 [list \
                JULIA --startup-file=no \
                --project=[file join $ROOT test] \
                [file join $run unittests.jl]]] \
            [list concurrency-tests 0 [list \
                JULIA --startup-file=no -t 6,1 \
                --project=[file join $ROOT test] \
                [file join $run unittests.jl] concurrency parallel gcpause cache]] \
            [list whitespace 1 {}] \
            [list tcl-format 1 [list \
                $tclsh [file join $run format.tcl] --check --tcl]] \
            [list julia-format 0 [list \
                $tclsh [file join $run format.tcl] --check --julia]] \
            [list line-length 1 [list \
                $tclsh [file join $run linelen.tcl] --check]] \
            [list results-table 1 [list \
                $tclsh [file join $utils results_table.tcl] --check]] \
            [list docs-build 0 [list \
                JULIA --startup-file=no \
                --project=[file join $ROOT docs] \
                [file join $ROOT docs make.jl]]]]
        if {!$dry && !$quick} {
            set julia [find_julia]
        }

        set results {}
        foreach step $steps {
            lassign $step name in_quick cmd
            if {$quick && !$in_quick} {
                lappend results [list $name skipped 0]
                continue
            }
            puts "\n=== $name"
            if {$dry} {
                if {$cmd eq ""} {
                    puts "(strip trailing whitespace from the changed lines;\
                        fail on conflict markers)"
                } else {
                    puts "\$ [join $cmd { }]"
                }
                continue
            }
            if {[lindex $cmd 0] eq "JULIA"} {
                set cmd [concat [list $julia] [lrange $cmd 1 end]]
            }
            set t0 [clock milliseconds]
            if {$cmd eq ""} {
                set ok [whitespace]
            } else {
                set ok [sh 0 {*}$cmd]
            }
            set secs [expr {([clock milliseconds] - $t0) / 1000.0}]
            lappend results [list $name [expr {$ok ? "ok" : "FAILED"}] $secs]
        }
        if {$dry} {
            return
        }

        puts "\n=== summary"
        set failed 0
        foreach r $results {
            lassign $r name state secs
            if {$state eq "skipped"} {
                set shown ""
            } else {
                set shown [format "%.1f s" $secs]
            }
            puts [format "  %-14s %-8s %s" $name $state $shown]
            if {$state eq "FAILED"} {
                set failed 1
            }
        }
        if {$failed} {
            puts "NOT ready to commit"
            exit 1
        } elseif {$quick} {
            puts "quick checks passed (the unit suite and the docs build were skipped)"
        } else {
            puts "ready to commit"
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main precommit::run $argv
}
