# SPDX-License-Identifier: LGPL-3.0-or-later

# The tunable constants of `Scattering`: the hydration-shell thickness and the memory
# headroom of the static build. Included by
# `scattering.jl`, so they live in the module.

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. 3.0 is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

@assert(SHELL_THICKNESS > 0, "SHELL_THICKNESS must be positive")

"""
Memory to leave free for other programs while the static build runs, in percent of the
machine's total memory (`Sys.total_memory()`). The build of the species Gram matrix
([`forwardCache`](@ref)) works through the q values in blocks, and the size of a block is
chosen so that the build stays within `Sys.free_memory()` minus this headroom: 10 % of
15.3 GiB leaves 1.5 GiB. A larger headroom means more, smaller blocks (and a little more
time), never a different result. Allowed values are `MEMORY_HEADROOM_MIN` to
`MEMORY_HEADROOM_MAX`; a whole number.
"""
const MEMORY_HEADROOM = 10

"The least `MEMORY_HEADROOM` allowed, in percent: a build must leave some memory free."
const MEMORY_HEADROOM_MIN = 5

"The most `MEMORY_HEADROOM` allowed, in percent: more would leave the build too little."
const MEMORY_HEADROOM_MAX = 50

@assert(
    MEMORY_HEADROOM_MIN ≤ MEMORY_HEADROOM ≤ MEMORY_HEADROOM_MAX,
    "MEMORY_HEADROOM must be within its limits",
)

"""
The limits of each setting above that has one, read by the terminal interface when a user
edits a value (`dev/scripts/harvest-defaults.jl` copies them to `default_settings.json`).
Each limit is `above` or `below` (strict) or `atLeast` or `atMost` (inclusive).
"""
const SETTING_LIMITS = (
    SHELL_THICKNESS = (above = 0,),
    MEMORY_HEADROOM = (atLeast = MEMORY_HEADROOM_MIN, atMost = MEMORY_HEADROOM_MAX),
)

"""
The constants above that are settings, the ones a user may change: the terminal interface
shows each on a page of its own, and `loadSettings`
accepts a saved value for these and for no other name.
"""
const SETTING_NAMES = (
    :SHELL_THICKNESS, :MEMORY_HEADROOM,
)
