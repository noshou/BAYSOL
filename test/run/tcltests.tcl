#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the tests of the Tcl tools (test/utils/tests/*.test, Tcl's own tcltest package). No fit and no
# benchmark runs, and Julia is not needed.
#
#     tclsh test/run/tcltests.tcl [-file PATTERN] [-match PATTERN] [-verbose LEVEL]
#
# Options are tcltest's: `-file common*` runs only the matching test files, `-match csv*` only the matching
# tests, `-verbose {body error pass}` shows more. Exit status 1 if any test failed. Needs Tcl 9 and Tcllib;
# the extraction tests also need the `sqlite3` package and are skipped without it.

package require tcltest

set here [file dirname [file normalize [info script]]]
tcltest::configure -testdir [file normalize [file join $here .. utils tests]] -verbose {error} {*}$argv
tcltest::runAllTests
exit [expr {$tcltest::numTests(Failed) > 0}]
