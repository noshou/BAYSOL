# SPDX-License-Identifier: LGPL-2.1-or-later

# Helpers shared by the *.test files (sourced by them, not a test file). The tests of the Tcl tools run no
# fit and no benchmark and need no Julia: they exercise the procs directly and the command lines of the
# tools that fail before Julia would start.

package require tcltest
namespace import ::tcltest::*

set TESTS_DIR [file dirname [file normalize [info script]]]
set UTILS_DIR [file dirname $TESTS_DIR]
set REPO_DIR  [file dirname [file dirname $UTILS_DIR]]
set DATA_DIR  [file join $TESTS_DIR data]

# Runs `tclsh script args...` and returns {exit-status combined-stdout-and-stderr}.
proc run_tool {script args} {
    set rc [catch {exec [info nameofexecutable] $script {*}$args 2>@1} out opts]
    set status 0
    if {$rc} {
        set code [dict get $opts -errorcode]
        set status [expr {[lindex $code 0] eq "CHILDSTATUS" ? [lindex $code 2] : 1}]
    }
    return [list $status $out]
}

# A fresh scratch directory, removed with `file delete -force` at the end of the test file by the caller.
proc scratch_dir {} { file tempdir tcltests- }

# The bytes of a file (for comparing binary files such as a SQLite database).
proc read_binary {path} {
    set ch [open $path rb]
    set data [read $ch]
    close $ch
    return $data
}

# Writes $text to $path.
proc write_file {path text} {
    file mkdir [file dirname $path]
    set ch [open $path w]
    fconfigure $ch -encoding utf-8
    puts -nonewline $ch $text
    close $ch
}

# Constraint for the tests that read old reports through git: skipped in a shallow clone or a copy without history.
tcltest::testConstraint gitHistory [expr {![catch {
    foreach rev {23151ec dc36a4b 2068a68} { exec git -C $REPO_DIR cat-file -e $rev^\{commit\} }
}]}]
