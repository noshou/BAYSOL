#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Profiles the static build of fitting tests: where the seed build (structure, SASA, the B_lm expansion, the Gram matrix)
# spends its time, by function.
#
#     tclsh test/run/profile.tcl ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--nuts] [--dry-run]
#
#   ID[:tag]   fitting tests to profile (SASDMJ9, SASDBS6:fit2_model3, ...); every ID must exist
#   --delay    the profiler's sampling interval (default 0.0005 s)
#   --nuts     also profile the sampling (MAP search and NUTS) of each fit, after a short run that warms the compiler
#   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto, 4,1); default one
#   --dry-run  print the command, run nothing
#
# Each is built twice in one process (the first call warms the compiler) and the second build is profiled
# (test/utils/profile_seed.jl): the stage timings of that build, and the samples by function, exclusive and inclusive,
# for frames in BAYSOL's own source. This is development tooling for performance work, not a benchmark: use it to
# find what to optimize, and `fittings.tcl --bench --approved` or the fitting-test reports to measure it. Needs Tcl 9
# and `julia` on the PATH (or JULIA=/path/to/julia); shared helpers are in test/utils/common.tcl.

source [file join [file dirname [info script]] .. utils common.tcl]
set SCRIPT [info script]

namespace eval profile {
    namespace path ::util

    proc fail {msg} {
        puts stderr "profile.tcl: $msg"
        exit 2
    }

    proc run {argv} {
        global ROOT
        if {"--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }
        set dry 0
        set delay {}
        set nuts 0
        set specs {}
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set a [lindex $argv $i]
            switch -glob -- $a {
                --dry-run {
                    set dry 1
                }
                --nuts {
                    set nuts 1
                }
                --delay {
                    if {[incr i] >= [llength $argv]} {
                        fail "--delay needs a value"
                    }
                    set delay [lindex $argv $i]
                }
                --* {
                    fail "unknown option $a"
                }
                default {
                    lappend specs $a
                }
            }
        }
        if {![llength $specs]} {
            fail "give at least one ID\[:tag\]"
        }
        foreach s $specs {
            if {[lindex [split $s :] 0] ni [ids]} {
                fail "no fitting test folder for: $s (available: [join [ids] { }])"
            }
        }
        if {[catch {find_julia} julia]} {
            fail $julia
        }
        set cmd [list \
            $julia --startup-file=no \
            --project=[file join $ROOT test fitting_tests] \
            [file join $ROOT test utils profile_seed.jl] \
        ]
        if {$delay ne ""} {
            lappend cmd --delay $delay
        }
        if {$nuts} {
            lappend cmd --nuts
        }
        lappend cmd {*}$specs
        puts "\$ [join $cmd { }]"
        if {$dry} {
            return
        }
        if {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} {
            exit 1
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main profile::run $argv
}
