# SPDX-License-Identifier: LGPL-3.0-or-later

# seed_model: structure + data + buffer -> Inference.Seed (the static build of a run).

"""
Computes a NUTS seed from given data input:

    1.  resolve mol_src to a structure
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
    as measured over the q range to be fitted: it is binned here, and the bins with
    non-positive intensity are dropped here.
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
-   `lMax::Union{Nothing,Integer} = nothing`: spherical-harmonic band
    limit for the forward model; `nothing` takes `ceil(q_max·D)`
    ([`Shannon.auto_lmax`](@ref BAYSOL.Utils.Shannon.auto_lmax)),
    `q_max` the largest binned q.
-   `drop_nonpositive::Bool = true`: drop the (binned) points whose intensity is not
    positive ([`Shannon.shannon_data`](@ref BAYSOL.Utils.Shannon.shannon_data)).
-   `add_hydrogens::Bool=true`: whether to run PROPKA + Pdb2pqr at all.
    false skips both and the forward model runs on the structure exactly as
    given (heavy-atom-only, unless the file already carries hydrogens). Modified
    nucleotides are then hydrogenated through their base, an approximation
    ([`Hydrogenator`](@ref BAYSOL.Hydrogenator)).
-   `blm_chunk::Unsigned = B_LM_CHUNK`: [`Scattering.compute_B_lm`](@ref)
    batch size, forwarded to [`Scattering.forward_cache`](@ref) (results
    invariant, cost/memory tradeoff only).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Float64 = PROBE_RADIUS`,
    `n_target::Union{Nothing,Int} = SHELL_N_TARGET`: hydration-shell geometry,
    forwarded to [`Scattering.forward_cache`](@ref).
-   `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`Inference.seed_sampler`](@ref).
-   `κ_δρ₁₂::Real = κ_δρ₁₂`, `κ_δρ₃::Real = κ_δρ₃`:
    concentrations of the δρ₁/δρ₂ and δρ₃ priors, forwarded to
    [`Inference.seed_sampler`](@ref).

# Returns
-   `seed::Inference.Seed`, ready to pass to [`run_model`](@ref)/[`Inference.infer`](@ref).

# Exceptions
- `MolecularStructure.ComponentError`: a residue name is neither in the bundled component
    table nor in the cache and cannot be downloaded (offline).
- `DomainError`: qvals, `I_exp`, and `σ_exp` have mismatched lengths, or hold non-finite
    values, or `σ_exp` is not positive, or `rebin < 1`.
- `ArgumentError`: `qvals/I_exp/σ_exp` are empty, or
    no point has a positive intensity after binning.
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
    lMax::Union{Nothing,Integer} = nothing,
    drop_nonpositive::Bool = true,
    add_hydrogens::Bool = true,
    blm_chunk::Unsigned = B_LM_CHUNK,
    thickness::Real = SHELL_THICKNESS,
    t::Real = DEFAULT_TEMPERATURE_C,
    probe::Float64 = PROBE_RADIUS,
    n_target::Union{Nothing,Int} = SHELL_N_TARGET,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
)::Inference.Seed
    # the static build allocates large temporaries; collect
    # once per byte budget instead of whenever the heap grows
    return with_gc_paused() do
        # the run's clock starts here; write_timings reads the wall clock off it
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

        # load pdb into cache, then add hydrogens if requested. What the residues are
        # (components) decides how: PARSE with PROPKA, except AMBER without PROPKA for a
        # nucleic acid alone.
        path = timed!(log, :static, 1, "resolve_structure") do
            MolecularStructure.resolve_structure(mol_src)
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
                a = Hydrogenator.modified_amino_hydrogens(hpath, infos)
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
        shell                     = timed!(log, :static, 1, "SASA") do
            sasa(mol; probe = probe, n_target = n_target)
        end
        info                      = timed!(
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
        log.info["lMax"]          = info.lMax
        log.info["n_q_raw"]       = length(info.q_raw)
        log.info["rebin"]         = info.rebin
        log.info["D"]             = info.D
        log.info["n_channels"]    = info.n_channels
        log.info["n_nonpositive"] = info.n_nonpositive

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
                timing = log,
                shannon = info,
            )
        end
    end   # with_gc_paused
end
