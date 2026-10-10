# SPDX-License-Identifier: LGPL-2.1-or-later

# Parsing one fitting-test report (`res*.txt`) into a dict of numbers. Sourced by
# compare.tcl and results_table.tcl, not run. A value a report format lacks is the empty
# string, so "defined" means `$v ne ""`. Needs common.tcl (for `NUM`) to be sourced first.

# NOTE on patterns: Tcl gives a whole regex the greediness of its first
# quantifier, so one lazy `.*?` would make the number capture lazy too (it
# would return only the first digit). The patterns below therefore use greedy
# `.*` followed by `\s` before the number, which finds the same number: the
# last whitespace-delimited one on the line, and each of these lines holds one.

namespace eval report {
    # '496.68k' -> 496680; '12.4k' -> 12400; '1.2M' -> 1.2e6.
    proc count {tok} {
        set scale [switch -glob -- $tok {
            *k {
                expr {1e3}
            }
            *M {
                expr {1e6}
            }
            default {
                expr {1.0}
            }
        }]
        # rounded to 6 decimals, so that 8.03k is 8030.0 and not 8029.999999999999
        return [expr {double(round([string trimright $tok kM] * $scale * 1e6)) / 1e6}]
    }

    # First capture group of $pattern in $text ("" if absent); @N@ in the pattern
    # is a number. Line mode: ^ and $ match at line ends and . stops at a newline.
    proc grab {text pattern} {
        if {[regexp -line -- [expand $pattern] $text -> v]} {
            return $v
        }
        return ""
    }

    # The pattern with its tokens replaced by their regexes, @N@ and @FLP@ a number (one
    # capture group), @NUM@ the same number without a capture group (to skip a column),
    # @QTY@ a number with an optional k (x1000) or M (x1000000) suffix (one capture group).
    proc expand {pattern} {
        global NUM
        set bare {[-+]?\d+\.?\d*(?:[eE][-+]?\d+)?}
        set qty {([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?[kM]?)}
        return [string map [list @N@ $NUM @FLP@ $NUM @NUM@ $bare @QTY@ $qty] $pattern]
    }

    # Sets each key of the {key pattern ...} list in
    # the dict variable $var to its grabbed value.
    proc grab_all {var pairs text} {
        upvar 1 $var d
        foreach {key pattern} $pairs {
            dict set d $key [grab $text $pattern]
        }
    }

    # Every number of a report: {key pattern ...}. A line a report lacks gives "". The keys
    # of `parse` below (chi2, c1, d1, ...) predate this table and stay, because compare.tcl
    # and results_table.tcl use them; where the two name the same line the values are equal.
    variable ENTRIES {
        n_atoms           {^n_atoms\s+= (\d+)}
        lMax              {^lMax\s+= (\d+)}
        n_q_raw           {^n_q_raw\s+= (\d+)}
        n_q               {^n_q\s+= (\d+)}
        n_samples         {^n_samples\s+= (\d+)}
        n_adapt           {^n_adapt\s+= (\d+)}
        rng_seed          {^rng_seed\s+= (\d+)}
        dmax              {^Dₘₐₓ\s+= @FLP@ Å}
        channels          {^channels\s+= @FLP@}
        rebin_per_channel {^rebin\s+= (\d+) per channel}
        rebin_measured    {^rebin\s+= \d+ per channel: (\d+) measured}
        rebin_fitted      {^rebin\s+= \d+ per channel: \d+ measured → (\d+) fitted points}
        rebin_dropped     {^rebin\s+= \d+ per channel: \d+ measured\
            → \d+ fitted points \((\d+) non-positive dropped\)}
        iterations        {^iterations\s+= (\d+)}
        accept            {^mean_accept\s+= @FLP@}
        depth             {^tree_depth\s+= @FLP@}
        depth_max         {^tree_depth\s+=[^\n]*\(max (\d+)\)}
        steps             {^mean_n_steps\s+= @FLP@}
        ebfmi             {^EBFMI\s+= @FLP@}
        cavity_frac       {^cavity_frac\s+= @FLP@}
        sat               {^excl_vol_sat\s+= (\w+)}
        div               {^divergence_rate\s+= @FLP@}
        chains_pooled     {^chains\s+= (\d+) pooled of \d+}
        chains_total      {^chains\s+= \d+ pooled of (\d+)}
        rhat_max          {^rhat_max\s+= @FLP@}
        ess_min           {^ess_min\s+= @FLP@}
        ess_tail_min      {^ess_tail_min\s+= @FLP@}
        modes             {^modes\s+= (\d+)}

        lgdn_MAP          {^log_density\s+= @FLP@}
        rho_e_MAP         {^ρₑ\s+= @FLP@}
        dro1_MAP          {^δρ₁\s+= @FLP@}
        dro2_MAP          {^δρ₂\s+= @FLP@}
        dro3_MAP          {^δρ₃\s+= @FLP@}
        scale_MAP         {^scale\s+= @FLP@}
        bkgrnd_MAP        {^bkgrnd_corr\s+= @FLP@}
        excl_MAP          {^excl_vol_corr\s+= @FLP@}
        chi2_MAP          {^χ²\s+= @FLP@}

        quantile_lo       {^=== Quantiles \((\d+)-\d+\) ===}
        quantile_hi       {^=== Quantiles \(\d+-(\d+)\) ===}

        wall              {^wall clock.*\s@FLP@\s+100\.0}
        static_build      {^\s+static build\s+@FLP@}
        resolve_structure {^\s+resolve_structure\s+@FLP@}
        propka            {^\s+propka.*\s@FLP@\s*$}
        pdb2pqr           {^\s+pdb2pqr.*\s@FLP@\s*$}
        load_molecule     {^\s+load_molecule\s+@FLP@}
        sasa              {^\s+SASA\s+@FLP@}
        shannon           {^\s+shannon \(diameter, binning\)\s+@FLP@}
        fwd               {^\s+forward_cache\s+@FLP@}
        vacuum_excluded   {^\s+vacuum \+ excluded volume \(vols \+ B_lm\)\s+@FLP@}
        hydration         {^\s+hydration \(B_lm\)\s+@FLP@}
        gram_rm           {^\s+Gram \+ r_m\s+@FLP@}
        seed_fitting      {^\s+seed_(?:fitting|sampler) \(priors, WLS\)\s+@FLP@}
        sampling          {^\s+sampling\s+@FLP@}
        map_s             {^\s+MAP search \+ whitening .*\)\s+@FLP@\s*$}
        nuts_setup        {^\s+NUTS setup \(.*\)\s+@FLP@\s*$}
        nuts              {^\s+NUTS\s+\(.*\)\s+@FLP@\s*$}
        reprofile         {^\s+per-draw c1 re-profile.*\)\s+@FLP@\s*$}
        map_quantiles     {^\s+MAP \+ quantiles\s+@FLP@}
        report_write      {^\s+report write\s+@FLP@}
        unaccounted       {^\s+unaccounted\s+@FLP@}
        gc                {^GC: @FLP@}

