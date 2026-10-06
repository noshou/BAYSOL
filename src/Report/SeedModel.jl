# SPDX-License-Identifier: LGPL-2.1-or-later

# seed_model: structure + data + buffer -> Fitting.Seed (the static build of a run).

"""
Computes a NUTS seed from given data input:

    1.  resolve mol_src to a structure
    2.  if add_hydrogens, run PROPKA on the model (its pKas drive Pdb2pqr's
        terminus protonation) and add hydrogens (Pdb2pqr, pH-driven)
    3.  build the forward-model (gram matrix)
    4.  produce a [`Fitting.Seed`](@ref).

# Arguments
- `mol_src::MolecularStructure.StructureSource`: where to obtain the
    structure from ([`MolecularStructure.LocalPathSource`](@ref),
    [`MolecularStructure.PDBIDSource`](@ref), or
    [`MolecularStructure.URLSource`](@ref)).
- `lMax::Int64`: spherical-harmonic band limit for the forward model.
- `energy::Real`: beam energy in eV.
- `qvals::AbstractVector`: momentum-transfer grid, Å⁻¹.
- `I_exp::AbstractVector, σ_exp::AbstractVector`: measured intensity curve
    and its per-point standard errors; must be the same length as qvals.
- `pH::Real`: solution pH — drives [`Fitting.Protein`](@ref)/[`Fitting.DNA`](@ref)/[`Fitting.RNA`](@ref)
    solute titration and Pdb2pqr's hydrogen placement (when `add_hydrogens`=true).
- `σ_pH::Real`: standard uncertainty on pH, propagated through solute titration.
- `solutes::Vector{Fitting.Solute}`: the buffer's components, **excluding the
    measured macromolecule** (see [`Fitting.Solute`](@ref)).

# Keywords
-   `add_hydrogens::Bool=true`: whether to run PROPKA + Pdb2pqr at all.
    false skips both and the forward model runs on the structure exactly as
    given (heavy-atom-only, unless the file already carries hydrogens).
-   `blm_chunk::Unsigned = B_LM_CHUNK`: [`Scattering.compute_B_lm`](@ref) batch size, forwarded to
    [`Scattering.forward_cache`](@ref) (results invariant, cost/memory tradeoff only).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Float64 = PROBE_RADIUS`,
    `n_target::Union{Nothing,Int} = SHELL_N_TARGET`: hydration-shell geometry,
    forwarded to [`Scattering.forward_cache`](@ref).
-   `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`Fitting.seed_fitting`](@ref).
-   `κ_δρ₁₂::Real = DRO12_CONCENTRATION`, `κ_δρ₃::Real = DRO3_CONCENTRATION`:
    concentrations of the δρ₁/δρ₂ and δρ₃ priors, forwarded to
    [`Fitting.seed_fitting`](@ref).

# Returns
-   `seed::Fitting.Seed`, ready to pass to [`run_model`](@ref)/[`Fitting.run_fitting`](@ref).

# Exceptions
- `DomainError`: qvals, `I_exp`, and `σ_exp` have mismatched lengths.
- `ArgumentError`: `qvals/I_exp/σ_exp` are empty.
"""
function seed_model(
    mol_src::MolecularStructure.StructureSource,
    lMax::Int64,
    energy::Real,
    qvals::AbstractVector,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Fitting.Solute};
    add_hydrogens::Bool=true,
    blm_chunk::Unsigned = B_LM_CHUNK,
    thickness::Real = SHELL_THICKNESS,
    t::Real = DEFAULT_TEMPERATURE_C,
    probe::Float64 = PROBE_RADIUS,
    n_target::Union{Nothing,Int} = SHELL_N_TARGET,
    κ_δρ₁₂::Real = DRO12_CONCENTRATION,
    κ_δρ₃::Real = DRO3_CONCENTRATION,
)::Fitting.Seed
    # the run's clock starts here; write_report reads the wall clock off it
    log = Timing.StageLog()

    if !(length(qvals) == length(I_exp) == length(σ_exp))
        throw(
            DomainError(
                (
                    length(qvals), length(I_exp), length(σ_exp),
                    "qvals, I_exp, and σ_exp must have the same length"
                )
            )
        )
    elseif (length(qvals) == 0)
        throw(ArgumentError("qvals, I_exp, and σ_exp cannot be empty"))
    end

    # load pdb into cache, then add hydrogens if requested. PROPKA's pKas are
    # only consumed by resolve_hydrogens, so it is skipped entirely when
    # add_hydrogens is false.
    path = Timing.timed!(log, :static, 1, "resolve_structure") do
        MolecularStructure.resolve_structure(mol_src)
    end
    hpath = path
    if add_hydrogens
        hit(f) = isfile(f) ? "[cache hit]" : "[cache miss]"
        pKas = Timing.timed!(log, :static, 1, "propka"; note = hit(MolecularStructure._pka_path(path))) do
            MolecularStructure.propka_pKas(path)
        end
        hpath = Timing.timed!(log, :static, 1, "pdb2pqr"; note = hit(MolecularStructure._hydrogens_path(path, pH))) do
            MolecularStructure.resolve_hydrogens(path, pKas, pH)
        end
    end
    mol = Timing.timed!(log, :static, 1, "load_molecule") do
        MolecularStructure.load_molecule(hpath)
    end

    # calculate forward model
    fw = Timing.timed!(log, :static, 1, "forward_cache") do
        Scattering.forward_cache(
            mol,
            qvals,
            lMax,
            energy;
            chunk=blm_chunk,
            thickness=thickness,
            probe=probe,
            n_target=n_target,
            stage_log=log,
        )
    end

    return Timing.timed!(log, :static, 1, "seed_fitting (priors, WLS)") do
        Fitting.seed_fitting(
            fw, I_exp, σ_exp, pH, σ_pH, solutes;
            t=t, κ_δρ₁₂=κ_δρ₁₂, κ_δρ₃=κ_δρ₃, timing=log,
        )
    end
end
