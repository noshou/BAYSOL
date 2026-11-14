# SPDX-License-Identifier: LGPL-3.0-or-later

# seedModel: structure + data + buffer -> Inference.Seed (the static build of a run).

"""
The part of a measured curve that [`seedModel`](@ref) fits: the points with
`qMin ≤ q ≤ qMax` (`nothing` is no limit) that lie in none of the ranges `excludeQ`
(both ends of each included), in their order, with the errors multiplied by `sigmaScale`.
With nothing to do the vectors come back as they are (the same objects).

# Returns
- `(; q, I, σ, nInput, nCropped, nExcluded)`: the curve, the number of points given,
    those outside `qMin`..`qMax` and those (inside it) that an excluded range took out.

# Exceptions
- `ArgumentError`: fewer than 3 points are left, which the scale and the background of the
    fit need (the message names `qMin`, `qMax` and `excludeQ`).
"""
function _selectCurve(q, I, σ; qMin, qMax, sigmaScale, excludeQ)
    n = length(q)
    inside = trues(n)
    qMin === nothing || (inside .&= q .>= qMin)
    qMax === nothing || (inside .&= q .<= qMax)
    kept = copy(inside)
    for (lo, hi) in excludeQ
        kept .&= .!(lo .<= q .<= hi)
    end
    count(kept) >= 3 || throw(
        ArgumentError(
            "only $(count(kept)) of the $n measured points are left to fit by qMin = " *
            "$(repr(qMin)), qMax = $(repr(qMax)) and excludeQ = $(repr(excludeQ)): " *
            "at least 3 are needed (the scale and the background are fitted); widen " *
            "qMin/qMax or exclude less",
        ),
    )
    σs = isone(sigmaScale) ? σ : σ .* sigmaScale
    all(kept) && return (; q, I, σ = σs, nInput = n, nCropped = 0, nExcluded = 0)
    return (; q = q[kept], I = I[kept], σ = σs[kept], nInput = n,
        nCropped = n - count(inside), nExcluded = count(inside) - count(kept))
end

"""
Writes into `info` (the run's `StageLog.info`) the data and structure choices of a seed that
differ from the defaults, so that a run can be reproduced from its log: `qMin`, `qMax`,
`sigmaScale`, `excludeQ` (as text) with the points `nQInput`, `nQCropped` and
`nQExcluded`, `structureModel`, `structureChains` (as text), `addHydrogens` (0) and
`lmaxPinned` (1). A default choice writes nothing.
"""
function _recordChoices!(info, sel, ck; lMax, addHydrogens)
    ck.qMin === nothing || (info["qMin"] = ck.qMin)
    ck.qMax === nothing || (info["qMax"] = ck.qMax)
    isone(ck.sigmaScale) || (info["sigmaScale"] = ck.sigmaScale)
    if !isempty(ck.excludeQ)
        info["excludeQ"] = join(("$lo-$hi" for (lo, hi) in ck.excludeQ), "; ")
    end
    if sel.nCropped + sel.nExcluded > 0
        info["nQInput"] = sel.nInput
        info["nQCropped"] = sel.nCropped
        info["nQExcluded"] = sel.nExcluded
    end
    ck.model == MODEL || (info["structureModel"] = ck.model)
    isempty(ck.chains) || (info["structureChains"] = join(ck.chains, ","))
    addHydrogens || (info["addHydrogens"] = 0)
    lMax === nothing || (info["lmaxPinned"] = 1)
    return nothing
end

