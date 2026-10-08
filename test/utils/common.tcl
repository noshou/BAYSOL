# SPDX-License-Identifier: LGPL-2.1-or-later

package require Tcl 9.0-

# Repository root: the directory two levels above test/utils/ (BAYSOL_ROOT overrides it, for testing elsewhere).
set ROOT [expr {[info exists ::env(BAYSOL_ROOT)] ? $::env(BAYSOL_ROOT)
                : [file normalize [file join [file dirname [info script]] .. ..]]}]
set FIT_DIR test/fitting_tests

# A decimal number as a regex fragment, one capture group: optional sign, fraction and exponent.
# The report patterns write it as @N@.
set NUM {([-+]?\d+\.?\d*(?:[eE][-+]?\d+)?)}

# Runs `cmd args` as a script's main program: UTF-8 stdout, and a closed pipe (`... | head`) ends the
# program quietly instead of with a stack trace.
proc main {cmd args} {
    fconfigure stdout -encoding utf-8
    if {[catch {{*}$cmd {*}$args} err opts]} {
        if {[string match {*broken pipe*} $err]} { exit 0 }
        return -options $opts $err
    }
    if {[catch {flush stdout} err]} { exit 0 }
}

# Prints the header comment (the usage text) of the script $file: the lines after the shebang, the SPDX
# line and the blank one, up to the first non-comment line.
proc usage {file} {
    set ch [open $file r]
    fconfigure $ch -encoding utf-8
    gets $ch; gets $ch; gets $ch
    while {[gets $ch line] >= 0 && [string index $line 0] eq "#"} {
        puts [regsub {^# ?} $line {}]
    }
    close $ch
}

namespace eval util {
    namespace export git resolve slurp find_julia ids script_of tags_of single_run latest_release baseline_for rm_tree

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
        if {[catch {git rev-parse --verify --quiet "$rev^\{commit\}"} hash]} { return "" }
        return [string trim $hash]
    }

    # The newest release tag: the most recently created tag whose name starts with "v" and a digit
    # (v0.2.0-soukouratou, ...), or "" if there is none. This is what results are compared against by
    # default; pass explicit revisions to compare against anything else.
    proc latest_release {} {
        set tags [git for-each-ref --sort=-creatordate --format=%(refname:short) refs/tags]
        foreach t [split [string trim $tags] "\n"] {
            if {[regexp {^v\d} $t]} { return $t }
        }
        return ""
    }

    # The newest benchmark baseline recorded for release $tag: the last (by name) of
    # test/baselines/$tag*.json, or "" if there is none. Baselines are captured when a release is made.
    proc baseline_for {tag} {
        global ROOT
        set files [lsort [glob -nocomplain -directory [file join $ROOT test baselines] ${tag}*.json]]
        return [expr {[llength $files] ? [lindex $files end] : ""}]
    }

    # True for the tag list of a script with a single run, which is the one empty tag {""}.
    proc single_run {tags} { expr {[llength $tags] == 1 && [lindex $tags 0] eq ""} }

    # Deletes the benchmark's throwaway directory $dir and everything in it, never following a symbolic link:
    # a link is unlinked and its target left alone (the cold state's depot is made of links into the real one).
    # Refuses any directory that is not named baysol-bench-*, so a wrong argument cannot delete anything else.
    proc rm_tree {dir} {
        if {![string match baysol-bench-* [file tail $dir]]} { error "rm_tree: refusing to delete $dir" }
        if {![file isdirectory $dir]} return
        rm_entry $dir
    }

    # The entries of directory $dir, dot-files included, without "." and "..".
    proc entries {dir} {
        set out {}
        foreach path [glob -nocomplain -directory $dir * .*] {
            if {[file tail $path] ni {. ..}} { lappend out $path }
        }
        return $out
    }

    # One entry of rm_tree: a link or file is deleted; a real directory is emptied first.
    proc rm_entry {path} {
        if {[file type $path] eq "directory"} {
            foreach entry [entries $path] { rm_entry $entry }
        }
        file delete $path
    }

    # The Julia executable: $JULIA if set, else `julia` from the PATH. An error if it cannot be found.
    proc find_julia {} {
        set julia [expr {[info exists ::env(JULIA)] ? $::env(JULIA) : "julia"}]
        if {[auto_execok $julia] eq ""} { error "julia not found (set JULIA to its path)" }
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

    # --- the fitting tests under test/fitting_tests/ ---------------------------------------------------------

    # Scripts whose tags are not in a `const RUNS = [...]` table; the Julia side of these is the
    # SEED_ENTRY_OVERRIDES table in fit_seed.jl.
    variable SPECIAL_TAGS {SASDMZ9 {model1 model2 model3} SASDJ72 {model1 model2}}

    # The script of fitting test $id: <id>.jl, or the folder's only .jl file.
    proc script_of {id} {
        global ROOT FIT_DIR
        set dir [file join $ROOT $FIT_DIR $id]
        set scripts [glob -nocomplain -tails -directory $dir *.jl]
        if {"$id.jl" in $scripts} { return [file join $dir $id.jl] }
        if {[llength $scripts] == 1} { return [file join $dir [lindex $scripts 0]] }
        error "$dir: expected $id.jl or a single script, found $scripts"
    }

    # The tags a fitting test accepts: the `tag = "..."` entries of its RUNS table, a fixed list for the
    # special scripts, or {""} for a script with a single run.
    proc tags_of {id} {
        variable SPECIAL_TAGS
        if {[dict exists $SPECIAL_TAGS $id]} { return [dict get $SPECIAL_TAGS $id] }
        set src [slurp [script_of $id]]
        if {![regexp {const RUNS = \[(.*?)\n\]} $src -> table]} { return [list ""] }
        set tags {}
        foreach {m tag} [regexp -all -inline {tag = "([^"]+)"} $table] { lappend tags $tag }
        return $tags
    }

    # The ids of all fitting tests, sorted.
    proc ids {} {
        global ROOT FIT_DIR
        set out {}
        foreach d [lsort [glob -nocomplain -tails -directory [file join $ROOT $FIT_DIR] SASD*]] { lappend out $d }
        return $out
    }
}
