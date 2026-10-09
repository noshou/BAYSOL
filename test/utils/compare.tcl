#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Compare fitting-test results between git revisions and the working tree.
#
#     tclsh test/utils/compare.tcl [REV ...] [--no-tree] [--csv out.csv]
#     tclsh test/utils/compare.tcl --bench old.json new.json
#
# Each REV is any git revision (tag, branch, commit hash, `HEAD~3`, ...). With none given the
# comparison is with the LATEST RELEASE (the newest tag whose name starts with `v` and a digit,
# found with `git for-each-ref`): a result is always judged against the version users have, not
# against an arbitrary older one. Name any revisions to compare with those instead. The columns
# appear in the order given, followed by the working tree, which is the one being judged: every
# speedup and every χ² comparison is "last column against each of the others". `--no-tree` drops
# the working tree, so the last REV is judged instead.
#
# Reads every `test/fitting_tests/*/res*.txt` at each REV via `git show` (no checkout, nothing
# rerun) and prints timing totals, fit-quality and parameter distributions, and the fits that do the
# most NUTS work. Per-fit numbers go to `--csv` if given. `--bench` instead compares the JSON results
# of `bench.tcl` (cold/steady benchmarks): the last file is the one judged, and with a single file it
# is compared with the newest baseline of the latest release in test/baselines/ (README there).
#
# Examples:
#     compare.tcl v0.1.0-sɩngre v0.2.0-soukouratou HEAD     # three tags/commits against the tree
#     compare.tcl HEAD~2 HEAD --no-tree                      # two commits only
#     compare.tcl                                            # the working tree against the latest release
#     compare.tcl --bench baseline.json new.json             # cold/steady benchmark results
#     compare.tcl --bench new.json                           # ... against the latest release's baseline
#
# Conventions (CLAUDE.md): speedups are cumulative against the reference and not additive; the
# wall clock excludes PROPKA/pdb2pqr; fit comparisons are judged on distributions, not 1:1.
# Needs Tcl 9 and Tcllib (the `json` package); shared helpers are in common.tcl.

source [file join [file dirname [info script]] common.tcl]
source [file join [file dirname [info script]] report.tcl]
set SCRIPT [info script]
package require json

namespace eval compare {
    namespace path {::util ::report}


    # Parsed reports of every res*.txt under the fitting tests at $rev: dict of relative path -> report.
    proc git_reports {rev} {
        global FIT_DIR
        set res [dict create]
        foreach p [split [git ls-tree -r --name-only $rev $FIT_DIR] "\n"] {
            if {[regexp "^${FIT_DIR}/\[^/\]+/res\[^/\]*\\.txt\$" $p]} {
                dict set res $p [parse [git show "$rev:$p"]]
            }
        }
        return $res
    }

