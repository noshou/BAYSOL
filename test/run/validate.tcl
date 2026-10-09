#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs a validation: a slow, suite-wide check of one change against criteria fixed before the run (test/validation/<name>/).
#
#     tclsh test/run/validate.tcl --list
#     tclsh test/run/validate.tcl NAME [ID[:tag] ...] [--approved] [--dry-run]
#
#   --list      the validations and the question each answers
#   NAME        a folder of test/validation/ (shannon_binning, map_fstop, ...). An unknown name stops before anything runs.
#   ID ...      the fitting tests to run it on (SASDMJ9, SASDBS6, ...); every one must exist. None: all of them.
#   --approved  the owner has approved this run. Without it the validation is a no-op that only prints its plan. Why: a
#               validation runs the MAP search (or more) of dozens of fits, minutes of one core, and AI agents tend to start
#               such runs unasked, so the owner's per-run approval is a small safeguard.
#   --dry-run   print the command, run nothing
#
# With --approved the validation's script runs (Julia, in the test/fitting_tests environment) and writes its per-fit rows to
# test/validation/NAME/results/NAME-<stamp>.tsv, which is the evidence the validation's README refers to; it prints its verdict
# against the criteria in its README. Needs Tcl 9 and `julia` on the PATH (or JULIA=/path/to/julia); shared helpers are in
# test/utils/common.tcl.

source [file join [file dirname [info script]] .. utils common.tcl]
set SCRIPT [info script]

namespace eval validate {
    namespace path ::util

    variable FLAGS {--list --approved --dry-run}

    # Stops with a message (and exit status 2) when the command line is wrong.
    proc fail {msg} {
        puts stderr "validate.tcl: $msg"
        exit 2
    }

    # The validations: the sub-folders of test/validation/ that hold a validate.jl.
    proc names {} {
        global ROOT
        set out {}
        foreach f [lsort [glob -nocomplain -directory [file join $ROOT test validation] */validate.jl]] {
            lappend out [file tail [file dirname $f]]
        }
        return $out
    }

    # The question of validation $name: the first paragraph after the title of its README, on one line.
    proc question {name} {
        global ROOT
        set lines [split [slurp [file join $ROOT test validation $name README.md]] "\n"]
        set para {}
        foreach l [lrange $lines 1 end] {
            if {[string trim $l] eq ""} {
                if {[llength $para]} {
                    break
                } else {
                    continue
                }
            }
            lappend para [string trim $l]
        }
        return [join $para { }]
    }

    # Entry point.
    proc run {argv} {
        global ROOT
        variable FLAGS
        if {"--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }

        set flags {}
        set words {}
        foreach a $argv {
            if {[string match --* $a]} {
                if {$a ni $FLAGS} {
                    fail "unknown option $a (one of: [join $FLAGS {, }])"
                }
                lappend flags $a
            } else {
                lappend words $a
            }
        }
        if {"--list" in $flags} {
            foreach n [names] {
                puts [format "%-16s %s" $n [question $n]]
            }
            return
        }
        if {![llength $words]} {
            fail "give a validation name (see: validate.tcl --list)"
        }
        set name [lindex $words 0]
        if {$name ni [names]} {
            fail "no validation '$name' (available: [join [names] { }])"
        }
        set requested [lrange $words 1 end]
        set bad {}
        foreach id $requested {
            if {[lindex [split $id :] 0] ni [ids]} {
                lappend bad $id
            }
        }
        if {[llength $bad]} {
            fail "no fitting test folder for: [join $bad {, }] (available: [join [ids] { }])"
        }
        # a bare ID stands for every run of its script; an ID:tag names one
        set specs {}
        if {[llength $requested]} {
            set wanted $requested
        } else {
            set wanted [ids]
        }
        foreach w $wanted {
            if {[string first : $w] >= 0} {
                lappend specs $w
            } else {
                lappend specs {*}[specs_of [list $w]]
            }
        }

        if {[catch {find_julia} julia]} {
            fail $julia
        }
        set stamp [clock format [clock seconds] -format %Y%m%d-%H%M]
        set out [file join $ROOT test validation $name results $name-$stamp.tsv]
        set cmd [list \
            $julia --startup-file=no \
            --project=[file join $ROOT test fitting_tests] \
            [file join $ROOT test validation $name validate.jl] \
            --out $out {*}$specs \
        ]

        if {"--approved" ni $flags} {
            puts "validation $name: not running. [question $name]\nIt needs the repository owner's explicit approval (minutes of one core, writes only a TSV);\nre-run with --approved once it has been approved.\nPlanned: [join $cmd { }]"
            return
        }
        puts "\$ [join $cmd { }]"
        if {"--dry-run" in $flags} {
            return
        }
        file mkdir [file dirname $out]
        if {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} {
            puts stderr "validate.tcl: $name failed"
            exit 1
        }
        puts "results: $out"
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main validate::run $argv
}
