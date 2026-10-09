#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Cold / steady-state benchmark driver.
#
#     tclsh test/utils/bench.tcl --approved [--state cold|warm] [--keep] [--out FILE.json] [--samples N] [--adapt N] ID[:tag] ...
#
# `--approved` is required; without it the script prints the plan and stops. Why: timings are only meaningful
# on a quiet machine (nothing else running, no desktop indexers or browsers burning CPU), and AI agents tend
# to start a benchmark without checking that. So `--approved` is passed only after the repository owner has
# approved this particular run, which means they have confirmed the machine is quiet. It is a small
# safeguard, not a security boundary. See the Benchmarks section of README.md for the
# protocol. The measured process itself stays Julia (child.jl, next to this script): it is the code being
# timed. This script only prepares the state, starts that process once per fit and collects the JSON it
# prints; `compare.tcl --bench` reads the result.
#
# --state cold (default): measures from a wiped state. A throwaway depot is built from symlinks to the
#     *source* parts of the real one (packages, artifacts, registries, clones, conda_environments: what a
#     user has after installing) WITHOUT its compiled caches, and the repository is copied from
#     `git ls-files` (tracked plus untracked-unignored files, no `_cache/`, no result files). Package
#     precompilation is timed, then each fit runs in a fresh process. Nothing in the real depot or
#     repository is modified or deleted.
# --state warm: the real depot and repo, for comparison with a cold run (never quote it as a user-facing
#     number).
# --keep: the cold state's temporary directory is deleted when the run ends (links are unlinked, never
#     followed: your depot is not touched); with --keep it is left in place and its path printed.
#
# Results go to test/baselines/results/ (not tracked) unless --out is given. A baseline for a release is a result
# saved as test/baselines/<release tag>-<state>-<host>.json when that release is made (see test/baselines/README.md);
# `compare.tcl --bench NEW.json` compares against the newest baseline of the latest release.
#
# Needs Tcl 9 and Tcllib (`json`, `json::write`), and `julia` on the PATH (or JULIA=/path/to/julia).
# Shared helpers are in common.tcl.

source [file join [file dirname [info script]] common.tcl]
set SCRIPT [info script]
package require json
package require json::write

namespace eval bench {
    namespace path ::util

    # Directories of a Julia depot that a user has after installing (sources, not compiled caches).
    variable DEPOT_SOURCE_DIRS {packages artifacts registries clones conda_environments environments}

    # Options that take no value.
    variable FLAGS {keep}

    # `--key value` options (and the value-less FLAGS) and positional specs of the command line:
    # {options-dict specs-list}.
    proc parse_args {args} {
        variable FLAGS
        set opts [dict create]
        set specs {}
        for {set i 0} {$i < [llength $args]} {incr i} {
            set a [lindex $args $i]
            if {[string match --* $a]} {
                set key [string range $a 2 end]
                if {$key in $FLAGS} {
                    dict set opts $key 1
                    continue
                }
                if {$i + 1 >= [llength $args]} {
                    error "option $a needs a value"
                }
                dict set opts $key [lindex $args [incr i]]
            } else {
                lappend specs $a
            }
        }
        return [list $opts $specs]
    }

