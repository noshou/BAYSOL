#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Formats the code: Julia with JuliaFormatter.jl (settings:
# .JuliaFormatter.toml at the repository root), Tcl (.tcl and .test) with
# tclfmt (indentation and spacing; it does not wrap lines, see linelen.tcl).
#
#     tclsh dev/format.tcl (--apply|--check) [--julia|--tcl] [PATH ...]
#
#   --apply   rewrites the Julia and Tcl files under PATH (default: the whole
#             repository)
#   --check   changes nothing; lists the files that are not formatted and exits 1
#             if there are any
#   --julia, --tcl   only that language (the precommit runs the two checks as
#             separate steps)
#
# JuliaFormatter lives in its own environment, test/format (first use:
# `julia --project=test/format -e 'using Pkg; Pkg.instantiate()'`); tclfmt must
# be on the PATH. Needs Tcl 9 and `julia` on the PATH (or JULIA=/path/to/julia).

source [file join [file dirname [info script]] linelen.tcl]
set SCRIPT [info script]

namespace eval format {
    namespace path ::util

    proc run {argv} {
        global ROOT
        if {![llength $argv] || "--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }
        set mode [lindex $argv 0]
        if {$mode ni {--apply --check}} {
            fail format.tcl "unknown option $mode (one of: --apply, --check)"
        }
        set rest [lrange $argv 1 end]
        set do_julia [expr {"--tcl" ni $rest}]
        set do_tcl [expr {"--julia" ni $rest}]
        set paths [lmap a $rest {expr {$a in {--julia --tcl} ? [continue] : $a}}]
        if {![llength $paths]} {
            set paths [list $ROOT]
        }
        set failed 0
        if {$do_julia} {
            if {[catch {find_julia} julia]} {
                fail format.tcl $julia
            }
            set cmd [list $julia --startup-file=no --project=[file join $ROOT test format] \
                [file join $ROOT test utils format.jl] $mode {*}$paths]
            if {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} {
                set failed 1
            }
        }
        # Tcl: one tclfmt call over every .tcl and .test file under the paths
        set tcl {}
        foreach p $paths {
            foreach f [linelen::files $p] {
                if {[file extension $f] in {.tcl .test}} {
                    lappend tcl [file join $ROOT $f]
                }
            }
        }
        set flag [expr {$mode eq "--apply" ? "--in-place" : "--check"}]
        if {
            $do_tcl && [llength $tcl]
            && [catch {exec tclfmt $flag {*}$tcl <@stdin >@stdout 2>@stderr}]
        } {
            set failed 1
        }
        if {$failed} {
            exit 1
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main format::run $argv
}
