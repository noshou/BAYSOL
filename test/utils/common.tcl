# SPDX-License-Identifier: LGPL-2.1-or-later

package require Tcl 9.0-

# Repository root: the directory two levels above test/utils/
# (BAYSOL_ROOT overrides it, for testing elsewhere).
if {[info exists ::env(BAYSOL_ROOT)]} {
    set ROOT $::env(BAYSOL_ROOT)
} else {
    set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
}
set FIT_DIR test/fitting_tests

# A decimal number as a regex fragment, one capture group: optional
# sign, fraction and exponent. The report patterns write it as @N@.
set NUM {([-+]?\d+\.?\d*(?:[eE][-+]?\d+)?)}

# Takes `--threads N` (N as `julia -t` takes it: `4`, `auto`, `4,1` for
# four workers and one interactive thread) out of an argument list and sets
# JULIA_NUM_THREADS from it, which every Julia process started afterwards
# inherits. Returns the list without the option. An error if N is missing.
proc take_threads {argv} {
    set i [lsearch -exact $argv --threads]
    if {$i < 0} {
        return $argv
    }
    if {$i + 1 >= [llength $argv]} {
        error "--threads needs a value (e.g. 4, auto, 4,1)"
    }
    set ::env(JULIA_NUM_THREADS) [lindex $argv $i+1]
    return [lreplace $argv $i $i+1]
}

# Runs `cmd args` as a script's main program: UTF-8 stdout, and a closed pipe
# (`... | head`) ends the program quietly instead of with a stack trace. A
# `--threads N` among the arguments (the entry points pass their whole
# argument list as the one argument) is taken out first, see `take_threads`.
proc main {cmd args} {
    fconfigure stdout -encoding utf-8
    if {[llength $args] == 1} {
        set args [list [take_threads [lindex $args 0]]]
    }
    if {[catch {{*}$cmd {*}$args} err opts]} {
        if {[string match {*broken pipe*} $err]} {
            exit 0
        }
        return -options $opts $err
    }
    if {[catch {flush stdout} err]} {
        exit 0
    }
}