    # Is the repository file $f (a path relative to the root) left out of the cold state's repository copy?
    # Docs, the visual-check snapshots, the fitting tests' result files and untracked benchmark results
    # are: none of them is needed to build a Seed and fit it.
    proc excluded {f} {
        expr {
            [string match docs/* $f]
            || [string match test/visualize/xyz/* $f]
            || [string match test/baselines/results/* $f]
            || [regexp {^test/fitting_tests/.*/res[^/]*\.(txt|png)$} $f]
        }
    }

    # Copies the repository's tracked and untracked-but-not-ignored files (minus the excluded ones) to
    # $dest. Returns the number of files copied.
    proc copy_repo {dest} {
        global ROOT
        set n 0
        foreach f [split [git -c core.quotepath=false ls-files -co --exclude-standard] "\n"] {
            if {$f eq "" || [excluded $f]} {
                continue
            }
            if {![file isfile [file join $ROOT $f]]} {
                continue
            }
            file mkdir [file dirname [file join $dest $f]]
            file copy -force [file join $ROOT $f] [file join $dest $f]
            incr n
        }
        return $n
    }

    # Builds a depot at $dest from symlinks to the source parts of the real depot $real. Deliberately
    # absent: compiled/ (precompile caches), scratchspaces/, logs/.
    proc make_depot {dest real} {
        variable DEPOT_SOURCE_DIRS
        file mkdir $dest
        foreach d $DEPOT_SOURCE_DIRS {
            if {[file isdirectory [file join $real $d]]} {
                file link -symbolic [file join $dest $d] [file join $real $d]
            }
        }
    }

    # Julia's version, CPU name, hardware threads and first depot, from one short Julia call.
    proc julia_facts {julia} {
        set facts_code {
            print(join((VERSION, Sys.CPU_NAME, Sys.CPU_THREADS, first(DEPOT_PATH)), "\n"))
        }
        set out [exec $julia --startup-file=no -e $facts_code]
        lassign [split $out "\n"] version cpu cores depot
        return [dict create version $version cpu $cpu cores $cores depot $depot]
    }

    # The "meta" object of a result, as a JSON object string.
    proc meta {facts state repo} {
        set rev [string trim [git rev-parse --short HEAD]]
        if {[string trim [git status --porcelain]] ne ""} {
            append rev +dirty
        }
        if {$state eq "cold"} {
            set note "compiled caches, _cache/ and result files wiped;\
                conda env and package sources kept (provisioning is not measured)"
        } else {
            set note "real depot and repo; caches warm"
        }
        return [json::write object \
            date [json::write string [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S]] \
            host [json::write string [info hostname]] \
            julia [json::write string [dict get $facts version]] \
            cpu [json::write string [dict get $facts cpu]] \
            cores [dict get $facts cores] \
            state [json::write string $state] \
            git_rev [json::write string $rev] \
            repo [json::write string $repo] \
            note [json::write string $note]]
    }

    # The JSON object a child process printed: the last line that is a whole object (opens and closes with a curly
    # brace). The child's stdout can carry other text before it (CondaPkg's "Transaction ... All requested packages
    # already installed" when PROPKA first runs).
    proc json_line {out} {
        set found ""
        foreach line [split $out "\n"] {
            set t [string trim $line]
            if {[string index $t 0] eq "\{" && [string index $t end] eq "\}"} {
                set found $t
            }
        }
        return $found
    }

    # Runs a command and returns {wall-seconds stdout}. The command's stderr goes to ours, and the
    # environment variables in the dict $env are set for its duration only.
    proc timed {env args} {
        dict for {k v} $env {
            if {[info exists ::env($k)]} {
                set saved($k) $::env($k)
            } else {
                set saved($k) ""
            }
            set ::env($k) $v
        }
        set t0 [clock microseconds]
        set rc [catch {exec {*}$args 2>@stderr} out]
        set t1 [clock microseconds]
        dict for {k v} $env {
            if {$saved($k) eq ""} {
                unset ::env($k)
            } else {
                set ::env($k) $saved($k)
            }
        }
        if {$rc} {
            error "command failed: [lrange $args 0 3] ...\n$out"
        }
        return [list [expr {($t1 - $t0) / 1e6}] $out]
    }

    # Runs the benchmark. Without --approved it only prints the plan.
    proc run {argv} {
        global ROOT
        if {"--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }

        # Benchmarks only run with the owner's approval, because they need a quiet machine and an agent will
        # not check for one on its own: without `--approved` this prints the plan and stops.
        if {"--approved" ni $argv} {
            puts "benchmarks: not running. A benchmark needs a QUIET machine, and an unattended agent cannot tell whether it is
quiet, so each run needs the repository owner's explicit approval (they confirm nothing else is running).
Planned: [join $argv { }]
It uses one core for minutes (cold: a full precompile of every dependency first), builds a throwaway depot
and repo copy under the temp directory, and leaves your real depot and repository untouched.
Re-run with --approved once the run has been approved."
            return
        }
        set argv [lsearch -all -inline -not -exact $argv --approved]
        lassign [parse_args {*}$argv] opts specs
        if {![llength $specs]} {
            error "usage: bench.tcl --approved \[--state cold|warm\] \[--out FILE.json\]\
                \[--samples N --adapt N\] ID\[:tag\] ..."
        }
        set state cold
        if {[dict exists $opts state]} {
            set state [dict get $opts state]
        }
        if {$state ni {cold warm}} {
            error "--state must be cold or warm"
        }
        set samples 2000
        if {[dict exists $opts samples]} {
            set samples [dict get $opts samples]
        }
        set adapt 1000
        if {[dict exists $opts adapt]} {
            set adapt [dict get $opts adapt]
        }
        if {[dict exists $opts out]} {
            set out [dict get $opts out]
        } else {
            set stamp [clock format [clock seconds] -format %Y%m%d-%H%M]
            set out [file join $ROOT test baselines results $stamp-$state-[info hostname].json]
        }
        file mkdir [file dirname $out]

        set julia [find_julia]
        set facts [julia_facts $julia]
        set childenv [dict create]
        set keep [dict exists $opts keep]
        set tmp ""

        try {
        # --- install: instantiate + precompile, timed
        if {$state eq "cold"} {
            set tmp [file tempdir baysol-bench-]
            set repo [file join $tmp repo]
            set depot [file join $tmp depot]
            puts "cold state in $tmp"
            puts "  copied [copy_repo $repo] files"
            make_depot $depot [dict get $facts depot]
            set childenv [dict create JULIA_DEPOT_PATH $depot]
            set script {
                using Pkg
                Pkg.instantiate()
                t = @elapsed Pkg.precompile()
                println("PRECOMPILE_S=", t)
            }
            lassign [timed $childenv $julia --project=$repo -e $script] t_pre txt
            if {![regexp {PRECOMPILE_S=([0-9.eE+-]+)} $txt -> pre]} {
                error "no PRECOMPILE_S in the precompile output"
            }
            puts [format "  instantiate + precompile: %.1f s (precompile alone %.1f s)" $t_pre $pre]
            set install [json::write object instantiate_and_precompile_s $t_pre precompile_s $pre]
        } else {
            set repo $ROOT
            set script {
                using Pkg
                Pkg.precompile()
            }
            lassign [timed {} $julia --project=$repo -e $script] t_pre txt
            set install [json::write object instantiate_and_precompile_s $t_pre precompile_s $t_pre]
        }
        set meta [meta $facts $state $repo]

        # --- one fresh process per fit; child.jl prints its measurements as one JSON object
        set fits {}
        foreach spec $specs {
            lassign [timed $childenv \
                $julia --project=$repo [file join $repo test utils child.jl] \
                $repo $spec $samples $adapt \
            ] t_proc raw
            set raw [json_line $raw]
            if {![string match "\{*\}" $raw] || $raw eq "\{\}"} {
                error "child.jl printed something other than a non-empty JSON object for $spec:\n$raw"
            }
            # parse check, and the numbers for the progress line
            set r [json::json2dict $raw]
            # the parent measured the process wall time; add it to the child's object, then check the result parses
            set merged "[string range $raw 0 end-1],\"process_wall_s\":$t_proc\}"
            if {[catch {json::json2dict $merged} chk] || ![dict exists $chk process_wall_s]} {
                error "could not add process_wall_s to the result for $spec"
            }
            lappend fits $spec $merged
            puts [format \
                "  %-22s process %6.1f s | using BAYSOL %5.1f s | first fit %6.1f s\
                (seed %5.1f + run %5.1f) | steady fit %6.1f s" \
                $spec $t_proc \
                [dict get $r using_baysol_s] \
                [dict get $r first total_s] \
                [dict get $r first seed_s] \
                [dict get $r first run_s] \
                [dict get $r second total_s] \
            ]
        }

        set ch [open $out w]
        fconfigure $ch -encoding utf-8
        puts $ch [json::write object meta $meta install $install fit [json::write object {*}$fits]]
        close $ch
        puts "wrote $out"

        } finally {
            if {$tmp ne ""} {
                if {$keep} {
                    puts "kept the cold state in $tmp (remove it with rm -r; the links inside are not followed)"
                } else {
                    rm_tree $tmp
                    puts "removed $tmp"
                }
            }
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main bench::run $argv
}