    # The same for the files in the working tree.
    proc tree_reports {} {
        global ROOT FIT_DIR
        set res [dict create]
        foreach f [lsort [glob -nocomplain -directory $ROOT $FIT_DIR/*/res*.txt]] {
            set relative [string range $f [expr {[string length $ROOT] + 1}] end]
            dict set res $relative [parse [slurp $f]]
        }
        return $res
    }

    # --- small numeric and formatting helpers -----------------------------------------------------------

    # The non-empty values of $key over a dict of reports.
    proc column {reports key} {
        set out {}
        dict for {path r} $reports {
            set v [dict get $r $key]
            if {$v ne ""} {
                lappend out $v
            }
        }
        return $out
    }

    # Sum of $key over the reports, or "" if no report has it (older formats lack some fields).
    proc total {reports key} {
        set vals [column $reports $key]
        if {![llength $vals]} { return "" }
        set s 0.0
        foreach v $vals {
            set s [expr {$s + $v}]
        }
        return $s
    }

    # 'steps / NUTS seconds' of one report, with '-' for whatever an older format lacks.
    proc cell {r} {
        if {$r eq ""} {
            return -
        }
        set nuts [fmt_or_dash %.1f [dict get $r nuts]]
        if {$nuts ne "-"} {
            append nuts s
        }
        return "[fmt_or_dash %.1f [dict get $r steps]] / $nuts"
    }

    proc median {xs} {
        set xs [lsort -real $xs]
        set n [llength $xs]
        if {$n % 2} {
            return [lindex $xs [expr {$n / 2}]]
        }
        set below [lindex $xs [expr {$n / 2 - 1}]]
        set above [lindex $xs [expr {$n / 2}]]
        return [expr {($below + $above) / 2.0}]
    }

    # Median of the values formatted with $fmt, or '-' when there are none.
    proc med {xs fmt} {
        if {![llength $xs]} {
            return -
        }
        return [format $fmt [median $xs]]
    }

    # Quantile $q (0..1) of the values, by linear interpolation between order statistics.
    proc pct {xs q} {
        set xs [lsort -real $xs]
        set last [expr {[llength $xs] - 1}]
        set k [expr {$last * $q}]
        set lo [expr {int($k)}]
        if {$lo + 1 < $last} {
            set hi [expr {$lo + 1}]
        } else {
            set hi $last
        }
        set a [lindex $xs $lo]
        return [expr {$a + ([lindex $xs $hi] - $a) * ($k - $lo)}]
    }

    # $x with $dec decimals and thousands separators: commas 4782.4 0 -> "4,782".
    proc commas {x dec} {
        set s [format %.${dec}f $x]
        while {[regsub {^(-?\d+)(\d{3})} $s {\1,\2} s]} {
        }
        return $s
    }

    # $v formatted with $fmt, or '-' when it is empty.
    proc fmt_or_dash {fmt v} {
        if {$v eq ""} {
            return -
        }
        return [format $fmt $v]
    }

    # "x.xxx" ratio of two numbers, or n/a when either is missing or zero.
    proc ratio {num denom} {
        if {$num eq "" || $denom eq "" || $num == 0 || $denom == 0} {
            return n/a
        }
        return [format %.2fx [expr {double($num) / $denom}]]
    }

    # Number of elements of the list satisfying the expression $test (over variable x).
    proc count_if {xs test} {
        set n 0
        foreach x $xs {
            if {[expr $test]} {
                incr n
            }
        }
        return $n
    }

    # --- the tables of the revision comparison ----------------------------------------------------------

    # Timing totals over all common fits, one column per revision plus "last vs each other" ratios.
    proc timing_table {sets names} {
        set cur [lindex $names end]
        set others [lrange $names 0 end-1]
        set rows {
            {forward_cache fwd}
            {{MAP search + whitening} map_s}
            {NUTS nuts}
            {{per-draw c1 re-profile} reprofile}
            {{wall clock excl. PROPKA/pdb2pqr} wall_ex}
            {{leapfrog steps (x1e6)} leapfrog}
        }
        set vs {}
        foreach n $others {
            lappend vs "$cur vs $n"
        }
        puts "| (all fits, summed) | [join $names { | }] | [join $vs { | }] |"
        puts "|---|[string repeat ---| [expr {[llength $names] + [llength $others]}]]"
        foreach row $rows {
            lassign $row label key
            set v {}
            foreach n $names {
                dict set v $n [total [dict get $sets $n] $key]
            }
            set cells {}
            foreach n $names {
                set x [dict get $v $n]
                if {$x eq ""} {
                    set text -
                } elseif {$key eq "leapfrog"} {
                    set text [commas [expr {$x * 1e-6}] 2]
                } else {
                    set text "[commas $x 0] s"
                }
                lappend cells $text
            }
            set ratios {}
            set denom [dict get $v $cur]
            foreach n $others {
                set x [dict get $v $n]
                lappend ratios [ratio $x $denom]
            }
            puts "| $label | [join $cells { | }] | [join $ratios { | }] |"
        }
        puts "\n(ratio > 1: the last column is faster / does less work than that revision)"
    }

    # How many common fits got better / worse / stayed within 1 % in $new against $old.
    proc quality {new old label cur} {
        set common 0
        set lower 0
        set higher 0
        dict for {k r} $new {
            if {![dict exists $old $k]} {
                continue
            }
            set a [dict get $r chi2_cmp]
            set b [dict get $old $k chi2_cmp]
            if {$a eq "" || $b eq ""} {
                continue
            }
            incr common
            if {$a < 0.99 * $b} {
                incr lower
            } elseif {$a > 1.01 * $b} {
                incr higher
            }
        }
        set unchanged [expr {$common - $lower - $higher}]
        puts "χ² of $cur vs $label ($common common fits, ±1 % counts as unchanged):\
            $lower lower, $higher higher, $unchanged unchanged"
    }

    # One row of the distribution table: fit quality and parameter distributions of a set of reports.
    proc distribution {reports name} {
        set chi2 [column $reports chi2_cmp]
        set d3 [column $reports d3]
        set steps [column $reports steps]
        set z {}
        foreach v [column $reports z3] {
            lappend z [expr {abs($v)}]
        }
        set div 0
        set sat 0
        set deep 0
        dict for {k r} $reports {
            # more than 1 % divergent transitions
            if {[orzero [dict get $r div]] > 0.01} {
                incr div
            }
            # c1 at its bound
            if {[dict get $r sat] ni {"" false 0}} {
                incr sat
            }
            # deep trees
            if {[orzero [dict get $r steps]] > 100} {
                incr deep
            }
        }
        set quartiles -
        if {[llength $chi2]} {
            set q1 [format %.2f [pct $chi2 .25]]
            set q3 [format %.2f [pct $chi2 .75]]
            set quartiles "$q1 / $q3"
        }
        puts "| $name | [dict size $reports] | [med $chi2 %.2f] | $quartiles | $div | $sat\
            | [count_if $z {$x > 3}] | [med $d3 %+.2f] | $deep | [med $steps %.1f] |"
    }

    # --- the benchmark comparison (--bench) -------------------------------------------------------------

    # Stage rows of the benchmark tables: {label prefix of the stage names summed into that row}.
    set STAGES {
        {forward_cache forward_cache}
        {{MAP search} {MAP search}}
        {NUTS {NUTS  (}}
        {{c1 re-profile} {per-draw c1 re-profile}}
        {propka propka}
        {pdb2pqr pdb2pqr}
    }

    # Seconds of $field ('stage_seconds', 'stage_compile' or 'stage_gc') summed over the stages named $prefix*.
    proc stage_total {fit field prefix} {
        set sum 0.0
        foreach name [dict get $fit stage_name] v [dict get $fit $field] {
            if {[string first $prefix $name] == 0} {
                set sum [expr {$sum + $v}]
            }
        }
        return $sum
    }

    # Seconds of compile time inside the timed stages (those at depth 1) of a fit.
    proc compile_in_stages {fit} {
        set sum 0.0
        foreach depth [dict get $fit stage_depth] c [dict get $fit stage_compile] {
            if {$depth == 1} {
                set sum [expr {$sum + $c}]
            }
        }
        return $sum
    }

    # One table row of the benchmark report. $getter is a command prefix that is given a fit dict and
    # returns a number; a run lacking the fit shows '-'.
    proc bench_row {runs names spec label getter} {
        set vals {}
        foreach n $names {
            set fits [dict get $runs $n fit]
            if {[dict exists $fits $spec]} {
                lappend vals [{*}$getter [dict get $fits $spec]]
            } else {
                lappend vals ""
            }
        }
        set cells {}
        foreach v $vals {
            lappend cells [fmt_or_dash %.2f $v]
        }
        set last [lindex $vals end]
        set ratios {}
        foreach v [lrange $vals 0 end-1] {
            lappend ratios [ratio $v $last]
        }
        puts "| $label | [join $cells { | }] | [join $ratios { | }] |"
    }

    # Getters for bench_row: each takes a fit dict.
    proc get_top {key fit} {
        dict get $fit $key
    }
    proc get_first_total {fit} {
        dict get $fit first total_s
    }
    proc get_second_total {fit} {
        dict get $fit second total_s
    }
    proc get_jit {fit} {
        expr {[dict get $fit first total_s] - [dict get $fit second total_s]}
    }
    proc get_compile {fit} {
        compile_in_stages [dict get $fit first]
    }
    proc get_stage {which field prefix fit} {
        stage_total [dict get $fit $which] $field $prefix
    }

    # Side-by-side report of benchmark JSON files from bench.tcl (the last file is the one judged).
    proc bench_main {files} {
        variable STAGES
        # read every file; a run is named after its file
        if {[llength $files] == 1} {
            set tag [latest_release]
            if {$tag eq ""} {
                set base ""
                set tag_text "none found"
            } else {
                set base [baseline_for $tag]
                set tag_text $tag
            }
            if {$base eq ""} {
                puts stderr "no benchmark baseline for the latest release ($tag_text) in test/baselines/;\
                    name the file to compare with, as: compare.tcl --bench OLD.json NEW.json (test/baselines/README.md)"
                exit 1
            }
            puts "baseline: [file tail $base] (the latest release, $tag)"
            set files [list $base {*}$files]
        }
        set runs [dict create]
        set names {}
        foreach f $files {
            set d [::json::json2dict [slurp $f]]
            set n [file rootname [file tail $f]]
            lappend names $n
            dict set runs $n $d
            set m [dict get $d meta]
            puts "$n: [dict get $m state] state, [dict get $m git_rev], [dict get $m host],\
                Julia [dict get $m julia], [dict get $m cpu]"
        }
        set cur [lindex $names end]

        # results from different machines or cold vs warm state are not comparable
        foreach {field warning} {
            host "results from different hosts are not comparable"
            state "mixing cold and warm results; compare like with like"
        } {
            set seen {}
            foreach n $names {
                lappend seen [dict get $runs $n meta $field]
            }
            if {[llength [lsort -unique $seen]] > 1} {
                puts "WARNING: $warning"
            }
        }
        set installs {}
        foreach n $names {
            lappend installs [format "%s: %.1f s" $n [dict get $runs $n install precompile_s]]
        }
        puts "\ninstall (instantiate + precompile): [join $installs {, }]"

        # one table per fit that appears in any file
        set specs {}
        foreach n $names {
            lappend specs {*}[dict keys [dict get $runs $n fit]]
        }
        foreach spec [lsort -unique $specs] {
            puts "\n== $spec"
            set vs {}
            foreach n [lrange $names 0 end-1] {
                lappend vs "$cur vs $n"
            }
            puts "| seconds | [join $names { | }] | [join $vs { | }] |"
            puts "|---|[string repeat ---| [expr {2 * [llength $names] - 1}]]"
            set row [list bench_row $runs $names $spec]

            {*}$row {process wall} {get_top process_wall_s}
            {*}$row {using BAYSOL} {get_top using_baysol_s}
            {*}$row {tooling load (not product)} {get_top tooling_load_s}

            # first fit = includes JIT compilation
            {*}$row {FIRST FIT total (seed + run)} get_first_total
            {*}$row {  first - steady (JIT and first-use cost)} get_jit
            {*}$row {  compile inside the timed stages} get_compile
            foreach s $STAGES {
                lassign $s label prefix
                {*}$row "  first: $label" [list get_stage first stage_seconds $prefix]
            }

            # steady fit = second fit in the same process, everything compiled
            {*}$row {STEADY FIT total (seed + run)} get_second_total
            foreach s [lrange $STAGES 0 3] {
                lassign $s label prefix
                {*}$row "  steady: $label" [list get_stage second stage_seconds $prefix]
                {*}$row "  steady: $label GC" [list get_stage second stage_gc $prefix]
            }
        }
        puts "\n(ratio > 1: the last file is faster; first fit includes JIT,\
            steady fit does not; compare cold with cold only)"
    }


    # Entry point.
    proc run {argv} {
        global FIT_DIR
        set revs {}
        set no_tree 0
        set bench 0
        set csv ""
        for {set i 0} {$i < [llength $argv]} {incr i} {
            set a [lindex $argv $i]
            switch -- $a {
                --no-tree {
                    set no_tree 1
                }
                --bench {
                    set bench 1
                }
                --csv {
                    set csv [lindex $argv [incr i]]
                }
                -h - --help {
                    ::usage $::SCRIPT
                    return
                }
                default {
                    if {[string match --* $a]} {
                        puts stderr "usage: compare.tcl \[REV ...\] \[--no-tree\] \[--csv FILE\] | --bench FILE.json ..."
                        exit 2
                    }
                    lappend revs $a
                }
            }
        }
        if {$bench} {
            bench_main $revs
            return
        }
        if {![llength $revs]} {
            set tag [latest_release]
            if {$tag eq ""} {
                puts stderr "no release tag (v<digit>...) in this repository; name the revisions to compare"
                exit 1
            }
            set revs [list $tag]
            puts "baseline: $tag, the latest release (name other revisions to compare with those instead)"
        }

        # --- load the result sets: one per revision, then the working tree
        set sets [dict create]
        set names {}
        foreach rev $revs {
            if {[resolve $rev] eq ""} {
                puts stderr "unknown git revision '$rev'; tags here: [join [split [string trim [git tag --list]] "\n"] {, }]"
                exit 1
            }
            # the same rev twice stays distinguishable
            if {$rev in $names} {
                set label "$rev#[llength $names]"
            } else {
                set label $rev
            }
            set reports [git_reports $rev]
            if {![dict size $reports]} {
                puts "warning: no fitting-test reports at $rev; skipped"
                continue
            }
            dict set sets $label $reports
            lappend names $label
        }
        if {!$no_tree} {
            dict set sets "working tree" [tree_reports]
            lappend names "working tree"
        }
        if {[llength $names] < 2} {
            puts stderr "need at least two result sets to compare"
            exit 1
        }
        set cur [lindex $names end]

        # Only fits that have a report in every column are aggregated, so the columns are comparable.
        set common [dict keys [dict get $sets [lindex $names 0]]]
        foreach n [lrange $names 1 end] {
            set keep {}
            foreach k $common {
                if {[dict exists $sets $n $k]} {
                    lappend keep $k
                }
            }
            set common $keep
        }
        if {![llength $common]} {
            puts stderr "no fit has a report in every column"
            exit 1
        }

        set sizes {}
        foreach n $names {
            lappend sizes "$n=[dict size [dict get $sets $n]]"
        }
        puts "Reports: [join $sizes {, }]"
        puts "Everything below except the per-fit list and the CSV is aggregated over the\
            [llength $common] fits that have a report in every column.\n"
        set agg [dict create]
        foreach n $names {
            set sub [dict create]
            foreach k $common {
                dict set sub $k [dict get $sets $n $k]
            }
            dict set agg $n $sub
        }

        # --- the report
        timing_table $agg $names
        puts "\n| | fits | median χ² | χ² Q1 / Q3 | >1 % divergent | c1 pinned\
            | MAP >3σ from δρ₃ prior | median δρ₃ | fits >100 steps/iter | median steps/iter |"
        puts "|---|---|---|---|---|---|---|---|---|---|"
        foreach n $names {
            distribution [dict get $agg $n] $n
        }
        puts ""
        foreach n [lrange $names 0 end-1] {
            quality [dict get $agg $cur] [dict get $agg $n] $n $cur
        }

        # the fits with the deepest trees in the judged column (ties keep path order), every column's numbers
        set new [dict get $sets $cur]
        puts "\nFits with the most NUTS work in $cur (columns: [join $names { | }]): steps/iter / NUTS seconds"
        set by_steps [lsort -decreasing -real -index 1 [lmap k [lsort [dict keys $new]] {
            list $k [orzero [dict get $new $k steps]]
        }]]
        foreach item [lrange $by_steps 0 7] {
            set k [lindex $item 0]
            set cells {}
            foreach n $names {
                if {[dict exists $sets $n $k]} {
                    lappend cells [cell [dict get $sets $n $k]]
                } else {
                    lappend cells [cell ""]
                }
            }
            set shown [string map [list "$FIT_DIR/" ""] $k]
            puts [format "  %-42s %s" $shown [join $cells { | }]]
        }

        # --- per-fit CSV (every column, a fixed list of keys; blank where a revision lacks a value)
        if {$csv ne ""} {
            set keys {chi2_cmp steps depth nuts wall_ex div c1 d1 d2 d3 z3 n_modes}
            set ch [open $csv w]
            fconfigure $ch -encoding utf-8
            set head {}
            foreach n $names {
                foreach k $keys {
                    lappend head "$n:[string map {chi2_cmp chi2} $k]"
                }
            }
            puts $ch "fit,[join $head ,]"
            foreach k [lsort [dict keys $new]] {
                set vals {}
                foreach n $names {
                    foreach key $keys {
                        set v ""
                        if {[dict exists $sets $n $k]} {
                            set v [dict get $sets $n $k $key]
                        }
                        if {$v eq ""} {
                            lappend vals ""
                        } else {
                            lappend vals [format %.6g $v]
                        }
                    }
                }
                set shown [string map [list "$FIT_DIR/" ""] $k]
                puts $ch "$shown,[join $vals ,]"
            }
            close $ch
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main compare::run $argv
}