# Prints the header comment (the usage text) of the script $file: the lines after
# the shebang, the SPDX line and the blank one, up to the first non-comment line.
proc usage {file} {
    set ch [open $file r]
    fconfigure $ch -encoding utf-8
    gets $ch
    gets $ch
    gets $ch
    while {[gets $ch line] >= 0 && [string index $line 0] eq "#"} {
        puts [regsub {^# ?} $line {}]
    }
    close $ch
}

namespace eval util {
    namespace export \
        git resolve slurp find_julia ids script_of tags_of specs_of \
        single_run latest_release baseline_for rm_tree fail sh \
        split_args check_specs check_folders list_fits

    # Stops the program with "who: msg" on stderr and exit status 2 (a wrong command line).
    proc fail {who msg} {
        puts stderr "$who: $msg"
        exit 2
    }

    # Prints a command and, unless $dry, runs it with our terminal. True when it succeeded.
    proc sh {dry args} {
        puts "\$ [join $args { }]"
        if {$dry} {
            return 1
        }
        set failed [catch {
            exec {*}$args <@stdin >@stdout 2>@stderr
        }]
        return [expr {!$failed}]
    }

    # Output of `git -C $ROOT ARGS`, decoded as UTF-8 (tag and path names can be non-ASCII).
    # A failing git raises an error.
    proc git {args} {
        global ROOT
        set ch [open [concat [list | git -C $ROOT] $args] r]
        fconfigure $ch -encoding utf-8
        set out [read $ch]
        close $ch
        return $out
    }

    # The commit hash of $rev, or "" if git does not know it.
    proc resolve {rev} {
        if {[catch {git rev-parse --verify --quiet "$rev^\{commit\}"} hash]} {
            return ""
        }
        return [string trim $hash]
    }

    # The newest release tag: the most recently created tag whose name starts with "v" and a
    # digit (v0.2.0-soukouratou, ...), or "" if there is none. This is what results are
    # compared against by default; pass explicit revisions to compare against anything else.
    proc latest_release {} {
        set tags [git for-each-ref --sort=-creatordate --format=%(refname:short) refs/tags]
        foreach t [split [string trim $tags] "\n"] {
            if {[regexp {^v\d} $t]} {
                return $t
            }
        }
        return ""
    }

    # The newest benchmark baseline recorded for release $tag: the
    # last (by name) of test/baselines/$tag*.json, or "" if there
    # is none. Baselines are captured when a release is made.
    proc baseline_for {tag} {
        global ROOT
        set dir [file join $ROOT test baselines]
        set files [lsort [glob -nocomplain -directory $dir ${tag}*.json]]
        if {[llength $files]} {
            return [lindex $files end]
        }
        return ""
    }

    # True for the tag list of a script with a single run, which is the one empty tag {""}.
    proc single_run {tags} {
        expr {[llength $tags] == 1 && [lindex $tags 0] eq ""}
    }

    # Deletes the benchmark's throwaway directory $dir and everything in it, never
    # following a symbolic link: a link is unlinked and its target left alone (the cold
    # state's depot is made of links into the real one). Refuses any directory that is
    # not named baysol-bench-*, so a wrong argument cannot delete anything else.
    proc rm_tree {dir} {
        if {![string match baysol-bench-* [file tail $dir]]} {
            error "rm_tree: refusing to delete $dir"
        }
        if {![file isdirectory $dir]} {
            return
        }
        rm_entry $dir
    }

    # The entries of directory $dir, dot-files included, without "." and "..".
    proc entries {dir} {
        set out {}
        foreach path [glob -nocomplain -directory $dir * .*] {
            if {[file tail $path] ni {. ..}} {
                lappend out $path
            }
        }
        return $out
    }

    # One entry of rm_tree: a link or file is deleted; a real directory is emptied first.
    proc rm_entry {path} {
        if {[file type $path] eq "directory"} {
            foreach entry [entries $path] {
                rm_entry $entry
            }
        }
        file delete $path
    }

    # The Julia executable: $JULIA if set, else `julia`
    # from the PATH. An error if it cannot be found.
    proc find_julia {} {
        if {[info exists ::env(JULIA)]} {
            set julia $::env(JULIA)
        } else {
            set julia julia
        }
        if {[auto_execok $julia] eq ""} {
            error "julia not found (set JULIA to its path)"
        }
        return $julia
    }

    # Text of a file, read as UTF-8.
    proc slurp {path} {
        set ch [open $path r]
        fconfigure $ch -encoding utf-8
        set text [read $ch]
        close $ch
        return $text
    }

    # --- the fitting tests under test/fitting_tests/
    # ---------------------------------------------------------

    # Scripts whose tags are not in a `const RUNS = [...]` table; the Julia
    # side of these is the SEED_ENTRY_OVERRIDES table in fit_seed.jl.
    variable SPECIAL_TAGS {SASDMZ9 {model1 model2 model3} SASDJ72 {model1 model2}}

    # The script of fitting test $id: <id>.jl, or the folder's only .jl file.
    proc script_of {id} {
        global ROOT FIT_DIR
        set dir [file join $ROOT $FIT_DIR $id]
        set scripts [glob -nocomplain -tails -directory $dir *.jl]
        if {"$id.jl" in $scripts} {
            return [file join $dir $id.jl]
        }
        if {[llength $scripts] == 1} {
            return [file join $dir [lindex $scripts 0]]
        }
        error "$dir: expected $id.jl or a single script, found $scripts"
    }

    # The tags a fitting test accepts: the `tag = "..."` entries of its RUNS table,
    # a fixed list for the special scripts, or {""} for a script with a single run.
    proc tags_of {id} {
        variable SPECIAL_TAGS
        if {[dict exists $SPECIAL_TAGS $id]} {
            return [dict get $SPECIAL_TAGS $id]
        }
        set src [slurp [script_of $id]]
        if {![regexp {const RUNS = \[(.*?)\n\]} $src -> table]} {
            return [list ""]
        }
        set tags {}
        foreach {m tag} [regexp -all -inline {tag = "([^"]+)"} $table] {
            lappend tags $tag
        }
        return $tags
    }

    # The `ID[:tag]` specs of the fitting tests $selected:
    # one per tag, or the bare ID for a single-run script.
    proc specs_of {selected} {
        set out {}
        foreach id $selected {
            foreach tag [tags_of $id] {
                if {$tag eq ""} {
                    lappend out $id
                } else {
                    lappend out "$id:$tag"
                }
            }
        }
        return $out
    }

    # The ids of all fitting tests, sorted.
    proc ids {} {
        global ROOT FIT_DIR
        set out {}
        set dir [file join $ROOT $FIT_DIR]
        foreach d [lsort [glob -nocomplain -tails -directory $dir SASD*]] {
            lappend out $d
        }
        return $out
    }

    # --- command lines of the front ends in dev/
    # ------------------------------------------------------

    # Splits $argv into the options of the list $allowed (each `--key value`,
    # returned as a dict), the flags of the list $flags (returned as a list) and
    # the positional specs: {opts got specs}. Anything else starting with -- is
    # an error that names the accepted ones after $word (default "options").
    proc split_args {who allowed flags argv {word options}} {
        set opts [dict create]
        set got {}
        set specs {}
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set a [lindex $argv $i]
            if {$a in $flags} {
                lappend got $a
            } elseif {[string match --* $a]} {
                if {$a ni $allowed} {
                    fail $who \
                        "unknown option $a ($word: [join [concat $allowed $flags] {, }])"
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

    # Checks the ID[:tag] specs: at least one, each a
    # fitting test (with a tag where it has several runs).
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

    # Stops unless every one of $specs names a fitting-test folder; only
    # the ID before a `:` counts when $tagged is true (the default), the
    # whole word otherwise. The message lists the folders that exist.
    proc check_folders {who specs {tagged 1}} {
        set bad {}
        foreach s $specs {
            set id [expr {$tagged ? [lindex [split $s :] 0] : $s}]
            if {$id ni [ids]} {
                lappend bad $s
            }
        }
        if {[llength $bad]} {
            fail $who "no fitting test folder for: [join \
    $bad {, }] (available: [join [ids] { }])"
        }
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
}
