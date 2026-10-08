#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Sampler diagnostics on a SASBDB fitting test, without rerunning its fit or report.
#
#     tclsh test/utils/diagnose.tcl list
#     tclsh test/utils/diagnose.tcl report|tolerance|ablate [options] ID[:tag] ...
#
# Commands (the work is done by diagnose.jl and seed_diagnostics.jl, in Julia):
#   list       the fitting tests and their tags
#   report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement, modes, gradient error
#   tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the tolerance tight enough?)
#   ablate     chi-squared with one shared shell contrast / drho1=drho2 + drho3 / the full model
#
# Options:  --out FILE            write here instead of stdout
#           --tols 1e-5,1e-8      c1 tolerances for `tolerance`
#           --seeds 1,2,3         RNG seeds for `tolerance`
#           --samples N --adapt N NUTS iterations (default 2000 / 1000)
#
# `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a script that has several
# (fit2_model3); scripts with a single run take no tag. This front end checks the command line before
# Julia starts, so a typo fails at once instead of after a multi-second load. Needs Tcl 9, and `julia`
# on the PATH (or JULIA=/path/to/julia). Shared helpers are in common.tcl.

source [file join [file dirname [info script]] common.tcl]
set SCRIPT [info script]

namespace eval diagnose {
    namespace path ::util

    variable OPTIONS {--out --tols --seeds --samples --adapt}

    # Prints every fitting test with the tags it accepts.
    proc list_fits {} {
        foreach id [ids] {
            set tags [tags_of $id]
            puts [format "%-8s %s" $id [expr {[single_run $tags] ? "(single run, no tag)" : [join $tags { }]}]]
        }
    }

    # Stops with a message (and exit status 2) when the command line is wrong.
    proc fail {msg} { puts stderr "diagnose.tcl: $msg"; exit 2 }

    # Checks the options and specs; returns nothing.
    proc validate {opts specs} {
        dict for {key value} $opts {
            switch -- $key {
                --samples - --adapt {
                    if {![string is integer -strict $value] || $value < 1} { fail "$key needs a positive integer, got '$value'" }
                }
                --seeds {
                    foreach s [split $value ,] { if {![string is integer -strict $s]} { fail "--seeds needs integers separated by commas, got '$value'" } }
                }
                --tols {
                    foreach t [split $value ,] { if {![string is double -strict $t] || $t <= 0} { fail "--tols needs positive numbers separated by commas, got '$value'" } }
                }
            }
        }
        if {![llength $specs]} { fail "give at least one ID\[:tag\] (see: diagnose.tcl list)" }
        foreach spec $specs {
            lassign [split $spec :] id tag
            if {$id ni [ids]} { fail "no fitting test '$id' (see: diagnose.tcl list)" }
            set tags [tags_of $id]
            if {$tag ni $tags} {
                if {[single_run $tags]} { fail "$id has a single run and takes no tag, got '$tag'" }
                fail "$id needs a tag, one of: [join $tags {, }] (got '[expr {$tag eq "" ? "none" : $tag}]')"
            }
        }
    }

    # Entry point: checks the arguments, then starts the Julia side with the fitting tests' environment.
    proc run {argv} {
        global ROOT
        variable OPTIONS
        if {![llength $argv] || [lindex $argv 0] in {-h --help help}} { ::usage $::SCRIPT; return }
        set cmd [lindex $argv 0]
        if {$cmd eq "list"} { list_fits; return }
        if {$cmd ni {report tolerance ablate}} { fail "unknown command '$cmd' (list | report | tolerance | ablate)" }

        set opts [dict create]
        set specs {}
        set rest [lrange $argv 1 end]
        for {set i 0} {$i < [llength $rest]} {incr i} {
            set a [lindex $rest $i]
            if {[string match --* $a]} {
                if {$a ni $OPTIONS} { fail "unknown option $a (one of: [join $OPTIONS {, }])" }
                if {$i + 1 >= [llength $rest]} { fail "option $a needs a value" }
                dict set opts $a [lindex $rest [incr i]]
            } else {
                lappend specs $a
            }
        }
        validate $opts $specs

        if {[catch {find_julia} julia]} { fail $julia }
        # options go through as `--key value` pairs, specs last
        set cmdline [list $julia --startup-file=no --project=[file join $ROOT test fitting_tests] \
            [file join $ROOT test utils diagnose.jl] $cmd]
        dict for {k v} $opts { lappend cmdline $k $v }
        lappend cmdline {*}$specs
        if {[catch {exec {*}$cmdline <@stdin >@stdout 2>@stderr} err]} { exit 1 }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main diagnose::run $argv
}