        map_starts_ok     {^\s+MAP search \+ whitening \((\d+)/\d+ starts}
        map_starts_total  {^\s+MAP search \+ whitening \(\d+/(\d+) starts}
        map_modes         {^\s+MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?}

        nuts_iters        {^\s+NUTS\s+\(@QTY@ iters}
        leapfrog          {^\s+NUTS\s+\(\S+ iters, @QTY@ leapfrog}
        ms_per_step       {^\s+NUTS\s+\(\S+ iters, \S+ leapfrog, @QTY@ ms/step\)}
        draws             {^\s+per-draw c1 re-profile.*\((\d+) draws\)}
    }

    # The parameter rows: {prefix label}. Each has a MAP value,
    # the quantile and bound columns of the `=== Quantiles ===`
    # table, and (the four with a prior) the z-score columns.
    variable PARAMS {
        {lgdn   log_density}
        {rho_e  ρₑ}
        {dro1   δρ₁}
        {dro2   δρ₂}
        {dro3   δρ₃}
        {scale  scale}
        {bkgrnd bkgrnd_corr}
        {excl   excl_vol_corr}
        {chi2   χ²}
    }

    # Adds the columns of the quantile and z-score tables to the dict variable
    # $var: <prefix>_QUANT_LO, _QUANT_HI, _BOUND_LO, _BOUND_HI for every parameter
    # row, <prefix>_Z_MAP, _Z_QUANT_LO, _Z_QUANT_HI for the four with a prior.
    proc grab_tables {var text} {
        variable PARAMS
        upvar 1 $var d
        set skip {@NUM@\s+}
        set cols {QUANT_LO QUANT_HI BOUND_LO BOUND_HI}
        foreach p $PARAMS {
            lassign $p prefix label
            for {set i 0} {$i < 4} {incr i} {
                set pat "^${label}_Q\\s+[string repeat $skip $i]@FLP@"
                dict set d ${prefix}_[lindex $cols $i] [grab $text $pat]
            }
        }
        foreach p [lrange $PARAMS 1 4] {
            lassign $p prefix label
            set zcols {Z_MAP Z_QUANT_LO Z_QUANT_HI}
            for {set i 0} {$i < 3} {incr i} {
                set pat "^${label}_Z\\s+[string repeat $skip $i]@FLP@"
                dict set d ${prefix}_[lindex $zcols $i] [grab $text $pat]
            }
        }
    }

    # Number of lines of the report that match the pattern.
    proc count_lines {text pattern} {
        return [llength [regexp -all -line -inline -- [expand $pattern] $text]]
    }

    # The numbers of one report as a dict; a key is "" where a revision's format lacks it.
    proc parse {text} {
        variable ENTRIES
        set d [dict create]
        # every line of the report
        foreach {key pattern} $ENTRIES {
            set v [grab $text $pattern]
            # a quantity with a k or M suffix is stored as the
            # plain number (an integer when it is a whole one)
            if {[string first @QTY@ $pattern] >= 0 && $v ne ""} {
                set v [count $v]
                if {$v == entier($v)} {
                    set v [expr {entier($v)}]
                }
            }
            dict set d $key $v
        }
        grab_tables d $text
        # the mass shares of the posterior modes (each
        # has a `mode_<k>` line); 1 for a single mode
        set shares {}
        foreach {m share} [regexp -all -line -inline -- \
            {^mode_\d+\s+= chains [\d,]+, share ([\d.]+)} $text] {
            lappend shares $share
        }
        dict set d mode_share_max \
            [expr {[llength $shares] ? [tcl::mathfunc::max {*}$shares] : ""}]
        dict set d mode_share_min \
            [expr {[llength $shares] ? [tcl::mathfunc::min {*}$shares] : ""}]
        # chains that were not pooled (each has a `chain_dropped` line)
        dict set d chains_dropped [count_lines $text {^chain_dropped\s+=}]
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
        # the Shannon-binned fit's χ² on the measured grid (reports since
        # Shannon binning only), and the χ² every comparison uses: the
        # measured-grid one when there is one, else the (unbinned) fit's own
        dict set d chi2_raw [grab $text {^measured grid\s+lag-1.*χ²_red\s+@N@}]
        if {[dict get $d chi2_raw] ne ""} {
            dict set d chi2_cmp [dict get $d chi2_raw]
        } else {
            dict set d chi2_cmp [dict get $d chi2]
        }
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
        dict set d leapfrog ""
        dict set d ms_step ""
        dict set d nuts ""
        set nuts_pattern [string map [list @N@ $::NUM] {
            NUTS  \(([\d.]+k?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step\)\s+@N@
        }]
        if {[regexp -line -- [string trim $nuts_pattern] $text -> iters leap ms secs]} {
            dict set d leapfrog [count $leap]
            dict set d ms_step $ms
            dict set d nuts $secs
        }
        # z-score of the MAP δρ₃ from the prior (θ-space): first number
        # of its row in that table. The label is found first (lazily,
        # across lines, so no -line), then the number after it.
        dict set d z3 ""
        if {
            [regexp -indices -lineanchor {=== Standard\
            deviations from prior.*?^δρ₃} $text where]
        } {
            set rest [string range $text [expr {[lindex $where 1] + 1}] end]
            set z_pattern [string map [list @N@ $::NUM] {\A\s*@N@}]
            if {[regexp -- $z_pattern $rest -> z]} {
                dict set d z3 $z
            }
        }
        # reports since the `_Z` row labels: the z-score row is read by its own key
        if {[dict get $d z3] eq ""} {
            dict set d z3 [dict get $d dro3_Z_MAP]
        }
        # number of distinct local optima the MAP search found
        dict set d n_modes \
            [grab $text {MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?}]
        # wall clock without the PROPKA / pdb2pqr
        # subprocesses, the convention for every comparison
        set wall [dict get $d wall]
        if {$wall eq ""} {
            dict set d wall_ex ""
        } else {
            set propka [orzero [dict get $d propka]]
            set pdb2pqr [orzero [dict get $d pdb2pqr]]
            dict set d wall_ex [expr {$wall - $propka - $pdb2pqr}]
        }
        return $d
    }

    # $v, or 0 when it is empty.
    proc orzero {v} {
        if {$v eq ""} {
            return 0
        }
        return $v
    }
}
