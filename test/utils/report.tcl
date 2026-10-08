# SPDX-License-Identifier: LGPL-2.1-or-later

# Parsing one fitting-test report (`res*.txt`) into a dict of numbers. Sourced by compare.tcl and
# results_table.tcl, not run. A value a report format lacks is the empty string, so "defined" means
# `$v ne ""`. Needs common.tcl (for `NUM`) to be sourced first.

# NOTE on patterns: Tcl gives a whole regex the greediness of its first quantifier, so one lazy `.*?`
# would make the number capture lazy too (it would return only the first digit). The patterns below
# therefore use greedy `.*` followed by `\s` before the number, which finds the same number: the last
# whitespace-delimited one on the line, and each of these lines holds one.

namespace eval report {
    # '496.68k' -> 496680; '12.4k' -> 12400; '1.2M' -> 1.2e6.
    proc count {tok} {
        set scale [switch -glob -- $tok { *k {expr {1e3}} *M {expr {1e6}} default {expr {1.0}} }]
        return [expr {[string trimright $tok kM] * $scale}]
    }

    # First capture group of $pattern in $text ("" if absent); @N@ in the pattern is a number.
    # Line mode: ^ and $ match at line ends and . stops at a newline.
    proc grab {text pattern} {
        global NUM
        if {[regexp -line -- [string map [list @N@ $NUM] $pattern] $text -> v]} { return $v }
        return ""
    }

    # Sets each key of the {key pattern ...} list in the dict variable $var to its grabbed value.
    proc grab_all {var pairs text} {
        upvar 1 $var d
        foreach {key pattern} $pairs { dict set d $key [grab $text $pattern] }
    }

    # The numbers of one report as a dict; a key is "" where a revision's format lacks it.
    proc parse {text} {
        set d [dict create]
        # sampler quality
        grab_all d {
            div     {^divergence_rate = @N@}
            steps   {^mean_n_steps\s+= @N@}
            depth   {^tree_depth\s+= @N@}
            accept  {^mean_accept\s+= @N@}
            ebfmi   {^EBFMI\s+= @N@}
        } $text
        # fit quality and fitted parameters
        grab_all d {
            chi2    {^χ²\s+= @N@}
            c1      {^excl_vol_corr\s+= @N@}
            sat     {^excl_vol_sat\s+= (\w+)}
            rho_e   {^ρₑ\s+= @N@}
            d1      {^δρ₁\s+= @N@}
            d2      {^δρ₂\s+= @N@}
            d3      {^δρ₃\s+= @N@}
        } $text
        # the Shannon-binned fit's χ² on the measured grid (reports since Shannon binning only), and the χ² every
        # comparison uses: the measured-grid one when there is one, else the (unbinned) fit's own
        dict set d chi2_raw [grab $text {^measured grid\s+lag-1.*χ²_red\s+@N@}]
        dict set d chi2_cmp [dict get $d [expr {[dict get $d chi2_raw] ne "" ? "chi2_raw" : "chi2"}]]
        # timing section
        grab_all d {
            wall      {^wall clock.*\s@N@\s+100\.0}
            fwd       {^\s+forward_cache\s+@N@}
            propka    {^\s+propka.*\s@N@\s*$}
            pdb2pqr   {^\s+pdb2pqr.*\s@N@\s*$}
            map_s     {^\s+MAP search \+ whitening .*\)\s+@N@\s*$}
            reprofile {^\s+per-draw c1 re-profile.*\)\s+@N@\s*$}
            gc        {^GC: @N@}
        } $text
        # NUTS line: "NUTS  (2k iters, 496.68k leapfrog, 0.2 ms/step)   <seconds>"
        dict set d leapfrog ""; dict set d ms_step ""; dict set d nuts ""
        if {[regexp -line -- [string map [list @N@ $::NUM] \
                {NUTS  \(([\d.]+k?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step\)\s+@N@}] \
                $text -> iters leap ms secs]} {
            dict set d leapfrog [count $leap]
            dict set d ms_step $ms
            dict set d nuts $secs
        }
        # z-score of the MAP δρ₃ from the prior (θ-space): first number of its row in that table.
        # The label is found first (lazily, across lines, so no -line), then the number after it.
        dict set d z3 ""
        if {[regexp -indices -lineanchor {=== Standard deviations from prior.*?^δρ₃} $text where]} {
            set rest [string range $text [expr {[lindex $where 1] + 1}] end]
            if {[regexp -- [string map [list @N@ $::NUM] {\A\s*@N@}] $rest -> z]} { dict set d z3 $z }
        }
        # number of distinct local optima the MAP search found
        dict set d n_modes [grab $text {MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?}]
        # wall clock without the PROPKA / pdb2pqr subprocesses, the convention for every comparison
        set wall [dict get $d wall]
        dict set d wall_ex [expr {$wall eq "" ? "" : $wall - [orzero [dict get $d propka]] - [orzero [dict get $d pdb2pqr]]}]
        return $d
    }

    # $v, or 0 when it is empty.
    proc orzero {v} { expr {$v eq "" ? 0 : $v} }
}
