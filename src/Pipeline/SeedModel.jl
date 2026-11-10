# SPDX-License-Identifier: LGPL-3.0-or-later

# seed_model: structure + data + buffer -> Inference.Seed (the static build of a run).

"""
The part of a measured curve that [`seed_model`](@ref) fits: the points with
`q_min ≤ q ≤ q_max` (`nothing` is no limit) that lie in none of the ranges `exclude_q`
(both ends of each included), in their order, with the errors multiplied by `sigma_scale`.
With nothing to do the vectors come back as they are (the same objects).

# Returns
- `(; q, I, σ, n_input, n_cropped, n_excluded)`: the curve, the number of points given,
    those outside `q_min`..`q_max` and those (inside it) that an excluded range took out.

# Exceptions
- `ArgumentError`: fewer than 3 points are left, which the scale and the background of the
    fit need (the message names `q_min`, `q_max` and `exclude_q`).
"""
function _select_curve(q, I, σ; q_min, q_max, sigma_scale, exclude_q)
    n = length(q)
    inside = trues(n)
    q_min === nothing || (inside .&= q .>= q_min)
    q_max === nothing || (inside .&= q .<= q_max)
    kept = copy(inside)
    for (lo, hi) in exclude_q
        kept .&= .!(lo .<= q .<= hi)
    end
    count(kept) >= 3 || throw(
        ArgumentError(
            "only $(count(kept)) of the $n measured points are left to fit by q_min = " *
            "$(repr(q_min)), q_max = $(repr(q_max)) and exclude_q = $(repr(exclude_q)): " *
            "at least 3 are needed (the scale and the background are fitted); widen " *
            "q_min/q_max or exclude less",
        ),
    )
    σs = isone(sigma_scale) ? σ : σ .* sigma_scale
    all(kept) && return (; q, I, σ = σs, n_input = n, n_cropped = 0, n_excluded = 0)
    return (; q = q[kept], I = I[kept], σ = σs[kept], n_input = n,
        n_cropped = n - count(inside), n_excluded = count(inside) - count(kept))
end

"""
Writes into `info` (the run's `StageLog.info`) the data and structure choices of a seed that
differ from the defaults, so that a run can be reproduced from its log: `q_min`, `q_max`,
`sigma_scale`, `exclude_q` (as text) with the points `n_q_input`, `n_q_cropped` and
`n_q_excluded`, `structure_model`, `structure_chains` (as text), `add_hydrogens` (0) and
`lmax_pinned` (1). A default choice writes nothing.
"""
function _record_choices!(info, sel, ck; lMax, add_hydrogens)
    ck.q_min === nothing || (info["q_min"] = ck.q_min)
    ck.q_max === nothing || (info["q_max"] = ck.q_max)
    isone(ck.sigma_scale) || (info["sigma_scale"] = ck.sigma_scale)
    if !isempty(ck.exclude_q)
        info["exclude_q"] = join(("$lo-$hi" for (lo, hi) in ck.exclude_q), "; ")
    end
    if sel.n_cropped + sel.n_excluded > 0
        info["n_q_input"] = sel.n_input
        info["n_q_cropped"] = sel.n_cropped
        info["n_q_excluded"] = sel.n_excluded
    end
    ck.model == MODEL || (info["structure_model"] = ck.model)
    isempty(ck.chains) || (info["structure_chains"] = join(ck.chains, ","))
    add_hydrogens || (info["add_hydrogens"] = 0)
    lMax === nothing || (info["lmax_pinned"] = 1)
    return nothing
end

