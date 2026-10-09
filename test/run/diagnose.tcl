#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on SASBDB fitting tests, without rerunning their fits or reports: every part by default.
#
#     tclsh test/run/diagnose.tcl [--report] [--ablate] [--residuals] [--warmup] [--tolerance] [options] [ID[:tag] ...]
#     tclsh test/run/diagnose.tcl --list
#
# Parts (each is one call of test/utils/diagnose.tcl, which takes a single part):
#   --report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement, modes, gradient error
#   --ablate     chi-squared with one shared shell contrast / drho1=drho2 + drho3 / the full model
#   --residuals  are the residuals at the MAP white (lag-1, runs z), reduced chi-squared on the fitted and measured grid
#   --warmup     how short can the warm-up be and how many draws are enough: step size along a long
#                reference warm-up, runs with 50..1000 adaptation iterations against it, ESS vs draws
#   --tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the tolerance tight enough?)
# With none of the part flags, all five run, in this order. Name one or more to run only those.
#
# Options (each is passed to the parts that accept it):
#   --samples N --adapt N   NUTS iterations (report, tolerance; default: those of run_model)
#   --tols 1e-5,1e-8        c1 tolerances (tolerance)
#   --seeds 1,2,3           RNG seeds (warmup, tolerance; default 7)
#   --out DIR               write DIR/<part>.txt for each part instead of stdout
#   --dry-run               print the commands, run nothing
#   --list                  the fitting tests and their tags
#
# `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a script that has several
# (fit2_model3); scripts with a single run take no tag.
# With no ID, every run of every fitting test (53 fits). The command line is checked before Julia starts. Needs
# Tcl 9, and `julia` on the PATH (or JULIA=/path/to/julia).

set SCRIPT [info script]
source [file join [file dirname [info script]] .. utils diagnose.tcl]

namespace eval diagnose {
    namespace path {::util ::diag}

    proc run {argv} {
        global ROOT
        variable ::diag::PARTS
        if {![llength $argv] || "--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }
        set partflags {}
        set valueopts {}
        foreach {part accepted} $PARTS {
            lappend partflags --$part
            foreach o $accepted {
                if {$o ni $valueopts} {
                    lappend valueopts $o
                }
            }
        }
        lassign [parse diagnose.tcl $valueopts [concat $partflags --list --dry-run] $argv] opts flags specs
        if {"--list" in $flags} {
            list_fits
            return
        }
        set outdir ""
        if {[dict exists $opts --out]} {
            set outdir [dict get $opts --out]
            dict unset opts --out
        }
        check_options diagnose.tcl $opts
        if {![llength $specs]} {
            set specs [specs_of [ids]]
        }
        check_specs diagnose.tcl $specs

        set chosen {}
        foreach {part accepted} $PARTS {
            if {"--$part" in $flags} {
                lappend chosen $part
            }
        }
        if {![llength $chosen]} {
            foreach {part accepted} $PARTS {
                lappend chosen $part
            }
        }
        if {$outdir ne "" && "--dry-run" ni $flags} {
            file mkdir $outdir
        }
        set failed {}
        foreach part $chosen {
            set popts [dict create]
            dict for {k v} $opts {
                if {$k in [dict get $PARTS $part]} {
                    dict set popts $k $v
                }
            }
            if {$outdir ne ""} {
                dict set popts --out [file join $outdir $part.txt]
            }
            set cmd [list [info nameofexecutable] [file join $ROOT test utils diagnose.tcl] --$part]
            dict for {k v} $popts {
                lappend cmd $k $v
            }
            lappend cmd {*}$specs
            puts "\n=== diagnose: $part"
            if {"--dry-run" in $flags} {
                puts $cmd
            } elseif {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} {
                lappend failed $part
            }
        }
        if {[llength $failed]} {
            puts stderr "\ndiagnose.tcl: failed: [join $failed {, }]"
            exit 1
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main diagnose::run $argv
}
