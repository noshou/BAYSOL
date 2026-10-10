#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on SASBDB fitting tests, without
# rerunning their fits or reports: every part by default.
#
#     tclsh dev/diagnose.tcl [--report] [--ablate] [--residuals] [--warmup]
#         [--tolerance] [options] [ID[:tag] ...]
#     tclsh dev/diagnose.tcl --list
#
# Parts (each is one Julia process, test/utils/diagnose.jl,
# which loads the fit's Seed and runs the part):
#   --report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement,
#                modes, gradient error
#   --ablate     chi-squared with one shared shell contrast / drho1=drho2 + drho3 /
#                the full model
#   --residuals  are the residuals at the MAP white (lag-1, runs z), reduced
#                chi-squared on the fitted and measured grid
#   --warmup     how short can the warm-up be and how many draws are enough: step
#                size along a long reference warm-up, runs with 50..1000 adaptation
#                iterations against it, ESS vs draws
#   --tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the
#                tolerance tight enough?)
# With none of the part flags, all five run, in
# this order. Name one or more to run only those.
#
# Options (each is passed to the parts that accept it):
#   --samples N --adapt N   NUTS iterations (report, tolerance; default: those of run_model)
#   --tols 1e-5,1e-8        c1 tolerances (tolerance)
#   --seeds 1,2,3           RNG seeds (warmup, tolerance; default 7)
#   --out DIR               write DIR/<part>.txt for each part instead of stdout
#   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
#                4,1); default one
#   --dry-run               print the commands, run nothing
#   --list                  the fitting tests and their tags
#
# `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a
# script that has several (fit2_model3); scripts with a single run take no tag. With
# no ID, every run of every fitting test (53 fits). The command line is checked before
# Julia starts. Needs Tcl 9, and `julia` on the PATH (or JULIA=/path/to/julia).

set SCRIPT [info script]
source [file join [file dirname [info script]] .. test utils common.tcl]

namespace eval diagnose {
    namespace path ::util

    # The parts, in the order they run (the slow
    # ones last), each with the options it accepts.
    variable PARTS {
        report    {--out --samples --adapt}
        ablate    {--out}
        residuals {--out}
        warmup    {--out --seeds}
        tolerance {--out --samples --adapt --tols --seeds}
    }

    # Checks the values of the options in the dict
    # $opts; stops with a message on the first bad one.
    proc check_options {who opts} {
        dict for {key value} $opts {
            switch -- $key {
                --samples - --adapt {
                    if {![string is integer -strict $value] || $value < 1} {
                        fail $who "$key needs a positive integer, got '$value'"
                    }
                }
                --seeds {
                    foreach s [split $value ,] {
                        if {![string is integer -strict $s]} {
                            fail $who "--seeds needs integers separated by commas,\
                                got '$value'"
                        }
                    }
                }
                --tols {
                    foreach t [split $value ,] {
                        if {![string is double -strict $t] || $t <= 0} {
                            fail $who "--tols needs positive numbers separated by commas,\
                                got '$value'"
                        }
                    }
                }
            }
        }
    }

    # The command that runs part $part on $specs with the
    # options $opts: diagnose.jl in the fitting-test project.
    proc command {julia part opts specs} {
        global ROOT
        set project [file join $ROOT test fitting_tests]
        set cmd [list $julia --startup-file=no --project=$project \
            [file join $ROOT test utils diagnose.jl] --$part]
        dict for {k v} $opts {
            lappend cmd $k $v
        }
        return [concat $cmd $specs]
    }

    proc run {argv} {
        global ROOT
        variable PARTS
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
        lassign [split_args diagnose.tcl [concat $valueopts --out] \
            [concat $partflags --list --dry-run] $argv] opts flags specs
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

        set chosen [lmap f $flags {
            expr {$f in $partflags ? [string range $f 2 end] : [continue]}
        }]
        if {![llength $chosen]} {
            set chosen [dict keys $PARTS]
        }
        if {[catch {find_julia} julia]} {
            fail diagnose.tcl $julia
        }
        if {$outdir ne "" && "--dry-run" ni $flags} {
            file mkdir $outdir
        }
        set failed {}
        foreach part $chosen {
            # only the options this part accepts go to it
            set popts [dict filter $opts script {k v} {
                expr {$k in [dict get $PARTS $part]}
            }]
            if {$outdir ne ""} {
                dict set popts --out [file join $outdir $part.txt]
            }
            puts "\n=== diagnose: $part"
            set cmd [command $julia $part $popts $specs]
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