"""
Computes a NUTS seed from given data input:

    0.  keep the part of the measured curve to fit (`q_min`, `q_max`, `exclude_q`) and
        scale its errors (`sigma_scale`)
    1.  resolve mol_src to a structure (the `model` of it, and only its `chains`)
    2.  look the residue names up (`components`) and decide the hydrogenation from
        them (`classify`); if add_hydrogens, add hydrogens with Pdb2pqr: protein only,
        PARSE with PROPKA's pKas (they drive the terminus protonation); nucleotides
        present, AMBER and no PROPKA run if there is no protein; modified
        nucleotides are hydrogenated through the standard residue of their base
    3.  compute the accessible surface (the hydration-shell beads), take
        the diameter `D` of the whole scatterer cloud (atoms and beads),
        bin the measured curve to the Shannon channels that diameter allows
        ([`Shannon.shannon_data`](@ref BAYSOL.Utils.Shannon.shannon_data))
        and pick the band limit from it
    4.  build the forward-model (gram matrix) on the binned q grid
    5.  produce a [`Inference.Seed`](@ref).

# Arguments
- `mol_src::MolecularStructure.StructureSource`: where to obtain the
    structure from ([`MolecularStructure.LocalPathSource`](@ref),
    [`MolecularStructure.PDBIDSource`](@ref), or
    [`MolecularStructure.URLSource`](@ref)).
- `energy::Real`: beam energy in eV.
- `qvals::AbstractVector`: momentum-transfer grid, Å⁻¹.
- `I_exp::AbstractVector, σ_exp::AbstractVector`: measured intensity curve
    and its per-point standard errors; must be the same length as qvals. Pass the curve
    as measured: the part to fit is chosen here (`q_min`, `q_max`, `exclude_q`), it is
    binned here, and the bins with non-positive intensity are dropped here.
- `pH::Real`: solution pH, drives the titration of
    [`Protein`](@ref BAYSOL.BulkElectronDensity.Protein),
    [`DNA`](@ref BAYSOL.BulkElectronDensity.DNA) and
    [`RNA`](@ref BAYSOL.BulkElectronDensity.RNA) solutes and Pdb2pqr's hydrogen placement
    (when `add_hydrogens`=true).
- `σ_pH::Real`: standard uncertainty on pH, propagated through solute titration.
- `solutes::Vector{Solute}`: the buffer's components, **excluding the
    measured macromolecule** (see [`Solute`](@ref)).

# Keywords
-   `rebin::Union{Nothing,Integer} = SHANNON_REBIN`: bins per Shannon channel `π/D`
    (the bin width is `π/(rebin·D)`, `D` the diameter of the scatterer cloud), at
    least this many: a precise curve gets finer bins, until the binning's
    worst-case bias is below `max_bin_bias` of its smallest error bar (the number
    used is the report's `rebin` line); `nothing` fits the unbinned curve.
-   `max_bin_bias::Real = Shannon.BIN_BIAS_MAX`: that bound, 0.3 by default; `Inf` keeps
    `rebin` as given. The data the fit used, the raw data and the choices made are in
    `seed.shannon` ([`Shannon.ShannonInfo`](@ref BAYSOL.Utils.Shannon.ShannonInfo)).
-   `lMax::Union{Nothing,Integer} = LMAX`: spherical-harmonic band
    limit for the forward model (the setting `LMAX`); `nothing`, the default, takes
    `ceil(q_max·D)` ([`Shannon.auto_lmax`](@ref BAYSOL.Utils.Shannon.auto_lmax)),
    `q_max` the largest binned q; an integer pins it.
-   `drop_nonpositive::Bool = true`: drop the (binned) points whose intensity is not
    positive ([`Shannon.shannon_data`](@ref BAYSOL.Utils.Shannon.shannon_data)).
-   `add_hydrogens::Bool = ADD_HYDROGENS`: whether to run PROPKA + Pdb2pqr at all (the
    setting `ADD_HYDROGENS`, true by default).
    false skips both and the forward model runs on the structure exactly as
    given (heavy-atom-only, unless the file already carries hydrogens). Modified
    nucleotides are then hydrogenated through their base, an approximation
    ([`Hydrogenator`](@ref BAYSOL.Hydrogenator)).
-   `blm_chunk::Unsigned = B_LM_CHUNK`: [`Scattering.compute_B_lm`](@ref)
    batch size, forwarded to [`Scattering.forward_cache`](@ref) (results
    invariant, cost/memory tradeoff only).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Float64 = PROBE_RADIUS`,
    `n_target::Union{Nothing,Int} = nothing`: hydration-shell geometry,
    forwarded to [`Scattering.forward_cache`](@ref).
-   `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`Inference.seed_sampler`](@ref).
-   `κ_δρ₁₂::Real = κ_δρ₁₂`, `κ_δρ₃::Real = κ_δρ₃`:
    concentrations of the δρ₁/δρ₂ and δρ₃ priors, forwarded to
    [`Inference.seed_sampler`](@ref).
-   `pmv_fallback_uncert::Real = PMV_FALLBACK_UNCERT`: uncertainty, cm³ mol⁻¹, of a
    non-biological solute whose row of the partial-molar-volume table states none
    (default: the harvested mean of the table's stated ones, `NONBIO_MEAN_UNCERTAINTY`).
    Not recommended to change; it is recorded in the run log. Forwarded to
    [`Inference.seed_sampler`](@ref).
-   `bounds_δρ₁₂ = BOUNDS_δρ₁₂`, `mode_δρ₁₂ = MODE_δρ₁₂`: the support `(low, high)` of the
    δρ₁/δρ₂ priors (-10, 2) and their mode (1), in units of 0.03 e⁻/Å³; the mode must lie
    strictly inside the bounds.
-   `φ_max = φ_max`: the upper bound of the cavity occupancy (1.25), which sets the support
    of the δρ₃ prior.
-   `excl_vol_corr_bounds = EXCL_VOL_CORR_BOUNDS`, `excl_vol_corr_eps = EXCL_VOL_CORR_EPS`:
    the hard bounds of the profiled excluded-volume correction c1 ((0.8, 1.3)) and the
    padding and grid step of its search (0.02, at most the width of the bounds).
-   `shell_area_per_point = SHELL_AREA_PER_POINT`, `shell_min_points = SHELL_MIN_POINTS`: Å²
    of accessible surface each shell bead stands for (4) and the least number of beads (55),
    forwarded to [`sasa`](@ref BAYSOL.Geometry.sasa) (`n_target` pins the number instead).
-   `shell_sample = SHELL_SAMPLE`, `sasa_n_occ = SASA_N_OCC`: directions sampled per atom
    (256) and the witness-pass prefix (104, at most `shell_sample`), forwarded to
    [`sasa`](@ref BAYSOL.Geometry.sasa).
-   `bead_ray_range = BEAD_RAY_RANGE`, `bead_ray_dirs = BEAD_RAY_DIRS`: range in Å (12) and
    number of directions (64) of the cavity classification of the beads, forwarded to
    [`sasa`](@ref BAYSOL.Geometry.sasa).

-   `q_min = Q_MIN`, `q_max = Q_MAX`: the q range fitted, Å⁻¹, both ends included; a point
    outside it is left out. `nothing` (the default) is no limit. `q_min` must be below
    `q_max`. The curve the range leaves is the measured curve of the run (`seed.shannon`):
    its binning, channels and band limit follow it.
-   `sigma_scale = SIGMA_SCALE`: the factor (above 0, 1 by default) the measured `σ_exp` are
    multiplied by, before the binning.
-   `exclude_q = EXCLUDE_Q`: ranges `((q_lo, q_hi), ...)` of q, Å⁻¹, whose points are left
    out (both ends included); `()` by default. Each needs `0 ≤ q_lo < q_hi`.
-   `chains = CHAINS`: the chain ids to keep, `("A", "B")`; `()` (the
    default) keeps all. The others are removed before the hydrogens
    are added ([`MolecularStructure.keep_chains`](@ref)).
-   `model::Integer = MODEL`: which model of a multi-model structure to use, counted from 1
    in file order (1 is the first model whatever its number, the default and what was
    always read; [`MolecularStructure.reslove_struct`](@ref)).

The crop, the exclusion and the scale are applied to the measured curve first, before the
structure is touched, so a range that leaves fewer than 3 points fails at once; the
number of points that remain after the binning must be at least 3 too (the scale and the
background are fitted). Waters, ions and ligands are not part of the model (the loader
keeps the polymer only), and which alternate location of an atom is used is that of
BioStructures (the one of highest occupancy): neither is a keyword.

Every setting of [`load_settings`](@ref) that the structure, shell and priors depend on is
a keyword here: [`seed_keywords`](@ref) turns the settings into them. The keywords added
after `pmv_fallback_uncert` are checked as `load_settings` checks the setting of the same
name (the lower-case keyword is the setting's name, `MAP_N_STARTS` → `map_n_starts`), and a
bad value throws the same [`InvalidSettingsError`](@ref) lines. With every keyword at its
default the seed is what it was before they existed. A run that changes one of the data or
structure keywords records it (`q_min`, `q_max`, `sigma_scale`, `exclude_q`, the number of
points before and after, `structure_model`, `structure_chains`, `add_hydrogens`,
`lmax_pinned`) in its log and workbook.

# Returns
-   `seed::Inference.Seed`, ready to pass to [`run_model`](@ref)/[`Inference.infer`](@ref).

# Exceptions
- `MolecularStructure.ComponentError`: a residue name is neither in the bundled component
    table nor in the cache and cannot be downloaded (offline).
- `DomainError`: qvals, `I_exp`, and `σ_exp` have mismatched lengths, or
    `pmv_fallback_uncert` is not finite and above 0.
- [`InvalidSettingsError`](@ref): `bounds_δρ₁₂`, `mode_δρ₁₂`, `φ_max`,
    `excl_vol_corr_bounds`, `excl_vol_corr_eps`, `shell_area_per_point`,
    `shell_min_points`, `shell_sample`, `sasa_n_occ`, `bead_ray_range` or
    `bead_ray_dirs`, `q_min`, `q_max`, `sigma_scale`, `exclude_q`, `chains` or `model` is
    outside its limits or breaks a rule between them (`mode_δρ₁₂` not strictly inside
    `bounds_δρ₁₂`, `excl_vol_corr_eps` above the width of `excl_vol_corr_bounds`,
    `sasa_n_occ` above `shell_sample`, `q_min` not below `q_max`, a range of `exclude_q`
    with `q_lo` not below `q_hi`), with the line `load_settings` gives.
- `MolecularStructure.StructureSourceError`: `model` is above the number of models of the
    structure, or `chains` names a chain it does not have (the message lists them).
- `ArgumentError`: an input is outside its limits (a non-finite or non-positive q, σ_exp,
    `energy`,
    `thickness` or κ; a negative `σ_pH` or `probe`; `rebin`, `lMax`, `n_target` or
    `blm_chunk` below 1; a temperature at or below absolute zero), or `qvals/I_exp/σ_exp`
    are empty, or
    no point has a positive intensity after binning, or fewer than 3 points are left to fit
    by `q_min`, `q_max` and `exclude_q` (before the binning) or by the binning and the
    dropping of non-positive bins (the message names those keywords).
"""
function seed_model(
    mol_src::MolecularStructure.StructureSource,
    energy::Real,
    qvals::AbstractVector,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    rebin::Union{Nothing,Integer} = SHANNON_REBIN,
    max_bin_bias::Real = Shannon.BIN_BIAS_MAX,
    lMax::Union{Nothing,Integer} = LMAX,
    drop_nonpositive::Bool = true,
    add_hydrogens::Bool = ADD_HYDROGENS,
    blm_chunk::Unsigned = B_LM_CHUNK,
    thickness::Real = SHELL_THICKNESS,
    t::Real = DEFAULT_TEMPERATURE_C,
    probe::Float64 = PROBE_RADIUS,
    n_target::Union{Nothing,Int} = nothing,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
    pmv_fallback_uncert::Real = PMV_FALLBACK_UNCERT,
    bounds_δρ₁₂ = Inference.BOUNDS_δρ₁₂,
    mode_δρ₁₂ = Inference.MODE_δρ₁₂,
    φ_max = Inference.φ_max,
    excl_vol_corr_bounds = Inference.EXCL_VOL_CORR_BOUNDS,
    excl_vol_corr_eps = Inference.EXCL_VOL_CORR_EPS,
    shell_area_per_point = Geometry.SHELL_AREA_PER_POINT,
    shell_min_points = Geometry.SHELL_MIN_POINTS,
    shell_sample = Geometry.SHELL_SAMPLE,
    sasa_n_occ = Geometry.SASA_N_OCC,
    bead_ray_range = Geometry.BEAD_RAY_RANGE,
    bead_ray_dirs = Geometry.BEAD_RAY_DIRS,
    q_min = Q_MIN,
    q_max = Q_MAX,
    sigma_scale = SIGMA_SCALE,
    exclude_q = EXCLUDE_Q,
    chains = CHAINS,
    model = MODEL,
)::Inference.Seed
    # the checks of load_settings, on the keywords that are settings (and the rules
    # between them); the values come back in the types the code below wants
    ck = _checked_keywords(
        :seed_model,
        (; bounds_δρ₁₂, mode_δρ₁₂, φ_max, excl_vol_corr_bounds, excl_vol_corr_eps,
            shell_area_per_point, shell_min_points, shell_sample, sasa_n_occ,
            bead_ray_range, bead_ray_dirs, q_min, q_max, sigma_scale, exclude_q, chains,
            model),
    )
    # the static build allocates large temporaries; collect
    # once per byte budget instead of whenever the heap grows
    return with_gc_paused() do
        # the run's clock starts here; write_log reads the wall clock off it
        log = StageLog()

        if !(length(qvals) == length(I_exp) == length(σ_exp))
            throw(
                DomainError(
                    (
                    length(qvals),
                    length(I_exp),
                    length(σ_exp),
                    "qvals, I_exp, and σ_exp must have the same length",
                )
                ),
            )
        elseif (length(qvals) == 0)
            throw(ArgumentError("qvals, I_exp, and σ_exp cannot be empty"))
        end

        # the part of the curve to fit, and the scale of its errors: before anything else
        # (a bad point that `exclude_q` leaves out is never checked)
        sel = _select_curve(
            qvals, I_exp, σ_exp; q_min = ck.q_min, q_max = ck.q_max,
            sigma_scale = ck.sigma_scale, exclude_q = ck.exclude_q,
        )
        qvals, I_exp, σ_exp = sel.q, sel.I, sel.σ

        # inputs that must be positive or inside a range (and never a zero divisor)
        _need(all(isfinite, qvals) && all(>(0), qvals), "q must be finite and positive")
        _need(all(isfinite, I_exp), "I_exp must be finite")
        _need(all(x -> isfinite(x) && x > 0, σ_exp), "σ_exp must be finite and positive")
        _need(isfinite(energy) && energy > 0, "energy must be a positive number of eV")
        _need(
            isfinite(pH) && isfinite(σ_pH) && σ_pH ≥ 0,
            "pH must be finite and σ_pH must not be negative",
        )
        _need(isfinite(t) && t > -273.15, "t must be above absolute zero (°C)")
        _need(rebin === nothing || rebin ≥ 1, "rebin must be at least 1 (or nothing)")
        _need(max_bin_bias > 0, "max_bin_bias must be positive")
        _need(lMax === nothing || lMax ≥ 1, "lMax must be at least 1 (or nothing)")
        _need(blm_chunk ≥ 1, "blm_chunk must be at least 1")
        _need(isfinite(thickness) && thickness > 0, "thickness must be positive")
        _need(isfinite(probe) && probe ≥ 0, "probe must be finite and not negative")
        _need(n_target === nothing || n_target ≥ 1, "n_target must be ≥ 1 or nothing")
        _need(κ_δρ₁₂ > 0 && κ_δρ₃ > 0, "κ_δρ₁₂ and κ_δρ₃ must be positive")

        # load pdb into cache, then add hydrogens if requested. What the residues are
        # (components) decides how: PARSE with PROPKA, except AMBER without PROPKA for a
        # nucleic acid alone.
        path = timed!(log, :static, 1, "reslove_struct") do
            p = MolecularStructure.reslove_struct(mol_src; model = ck.model)
            MolecularStructure.keep_chains(p, ck.chains)
        end

        # the residue names of the structure, looked up in the component table (loaded
        # here on first use), the cache and, for names newer than the table, the RCSB
        t_stage = tick()
        infos = MolecularStructure.component.(MolecularStructure.residue_names(path))
        n_src(s) = count(i -> i.source === s, infos)
        tock!(
            log,
            :static,
            1,
            "components",
            t_stage;
            note = "[$(length(infos)) residue names: $(n_src(:builtin)) builtin, " *
                   "$(n_src(:cache)) cache, $(n_src(:download)) download]",
        )

        # what the text of the structure needs (chains reusing an id, duplicate atoms) and
        # whether it looks like a dummy-atom or fragment model (logged, flow unchanged)
        t_stage = tick()
        issues = MolecularStructure.structure_issues(path)
        dummy = MolecularStructure.log_dummy_like(path)
        tock!(
            log, :static, 1, "structure checks", t_stage;
            note = "[$(issues.relabelled) chains relabelled, $(issues.dropped) " *
                   "duplicate atoms dropped, $(dummy.n) dummy-like findings]",
        )
        extra =
            (issues.relabelled > 0 ? "; $(issues.relabelled) chains relabelled" : "") *
            (dummy.n > 0 ? "; $(dummy.n) dummy-like residues (undefined behaviour)" : "")

        hpath = path
        if add_hydrogens
            t_stage = tick()
            choice = Hydrogenator.hydrogenation_choice(infos, path)
            tock!(
                log, :static, 1, "classify", t_stage;
                note = "[$(choice.content): $(uppercase(String(choice.ff))), " *
                       "titration $(choice.titration)" *
                       (isempty(choice.reason) ? "" : "; " * choice.reason) * extra * "]",
            )
            hit(f) = isfile(f) ? "[cache hit]" : "[cache miss]"
            ff = choice.ff

            # the protein route is PROPKA + PARSE
            suffix =
                choice.content === :protein ? "" :
                " ($(choice.content), $(choice.titration))"
            titration = Hydrogenator.NoTitration()
            if choice.titration === :propka
                pKas = timed!(
                    log, :static, 1, "propka";
                    note = hit(Hydrogenator._pka_path(path)),
                ) do
                    Hydrogenator.propka_pKas(path)
                end
                titration = Propka(pKas)
            end
            hpath = timed!(
                log, :static, 1, "pdb2pqr" * suffix;
                note = hit(Hydrogenator._hydrogens_path(path, pH, ff, titration)),
            ) do
                Hydrogenator.resolve_hydrogens(path, pH; ff, titration)
            end

            # modified bases are hydrogenated through their base: say how far that got
            if Hydrogenator.has_modified_nucleotides(infos)
                t_stage = tick()
                d = Hydrogenator.modified_hydrogen_deficit(hpath, infos)
                tock!(
                    log,
                    :static,
                    1,
                    "modified nucleotide hydrogens",
                    t_stage;
                    note = "[$(d.residues) residues: $(d.with_base) hydrogenated " *
                           "through their base, $(d.no_base) without a base; " *
                           "$(d.placed) hydrogens placed, $(d.expected) in the free " *
                           "components' formulas]",
                )
            end

            # modified amino acids likewise, through their standard parent
            if Hydrogenator.has_modified_amino(infos)
                t_stage = tick()
                a = Hydrogenator.moded_aa_hyd(hpath, infos)
                tock!(
                    log, :static, 1, "modified amino acid hydrogens", t_stage;
                    note = "[$(a.residues) residues: $(a.with_parent) hydrogenated " *
                           "through " *
                           "their parent, $(a.no_parent) without a parent; " *
                           "$(a.placed) hydrogens placed]",
                )
            end

            # pdb2pqr drops some heavy atoms (the phosphorus of a 5' end) and adds others
            t_stage = tick()
            b = Hydrogenator.hydrogenation_balance(hpath)
            tock!(
                log, :static, 1, "heavy atoms", t_stage;
                note = "[$(Hydrogenator.heavy_atom_count(path)) in, " *
                       "$(Hydrogenator.heavy_atom_count(hpath)) out" *
                       (
                           b === nothing ? "" :
                           "; $(b.restored) restored, $(b.added) added by pdb2pqr"
                       ) * "]",
            )
        end
        mol = timed!(log, :static, 1, "load_molecule") do
            MolecularStructure.load_molecule(hpath)
        end

        # the data the forward model is built for: the accessible
        # surface is needed first, since the diameter of the whole
        # scatterer cloud fixes the Shannon width and the band limit
        shell = timed!(log, :static, 1, "SASA") do
            sasa(
            mol; probe = probe, n_target = n_target,
            shell_area_per_point = ck.shell_area_per_point,
            shell_min_points = ck.shell_min_points, shell_sample = ck.shell_sample,
            sasa_n_occ = ck.sasa_n_occ, bead_ray_range = ck.bead_ray_range,
            bead_ray_dirs = ck.bead_ray_dirs
)
        end
        info  = timed!(
        log, :static, 1, "shannon (diameter, binning)"
) do
            D = Shannon.cloud_diameter(
            hcat(MolecularStructure.coords_cartesian(mol), shell[1])
)
            Shannon.shannon_data(
            qvals,
            I_exp,
            σ_exp;
            D = D,
            rebin = rebin,
            max_bin_bias = max_bin_bias,
            lMax = lMax,
            drop_nonpositive = drop_nonpositive
)
        end
        # what the fit is of: fewer than 3 points cannot fit the scale and the background
        length(info.q) >= 3 || throw(
            ArgumentError(
                "only $(length(info.q)) point(s) are left to fit after the q range, the " *
                "exclusions, the binning and the dropping of non-positive intensities " *
                "($(length(info.q_raw)) measured points were selected by q_min, q_max " *
                "and exclude_q): at least 3 are needed; widen q_min/q_max or exclude less",
            ),
        )
        log.info["lMax"]                = info.lMax
        log.info["n_q_raw"]             = length(info.q_raw)
        log.info["rebin"]               = info.rebin
        log.info["D"]                   = info.D
        log.info["n_channels"]          = info.n_channels
        log.info["n_nonpositive"]       = info.n_nonpositive
        log.info["pmv_fallback_uncert"] = Float64(pmv_fallback_uncert)
        # the conditions of the run, which the log lists with the setup (`write_log`)
        log.info["temperature_c"] = Float64(t)
        log.info["ph"]            = Float64(pH)
        log.info["sigma_ph"]      = Float64(σ_pH)
        log.info["energy_ev"]     = Float64(energy)
        # the data and structure choices that differ from the defaults (a default run's
        # log is what it always was)
        _record_choices!(log.info, sel, ck; lMax, add_hydrogens)

        # calculate forward model
        fw = timed!(log, :static, 1, "forward_cache") do
            Scattering.forward_cache(
                mol,
                info.q,
                info.lMax,
                energy;
                chunk = blm_chunk,
                thickness = thickness,
                probe = probe,
                n_target = n_target,
                shell = shell,
                stage_log = log,
            )
        end

        return timed!(log, :static, 1, "seed_sampler (priors, WLS)") do
            Inference.seed_sampler(
                fw,
                info.I,
                info.σ,
                pH,
                σ_pH,
                solutes;
                t = t,
                κ_δρ₁₂ = κ_δρ₁₂,
                κ_δρ₃ = κ_δρ₃,
                pmv_fallback_uncert = pmv_fallback_uncert,
                bounds_δρ₁₂ = ck.bounds_δρ₁₂,
                mode_δρ₁₂ = ck.mode_δρ₁₂,
                φ_max = ck.φ_max,
                excl_vol_corr_bounds = ck.excl_vol_corr_bounds,
                excl_vol_corr_eps = ck.excl_vol_corr_eps,
                timing = log,
                shannon = info,
            )
        end
    end   # with_gc_paused
end