"""
Computes a NUTS seed from given data input:

    0.  keep the part of the measured curve to fit (`qMin`, `qMax`, `excludeQ`) and
        scale its errors (`sigmaScale`)
    1.  resolve molSrc to a structure (the `model` of it, and only its `chains`)
    2.  look the residue names up (`components`) and decide the hydrogenation from
        them (`classify`); if addHydrogens, add hydrogens with Pdb2pqr: protein only,
        PARSE with PROPKA's pKas (they drive the terminus protonation); nucleotides
        present, AMBER and no PROPKA run if there is no protein; modified
        nucleotides are hydrogenated through the standard residue of their base
    3.  compute the accessible surface (the hydration-shell beads), take
        the diameter `D` of the whole scatterer cloud (atoms and beads),
        bin the measured curve to the Shannon channels that diameter allows
        ([`Shannon.shannonData`](@ref BAYSOL.Utils.Shannon.shannonData))
        and pick the band limit from it
    4.  build the forward-model (gram matrix) on the binned q grid
    5.  produce a [`Inference.Seed`](@ref).

# Arguments
- `molSrc::MolecularStructure.StructureSource`: where to obtain the
    structure from ([`MolecularStructure.LocalPathSource`](@ref),
    [`MolecularStructure.PDBIDSource`](@ref), or
    [`MolecularStructure.URLSource`](@ref)).
- `energy::Real`: beam energy in eV.
- `qvals::AbstractVector`: momentum-transfer grid, Å⁻¹.
- `I_exp::AbstractVector, σ_exp::AbstractVector`: measured intensity curve
    and its per-point standard errors; must be the same length as qvals. Pass the curve
    as measured: the part to fit is chosen here (`qMin`, `qMax`, `excludeQ`), it is
    binned here, and the bins with non-positive intensity are dropped here.
- `pH::Real`: solution pH, drives the titration of
    [`Protein`](@ref BAYSOL.BulkElectronDensity.Protein),
    [`DNA`](@ref BAYSOL.BulkElectronDensity.DNA) and
    [`RNA`](@ref BAYSOL.BulkElectronDensity.RNA) solutes and Pdb2pqr's hydrogen placement
    (when `addHydrogens`=true).
- `σ_pH::Real`: standard uncertainty on pH, propagated through solute titration.
- `solutes::Vector{Solute}`: the buffer's components, **excluding the
    measured macromolecule** (see [`Solute`](@ref)).

# Keywords
-   `rebin::Union{Nothing,Integer} = SHANNON_REBIN`: bins per Shannon channel `π/D`
    (the bin width is `π/(rebin·D)`, `D` the diameter of the scatterer cloud), at
    least this many: a precise curve gets finer bins, until the binning's
    worst-case bias is below `maxBinBias` of its smallest error bar (the number
    used is the report's `rebin` line); `nothing` fits the unbinned curve.
-   `maxBinBias::Real = Shannon.BIN_BIAS_MAX`: that bound, 0.3 by default; `Inf` keeps
    `rebin` as given. The data the fit used, the raw data and the choices made are in
    `seed.shannon` ([`Shannon.ShannonInfo`](@ref BAYSOL.Utils.Shannon.ShannonInfo)).
-   `lMax::Union{Nothing,Integer} = LMAX`: spherical-harmonic band
    limit for the forward model (the setting `LMAX`); `nothing`, the default, takes
    `ceil(qMax·D)` ([`Shannon.autoLmax`](@ref BAYSOL.Utils.Shannon.autoLmax)),
    `qMax` the largest binned q; an integer pins it.
-   `dropNonpositive::Bool = true`: drop the (binned) points whose intensity is not
    positive ([`Shannon.shannonData`](@ref BAYSOL.Utils.Shannon.shannonData)).
-   `addHydrogens::Bool = ADD_HYDROGENS`: whether to run PROPKA + Pdb2pqr at all (the
    setting `ADD_HYDROGENS`, true by default).
    false skips both and the forward model runs on the structure exactly as
    given (heavy-atom-only, unless the file already carries hydrogens). Modified
    nucleotides are then hydrogenated through their base, an approximation
    ([`Hydrogenator`](@ref BAYSOL.Hydrogenator)).
-   `blmChunk::Unsigned = B_LM_CHUNK`: [`Scattering.computeBLm`](@ref)
    batch size, forwarded to [`Scattering.forwardCache`](@ref) (results
    invariant, cost/memory tradeoff only).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Float64 = PROBE_RADIUS`,
    `nTarget::Union{Nothing,Int} = nothing`: hydration-shell geometry,
    forwarded to [`Scattering.forwardCache`](@ref).
-   `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`Inference.seedSampler`](@ref).
-   `κ_δρ₁₂::Real = κ_δρ₁₂`, `κ_δρ₃::Real = κ_δρ₃`:
    concentrations of the δρ₁/δρ₂ and δρ₃ priors, forwarded to
    [`Inference.seedSampler`](@ref).
-   `pmvFallbackUncert::Real = PMV_FALLBACK_UNCERT`: uncertainty, cm³ mol⁻¹, of a
    non-biological solute whose row of the partial-molar-volume table states none
    (default: the harvested mean of the table's stated ones, `NONBIO_MEAN_UNCERTAINTY`).
    Not recommended to change; it is recorded in the run log. Forwarded to
    [`Inference.seedSampler`](@ref).
-   `bounds_δρ₁₂ = BOUNDS_δρ₁₂`, `mode_δρ₁₂ = MODE_δρ₁₂`: the support `(low, high)` of the
    δρ₁/δρ₂ priors (-10, 2) and their mode (1), in units of 0.03 e⁻/Å³; the mode must lie
    strictly inside the bounds.
-   `φ_max = φ_max`: the upper bound of the cavity occupancy (1.25), which sets the support
    of the δρ₃ prior.
-   `exclVolCorrBounds = EXCL_VOL_CORR_BOUNDS`, `exclVolCorrEps = EXCL_VOL_CORR_EPS`:
    the hard bounds of the profiled excluded-volume correction c1 ((0.8, 1.3)) and the
    padding and grid step of its search (0.02, at most the width of the bounds).
-   `shellAreaPerPoint = SHELL_AREA_PER_POINT`, `shellMinPoints = SHELL_MIN_POINTS`: Å²
    of accessible surface each shell bead stands for (4) and the least number of beads (55),
    forwarded to [`sasa`](@ref BAYSOL.Geometry.sasa) (`nTarget` pins the number instead).
-   `shellSample = SHELL_SAMPLE`, `sasaNOcc = SASA_N_OCC`: directions sampled per atom
    (256) and the witness-pass prefix (104, at most `shellSample`), forwarded to
    [`sasa`](@ref BAYSOL.Geometry.sasa).
-   `beadRayRange = BEAD_RAY_RANGE`, `beadRayDirs = BEAD_RAY_DIRS`: range in Å (12) and
    number of directions (64) of the cavity classification of the beads, forwarded to
    [`sasa`](@ref BAYSOL.Geometry.sasa).

-   `qMin = Q_MIN`, `qMax = Q_MAX`: the q range fitted, Å⁻¹, both ends included; a point
    outside it is left out. `nothing` (the default) is no limit. `qMin` must be below
    `qMax`. The curve the range leaves is the measured curve of the run (`seed.shannon`):
    its binning, channels and band limit follow it.
-   `sigmaScale = SIGMA_SCALE`: the factor (above 0, 1 by default) the measured `σ_exp` are
    multiplied by, before the binning.
-   `excludeQ = EXCLUDE_Q`: ranges `((q_lo, q_hi), ...)` of q, Å⁻¹, whose points are left
    out (both ends included); `()` by default. Each needs `0 ≤ q_lo < q_hi`.
-   `chains = CHAINS`: the chain ids to keep, `("A", "B")`; `()` (the
    default) keeps all. The others are removed before the hydrogens
    are added ([`MolecularStructure.keepChains`](@ref)).
-   `model::Integer = MODEL`: which model of a multi-model structure to use, counted from 1
    in file order (1 is the first model whatever its number, the default and what was
    always read; [`MolecularStructure.resloveStruct`](@ref)).

The crop, the exclusion and the scale are applied to the measured curve first, before the
structure is touched, so a range that leaves fewer than 3 points fails at once; the
number of points that remain after the binning must be at least 3 too (the scale and the
background are fitted). Waters are not part of the model (the hydration shell stands for
them) and ligands, ions included, are, as heavy atoms without hydrogens (the loader keeps
every non-water HETATM group, atoms of a known element), and which alternate
location of an atom is used is that of BioStructures (the one of highest occupancy):
neither is a keyword.

Every setting of `loadSettings` that the structure, shell and priors depend on is
a keyword here: [`seedKeywords`](@ref) turns the settings into them. The keywords added
after `pmvFallbackUncert` are checked as `loadSettings` checks the setting of the same
name (the lower-case keyword is the setting's name, `MAP_N_STARTS` → `mapNStarts`), and a
bad value throws the same [`InvalidSettingsError`](@ref) lines. With every keyword at its
default the seed is what it was before they existed. A run that changes one of the data or
structure keywords records it (`qMin`, `qMax`, `sigmaScale`, `excludeQ`, the number of
points before and after, `structureModel`, `structureChains`, `addHydrogens`,
`lmaxPinned`) in its log and workbook.

# Returns
-   `seed::Inference.Seed`, ready to pass to [`runModel`](@ref)/[`Inference.infer`](@ref).

# Exceptions
- `MolecularStructure.ComponentError`: a residue name is neither in the bundled component
    table nor in the cache and cannot be downloaded (offline).
- `DomainError`: qvals, `iExp`, and `σ_exp` have mismatched lengths, or
    `pmvFallbackUncert` is not finite and above 0.
- [`InvalidSettingsError`](@ref): `bounds_δρ₁₂`, `mode_δρ₁₂`, `φ_max`,
    `exclVolCorrBounds`, `exclVolCorrEps`, `shellAreaPerPoint`,
    `shellMinPoints`, `shellSample`, `sasaNOcc`, `beadRayRange` or
    `beadRayDirs`, `qMin`, `qMax`, `sigmaScale`, `excludeQ`, `chains` or `model` is
    outside its limits or breaks a rule between them (`mode_δρ₁₂` not strictly inside
    `bounds_δρ₁₂`, `exclVolCorrEps` above the width of `exclVolCorrBounds`,
    `sasaNOcc` above `shellSample`, `qMin` not below `qMax`, a range of `excludeQ`
    with `q_lo` not below `q_hi`), with the line `loadSettings` gives.
- `MolecularStructure.StructureSourceError`: `model` is above the number of models of the
    structure, or `chains` names a chain it does not have (the message lists them).
- `ArgumentError`: an input is outside its limits (a non-finite or non-positive q, σ_exp,
    `energy`,
    `thickness` or κ; a negative `σ_pH` or `probe`; `rebin`, `lMax`, `nTarget` or
    `blmChunk` below 1; a temperature at or below absolute zero), or `qvals/I_exp/σ_exp`
    are empty, or
    no point has a positive intensity after binning, or fewer than 3 points are left to fit
    by `qMin`, `qMax` and `excludeQ` (before the binning) or by the binning and the
    dropping of non-positive bins (the message names those keywords).
"""
function seedModel(
    molSrc::MolecularStructure.StructureSource,
    energy::Real,
    qvals::AbstractVector,
    iExp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    rebin::Union{Nothing,Integer} = SHANNON_REBIN,
    maxBinBias::Real = Shannon.BIN_BIAS_MAX,
    lMax::Union{Nothing,Integer} = LMAX,
    dropNonpositive::Bool = true,
    addHydrogens::Bool = ADD_HYDROGENS,
    blmChunk::Unsigned = B_LM_CHUNK,
    thickness::Real = SHELL_THICKNESS,
    t::Real = DEFAULT_TEMPERATURE_C,
    probe::Float64 = PROBE_RADIUS,
    nTarget::Union{Nothing,Int} = nothing,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
    pmvFallbackUncert::Real = PMV_FALLBACK_UNCERT,
    bounds_δρ₁₂ = Inference.BOUNDS_δρ₁₂,
    mode_δρ₁₂ = Inference.MODE_δρ₁₂,
    φ_max = Inference.φ_max,
    exclVolCorrBounds = Inference.EXCL_VOL_CORR_BOUNDS,
    exclVolCorrEps = Inference.EXCL_VOL_CORR_EPS,
    shellAreaPerPoint = Geometry.SHELL_AREA_PER_POINT,
    shellMinPoints = Geometry.SHELL_MIN_POINTS,
    shellSample = Geometry.SHELL_SAMPLE,
    sasaNOcc = Geometry.SASA_N_OCC,
    beadRayRange = Geometry.BEAD_RAY_RANGE,
    beadRayDirs = Geometry.BEAD_RAY_DIRS,
    qMin = Q_MIN,
    qMax = Q_MAX,
    sigmaScale = SIGMA_SCALE,
    excludeQ = EXCLUDE_Q,
    chains = CHAINS,
    model = MODEL,
)::Inference.Seed
    # the checks of loadSettings, on the keywords that are settings (and the rules
    # between them); the values come back in the types the code below wants
    ck = _checkedKeywords(
        :seedModel,
        (; bounds_δρ₁₂, mode_δρ₁₂, φ_max, exclVolCorrBounds, exclVolCorrEps,
            shellAreaPerPoint, shellMinPoints, shellSample, sasaNOcc,
            beadRayRange, beadRayDirs, qMin, qMax, sigmaScale, excludeQ, chains,
            model),
    )
    # the static build allocates large temporaries; collect
    # once per byte budget instead of whenever the heap grows
    return withGcPaused() do
        # the run's clock starts here; writeLog reads the wall clock off it
        log = StageLog()

        if !(length(qvals) == length(iExp) == length(σ_exp))
            throw(
                DomainError(
                    (
                    length(qvals),
                    length(iExp),
                    length(σ_exp),
                    "qvals, I_exp, and σ_exp must have the same length",
                )
                ),
            )
        elseif (length(qvals) == 0)
            throw(ArgumentError("qvals, I_exp, and σ_exp cannot be empty"))
        end

        # the part of the curve to fit, and the scale of its errors: before anything else
        # (a bad point that `excludeQ` leaves out is never checked)
        sel = _selectCurve(
            qvals, iExp, σ_exp; qMin = ck.qMin, qMax = ck.qMax,
            sigmaScale = ck.sigmaScale, excludeQ = ck.excludeQ,
        )
        qvals, iExp, σ_exp = sel.q, sel.I, sel.σ

        # inputs that must be positive or inside a range (and never a zero divisor)
        _need(all(isfinite, qvals) && all(>(0), qvals), "q must be finite and positive")
        _need(all(isfinite, iExp), "I_exp must be finite")
        _need(all(x -> isfinite(x) && x > 0, σ_exp), "σ_exp must be finite and positive")
        _need(isfinite(energy) && energy > 0, "energy must be a positive number of eV")
        _need(
            isfinite(pH) && isfinite(σ_pH) && σ_pH ≥ 0,
            "pH must be finite and σ_pH must not be negative",
        )
        _need(isfinite(t) && t > -273.15, "t must be above absolute zero (°C)")
        _need(rebin === nothing || rebin ≥ 1, "rebin must be at least 1 (or nothing)")
        _need(maxBinBias > 0, "maxBinBias must be positive")
        _need(lMax === nothing || lMax ≥ 1, "lMax must be at least 1 (or nothing)")
        _need(blmChunk ≥ 1, "blmChunk must be at least 1")
        _need(isfinite(thickness) && thickness > 0, "thickness must be positive")
        _need(isfinite(probe) && probe ≥ 0, "probe must be finite and not negative")
        _need(nTarget === nothing || nTarget ≥ 1, "nTarget must be ≥ 1 or nothing")
        _need(κ_δρ₁₂ > 0 && κ_δρ₃ > 0, "κ_δρ₁₂ and κ_δρ₃ must be positive")

        # load pdb into cache, then add hydrogens if requested. What the residues are
        # (components) decides how: PARSE with PROPKA, except AMBER without PROPKA for a
        # nucleic acid alone.
        path = timed!(log, :static, 1, "resloveStruct") do
            p = MolecularStructure.resloveStruct(molSrc; model = ck.model)
            MolecularStructure.keepChains(p, ck.chains)
        end

        # the residue names of the structure, looked up in the component table (loaded
        # here on first use), the cache and, for names newer than the table, the RCSB
        tStage = tick()
        infos = MolecularStructure.component.(MolecularStructure.residueNames(path))
        nSrc(s) = count(i -> i.source === s, infos)
        tock!(
            log,
            :static,
            1,
            "components",
            tStage;
            note = "[$(length(infos)) residue names: $(nSrc(:builtin)) builtin, " *
                   "$(nSrc(:cache)) cache, $(nSrc(:download)) download]",
        )

        # what the text of the structure needs (chains reusing an id, duplicate atoms) and
        # whether it looks like a dummy-atom or fragment model (logged, flow unchanged)
        tStage = tick()
        issues = MolecularStructure.structureIssues(path)
        dummy = MolecularStructure.logDummyLike(path)
        tock!(
            log, :static, 1, "structure checks", tStage;
            note = "[$(issues.relabelled) chains relabelled, $(issues.dropped) " *
                   "duplicate atoms dropped, $(dummy.n) dummy-like findings]",
        )
        extra =
            (issues.relabelled > 0 ? "; $(issues.relabelled) chains relabelled" : "") *
            (dummy.n > 0 ? "; $(dummy.n) dummy-like residues (undefined behaviour)" : "")

        hpath = path
        if addHydrogens
            tStage = tick()
            choice = Hydrogenator.hydrogenationChoice(infos, path)
            tock!(
                log, :static, 1, "classify", tStage;
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
                    note = hit(Hydrogenator._pkaPath(path)),
                ) do
                    Hydrogenator.propkaPkas(path)
                end
                titration = Propka(pKas)
            end
            hpath = timed!(
                log, :static, 1, "pdb2pqr" * suffix;
                note = hit(Hydrogenator._hydrogensPath(path, pH, ff, titration)),
            ) do
                Hydrogenator.resolveHydrogens(path, pH; ff, titration)
            end

            # modified bases are hydrogenated through their base: say how far that got
            if Hydrogenator.hasModifiedNucleotides(infos)
                tStage = tick()
                d = Hydrogenator.modifiedHydrogenDeficit(hpath, infos)
                tock!(
                    log,
                    :static,
                    1,
                    "modified nucleotide hydrogens",
                    tStage;
                    note = "[$(d.residues) residues: $(d.withBase) hydrogenated " *
                           "through their base, $(d.noBase) without a base; " *
                           "$(d.placed) hydrogens placed, $(d.expected) in the free " *
                           "components' formulas]",
                )
            end

            # modified amino acids likewise, through their standard parent
            if Hydrogenator.hasModifiedAmino(infos)
                tStage = tick()
                a = Hydrogenator.modedAaHyd(hpath, infos)
                tock!(
                    log, :static, 1, "modified amino acid hydrogens", tStage;
                    note = "[$(a.residues) residues: $(a.withParent) hydrogenated " *
                           "through " *
                           "their parent, $(a.noParent) without a parent; " *
                           "$(a.placed) hydrogens placed]",
                )
            end

            # pdb2pqr drops some heavy atoms (the phosphorus of a 5' end) and adds others
            tStage = tick()
            b = Hydrogenator.hydrogenationBalance(hpath)
            tock!(
                log, :static, 1, "heavy atoms", tStage;
                note = "[$(Hydrogenator.heavyAtomCount(path)) in, " *
                       "$(Hydrogenator.heavyAtomCount(hpath)) out" *
                       (
                           b === nothing ? "" :
                           "; $(b.restored) restored, $(b.added) added by pdb2pqr" *
                           (b.ligands > 0 ? ", $(b.ligands) ligand atoms put back" : "")
                       ) * "]",
            )
        end
        mol = timed!(log, :static, 1, "loadMolecule") do
            MolecularStructure.loadMolecule(hpath)
        end

        # the data the forward model is built for: the accessible
        # surface is needed first, since the diameter of the whole
        # scatterer cloud fixes the Shannon width and the band limit
        shell = timed!(log, :static, 1, "SASA") do
            sasa(
            mol; probe = probe, nTarget = nTarget,
            shellAreaPerPoint = ck.shellAreaPerPoint,
            shellMinPoints = ck.shellMinPoints, shellSample = ck.shellSample,
            sasaNOcc = ck.sasaNOcc, beadRayRange = ck.beadRayRange,
            beadRayDirs = ck.beadRayDirs
)
        end
        info  = timed!(
        log, :static, 1, "shannon (diameter, binning)"
) do
            D = Shannon.cloudDiameter(
            hcat(MolecularStructure.coordsCartesian(mol), shell[1])
)
            Shannon.shannonData(
            qvals,
            iExp,
            σ_exp;
            D = D,
            rebin = rebin,
            maxBinBias = maxBinBias,
            lMax = lMax,
            dropNonpositive = dropNonpositive
)
        end
        # what the fit is of: fewer than 3 points cannot fit the scale and the background
        length(info.q) >= 3 || throw(
            ArgumentError(
                "only $(length(info.q)) point(s) are left to fit after the q range, the " *
                "exclusions, the binning and the dropping of non-positive intensities " *
                "($(length(info.qRaw)) measured points were selected by qMin, qMax " *
                "and excludeQ): at least 3 are needed; widen qMin/qMax or exclude less",
            ),
        )
        log.info["lMax"]              = info.lMax
        log.info["nQRaw"]             = length(info.qRaw)
        log.info["rebin"]             = info.rebin
        log.info["D"]                 = info.D
        log.info["nChannels"]         = info.nChannels
        log.info["nNonpositive"]      = info.nNonpositive
        log.info["pmvFallbackUncert"] = Float64(pmvFallbackUncert)
        # the conditions of the run, which the log lists with the setup (`writeLog`)
        log.info["temperatureC"] = Float64(t)
        log.info["ph"]           = Float64(pH)
        log.info["sigmaPh"]      = Float64(σ_pH)
        log.info["energyEv"]     = Float64(energy)
        # the data and structure choices that differ from the defaults (a default run's
        # log is what it always was)
        _recordChoices!(log.info, sel, ck; lMax, addHydrogens)

        # calculate forward model
        fw = timed!(log, :static, 1, "forwardCache") do
            Scattering.forwardCache(
                mol,
                info.q,
                info.lMax,
                energy;
                chunk = blmChunk,
                thickness = thickness,
                probe = probe,
                nTarget = nTarget,
                shell = shell,
                stageLog = log,
            )
        end

        return timed!(log, :static, 1, "seedSampler (priors, WLS)") do
            Inference.seedSampler(
                fw,
                info.I,
                info.σ,
                pH,
                σ_pH,
                solutes;
                t = t,
                κ_δρ₁₂ = κ_δρ₁₂,
                κ_δρ₃ = κ_δρ₃,
                pmvFallbackUncert = pmvFallbackUncert,
                bounds_δρ₁₂ = ck.bounds_δρ₁₂,
                mode_δρ₁₂ = ck.mode_δρ₁₂,
                φ_max = ck.φ_max,
                exclVolCorrBounds = ck.exclVolCorrBounds,
                exclVolCorrEps = ck.exclVolCorrEps,
                timing = log,
                shannon = info,
            )
        end
    end   # withGcPaused
end
