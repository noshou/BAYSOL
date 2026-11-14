# SPDX-License-Identifier: LGPL-3.0-or-later

# The tunable constants of `Geometry`: the probe radius and the hydration-shell and
# surface-sampling settings. Included by `geometry.jl`, so they live in the module.

"Solvent probe radius in Å (water), forwarded to [`sasa`](@ref BAYSOL.Geometry.sasa)."
const PROBE_RADIUS = 1.4

"""
Å² of accessible surface each shell point stands for; sets the cloud's spacing
at ≈ √`SHELL_AREA_PER_POINT` ≈ 2 Å.

Calibrated against CRYSOL: its default --fb 17 puts F(17) = 1597 points on a
typical globular protein (~6500 Å²), i.e. ~4 Å² each. Budgeting by area rather
than by a fixed count keeps that spacing at every size, and since surface area
grows as N^(2/3), the point count is sub-linear in atom count rather than flat.
CRYSOL instead caps --fb at F(18) = 2584 for any structure, which
under-resolves large complexes; pass `nTarget` explicitly to reproduce that.
"""
const SHELL_AREA_PER_POINT = 4.0

"Floor on the derived point budget: F(10), the
smallest Fibonacci grid CRYSOL's --fb accepts."
const SHELL_MIN_POINTS = 55

"""
Sample directions per atom, before occlusion and before thinning.
Internal: only fine enough to resolve one atom's patch.
"""
const SHELL_SAMPLE = 256

"""
Range (Å) over which [`_beadClass`](@ref BAYSOL.Geometry._beadClass)
casts escape rays. A void whose wall is further than this in every
direction is bulk solvent, not a cavity.
"""
const BEAD_RAY_RANGE = 12.0

"""
Directions sampled by [`_beadClass`](@ref BAYSOL.Geometry._beadClass);
about half fall in the outward hemisphere and are used.
"""
const BEAD_RAY_DIRS = 64

"""
Witness-pass prefix of the [`SHELL_SAMPLE`](@ref) directions in
[`sasa`](@ref BAYSOL.Geometry.sasa): an atom none of whose first `SASA_N_OCC`
plastic-sequence points is exposed may still expose up to ~3/`SASA_N_OCC` of its
sphere (rule of three; a relative bound, the same for every atom size). Such an atom
skips the remaining directions and contributes no points.

**Accepted error.** The pass may cost at most the shell's own sampling error: the
256-direction sampling is off by up to 0.92 % on the analytic two-sphere cap
(`test-sasa.jl`, `SASA_CAP_RTOL`). 80 is the shortest prefix within that on the fixtures,
but with almost no margin and only ~5 ms saved per fit over 128, so 104 is used: about
half of 80's loss, a comfortable margin, and nearly all of the speed.
Measured loss of total accessible area against sampling every direction, on the protein
fixtures (crambin, BPTI, RNase A, hemoglobin, IgG):

| `SASA_N_OCC` | 48 | 56 | 64 | 80 | 96 | **104** | 128 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **worst loss** | 2.02 % | 1.83 % | 1.40 % | 0.90 % | 0.66 % | **0.57 %** | 0.40 % |

At 104 the loss is 0.31–0.57 % (always a loss, never a gain: dropped atoms have a real but
small exposed patch); 40–58 % of atoms bail, and with the packed cap test the sampling
loop runs 1.9–2.4× faster than the previous per-point test (1.15–1.20× of that is the pass).
"""
const SASA_N_OCC = 104

@assert(0 < SASA_N_OCC ≤ SHELL_SAMPLE, "SASA_N_OCC must be in (0, SHELL_SAMPLE]")

# Sanity limits: positive, and never a zero where the code divides.
@assert(PROBE_RADIUS ≥ 0, "PROBE_RADIUS must not be negative")
@assert(SHELL_AREA_PER_POINT > 0, "SHELL_AREA_PER_POINT must be positive (it is a divisor)")
@assert(
    SHELL_MIN_POINTS ≥ 1 && SHELL_SAMPLE ≥ 1,
    "SHELL_MIN_POINTS and SHELL_SAMPLE must be at least 1"
)
@assert(BEAD_RAY_RANGE > 0 && BEAD_RAY_DIRS ≥ 1, "BEAD_RAY_RANGE > 0 and BEAD_RAY_DIRS ≥ 1")

"""
The limits of each setting above that has one, read by the terminal interface when a user
edits a value (`dev/scripts/harvest-defaults.jl` copies them to `default_settings.json`).
Each limit is `above` or `below` (strict) or `atLeast` or `atMost` (inclusive). Limits
that tie two settings together (`SASA_N_OCC` ≤ `SHELL_SAMPLE`) stay in the checks above.
"""
const SETTING_LIMITS = (
    PROBE_RADIUS = (atLeast = 0,),
    SHELL_AREA_PER_POINT = (above = 0,),
    SHELL_MIN_POINTS = (atLeast = 1,),
    SHELL_SAMPLE = (atLeast = 1,),
    SASA_N_OCC = (above = 0,),
    BEAD_RAY_RANGE = (above = 0,),
    BEAD_RAY_DIRS = (atLeast = 1,),
)

"""
The rules that tie settings above together, which a set of values must obey as a whole;
each is a `(rule, setting, ...)` and is read by the terminal interface and by
`loadSettings`. `:atMostSetting`: `setting` is at
most the value of the setting `of`.
"""
const SETTING_RELATIONS = (
    (rule = :atMostSetting, setting = :SASA_N_OCC, of = :SHELL_SAMPLE),
)

"""
The constants above that are settings, the ones a user may change: the terminal interface
shows each on a page of its own, and `loadSettings`
accepts a saved value for these and for no other name.
"""
const SETTING_NAMES = (
    :PROBE_RADIUS, :SHELL_AREA_PER_POINT, :SHELL_MIN_POINTS, :SHELL_SAMPLE,
    :SASA_N_OCC, :BEAD_RAY_RANGE, :BEAD_RAY_DIRS,
)
