#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the visual checks in test/visualize/ (plots of the geometry code; they need a display, except
# `sasa_hydro_report`, which prints numbers only).
#
#     tclsh test/run/vis.tcl [NAME ...] [--list] [--dry-run]
#
#   NAME       the checks to run (see --list). Every one must exist, or nothing runs.
#              With none given, every check runs, one after the other.
#   --list     show the checks and what each one does
#   --dry-run  print what would be run, run nothing
#
# Each check is one call in a fresh Julia process in test/visualize/'s own environment. Needs Tcl 9 and `julia`
# on the PATH (or JULIA=/path/to/julia); shared helpers are in test/utils/common.tcl.

source [file join [file dirname [info script]] .. utils common.tcl]
set SCRIPT [info script]

namespace eval vis {
    namespace path ::util

    # The checks, in the order they run: name, script in test/visualize/, Julia call, one-line description.
    variable CHECKS {
        plastic_2d         {plastic_vis.jl     {vis_plastic_points_2D(2000)} {plastic sequence on a spherical surface (2-D generator)}}
        plastic_3d         {plastic_vis.jl     {vis_plastic_points_3D(2000)} {plastic sequence filling a spherical volume (3-D generator)}}
        sasa_hydro         {sasa_hydro_vis.jl  {vis_sasa_hydro()}            {SASA hydration-shell dummy cloud over a packed cluster}}
        sasa_hydro_report  {sasa_hydro_vis.jl  {sasa_hydro_report()}         {the same, numbers only, no window (works headless)}}
    }

    proc fail {msg} { puts stderr "vis.tcl: $msg"; exit 2 }

    # Entry point.
    proc run {argv} {
        global ROOT
        variable CHECKS
        if {"--help" in $argv || "-h" in $argv} { ::usage $::SCRIPT; return }

        set names {}
        set list 0
        set dry 0
        foreach a $argv {
            switch -- $a {
                --list    { set list 1 }
                --dry-run { set dry 1 }
                default {
                    if {[string match --* $a]} { fail "unknown option $a (one of: --list, --dry-run)" }
                    lappend names $a
                }
            }
        }
        if {$list} {
            dict for {name spec} $CHECKS { puts [format "%-18s %s" $name [lindex $spec 2]] }
            return
        }

        set missing {}
        foreach n $names { if {![dict exists $CHECKS $n]} { lappend missing $n } }
        if {[llength $missing]} {
            fail "no visual check named: [join $missing {, }] (available: [join [dict keys $CHECKS] { }])"
        }
        if {![llength $names]} { set names [dict keys $CHECKS] }

        if {[catch {find_julia} julia]} { fail $julia }
        set failed {}
        foreach n $names {
            lassign [dict get $CHECKS $n] script call
            set code "include(\"[file join $ROOT test visualize $script]\"); $call"
            set cmd [list $julia --startup-file=no --project=[file join $ROOT test visualize] -e $code]
            puts "\n=== $n"
            puts "\$ [join $cmd { }]"
            if {$dry} continue
            if {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} { lappend failed $n }
        }
        if {[llength $failed]} { puts stderr "\nvis.tcl: failed: [join $failed {, }]"; exit 1 }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main vis::run $argv
}
