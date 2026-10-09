#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on a SASBDB fitting test, without rerunning its fit or report. One part per call;
# test/run/diagnose.tcl runs several (all, by default).
#
#     tclsh test/utils/diagnose.tcl --list
#     tclsh test/utils/diagnose.tcl --report|--ablate|--residuals|--warmup|--tolerance [options] ID[:tag] ...
#
# Parts (the work is done by diagnose.jl and seed_diagnostics.jl, in Julia):
#   --report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement, modes, gradient error
#   --ablate     chi-squared with one shared shell contrast / drho1=drho2 + drho3 / the full model
#   --residuals  are the residuals at the MAP white (lag-1, runs z), reduced chi-squared on the fitted and measured grid
#                (the MAP search only; no sampling)
#   --warmup     how short can the warm-up be and how many draws are enough: step size along a long
#                reference warm-up, runs with 50..1000 adaptation iterations against it, ESS vs draws
#   --tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the tolerance tight enough?)
#
# Options (each part accepts only some):
#   --out FILE              write here instead of stdout (all parts)
#   --samples N --adapt N   NUTS iterations (report, tolerance; default: those of run_model)
#   --tols 1e-5,1e-8        c1 tolerances (tolerance)
#   --seeds 1,2,3           RNG seeds (warmup, tolerance; default 7)
#   --dry-run               print the command, run nothing
#   --list                  the fitting tests and their tags
#
# `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a script that has several
# (fit2_model3); scripts with a single run take no tag. This front end checks the command line before Julia
# starts, so a typo fails at once instead of after a multi-second load. Needs Tcl 9, and `julia` on the PATH
# (or JULIA=/path/to/julia). Shared helpers are in common.tcl.

source [file join [file dirname [info script]] common.tcl]
set DIAG_SCRIPT [info script]

namespace eval diag {
    namespace path ::util

    # The parts, in the order test/run/diagnose.tcl runs them (the slow ones last), each with the options
    # its part accepts. The Julia side of every part is diagnose.jl.
    variable PARTS {
        report    {--out --samples --adapt}
        ablate    {--out}
        residuals {--out}
        warmup    {--out --seeds}
        tolerance {--out --samples --adapt --tols --seeds}
    }

    # Stops with a message (and exit status 2) when the command line is wrong.
    proc fail {who msg} {
        puts stderr "$who: $msg"
        exit 2
    }

    # Prints every fitting test with the tags it accepts.
    proc list_fits {} {
        foreach id [ids] {
            set tags [tags_of $id]
            if {[single_run $tags]} {
                set shown "(single run, no tag)"
            } else {
                set shown [join $tags { }]
            }
            puts [format "%-8s %s" $id $shown]
        }
    }

    # Checks the values of the options in the dict $opts; stops with a message on the first bad one.
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
                            fail $who "--seeds needs integers separated by commas, got '$value'"
                        }
                    }
                }
                --tols {
                    foreach t [split $value ,] {
                        if {![string is double -strict $t] || $t <= 0} {
                            fail $who "--tols needs positive numbers separated by commas, got '$value'"
                        }
                    }
                }
            }
        }
    }

    # Checks the ID[:tag] specs: at least one, each a fitting test (with a tag where it has several runs).
    proc check_specs {who specs} {
        if {![llength $specs]} {
            fail $who "give at least one ID\[:tag\] (see: --list)"
        }
        foreach spec $specs {
            lassign [split $spec :] id tag
            if {$id ni [ids]} {
                fail $who "no fitting test '$id' (see: --list)"
            }
            set tags [tags_of $id]
            if {$tag ni $tags} {
                if {[single_run $tags]} {
                    fail $who "$id has a single run and takes no tag, got '$tag'"
                }
                set got [expr {$tag eq "" ? "none" : $tag}]
                fail $who "$id needs a tag, one of: [join $tags {, }] (got '$got')"
            }
        }
    }

    # Splits $argv into the options of the list $allowed (each `--key value`, returned as a dict), the flags
    # of the list $flags (returned as a list) and the positional specs. Anything else starting with -- is an error.
    proc parse {who allowed flags argv} {
        set opts [dict create]
        set got {}
        set specs {}
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set a [lindex $argv $i]
            if {$a in $flags} {
                lappend got $a
            } elseif {[string match --* $a]} {
                if {$a ni $allowed} {
                    fail $who "unknown option $a (options: [join [concat $allowed $flags] {, }])"
                }
                if {$i + 1 >= [llength $argv]} {
                    fail $who "option $a needs a value"
                }
                dict set opts $a [lindex $argv [incr i]]
            } else {
                lappend specs $a
            }
        }
        return [list $opts $got $specs]
    }

    # The command that runs part $part on $specs with the options $opts, as a list.
    proc command {part opts specs} {
        global ROOT
        if {[catch {find_julia} julia]} {
            fail diagnose.tcl $julia
        }
        set cmd [list $julia --startup-file=no --project=[file join $ROOT test fitting_tests] \
            [file join $ROOT test utils diagnose.jl] --$part]
        dict for {k v} $opts {
            lappend cmd $k $v
        }
        return [concat $cmd $specs]
    }

    # Entry point of diagnose.tcl: one part per call. Prints the usage on --help, checks the command line, then
    # runs the part (or, with --dry-run, prints the command).
    proc run {script argv} {
        variable PARTS
        if {![llength $argv] || "--help" in $argv || "-h" in $argv} {
            ::usage $script
            return
        }
        set partflags {}
        set allowed {}
        foreach {part accepted} $PARTS {
            lappend partflags --$part
            foreach o $accepted {
                if {$o ni $allowed} {
                    lappend allowed $o
                }
            }
        }
        lassign [parse diagnose.tcl $allowed [concat $partflags --list --dry-run] $argv] opts flags specs
        if {"--list" in $flags} {
            list_fits
            return
        }
        set chosen [lmap f $flags {expr {$f in $partflags ? [string range $f 2 end] : [continue]}}]
        if {[llength $chosen] != 1} {
            fail diagnose.tcl "give exactly one part ([join $partflags { | }]); test/run/diagnose.tcl runs several"
        }
        set part [lindex $chosen 0]
        dict for {k v} $opts {
            if {$k ni [dict get $PARTS $part]} {
                fail diagnose.tcl "$k is not an option of --$part (it takes: [join [dict get $PARTS $part] {, }])"
            }
        }
        check_options diagnose.tcl $opts
        check_specs diagnose.tcl $specs
        set cmd [command $part $opts $specs]
        if {"--dry-run" in $flags} {
            puts $cmd
            return
        }
        if {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} {
            exit 1
        }
    }
}

# Run only when executed as a script, so test/run/diagnose.tcl can source the procs.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main diag::run $DIAG_SCRIPT $argv
}
