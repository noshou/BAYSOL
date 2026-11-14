# SPDX-License-Identifier: LGPL-3.0-or-later

# The tunable constants of `Scattering`: the hydration-shell thickness. Included by
# `scattering.jl`, so they live in the module.

"""
Hydration-shell thickness in Å: how far the perturbed-density water layer
extends beyond the solvent-accessible surface. 3.0 is CRYSOL's border-layer
default.
"""
const SHELL_THICKNESS = 3.0

@assert(SHELL_THICKNESS > 0, "SHELL_THICKNESS must be positive")

"""
The limits of each setting above that has one, read by the terminal interface when a user
edits a value (`dev/scripts/harvest-defaults.jl` copies them to `default_settings.json`).
Each limit is `above` or `below` (strict) or `atLeast` or `atMost` (inclusive).
"""
const SETTING_LIMITS = (SHELL_THICKNESS = (above = 0,),)

"""
The constants above that are settings, the ones a user may change: the terminal interface
shows each on a page of its own, and `loadSettings`
accepts a saved value for these and for no other name.
"""
const SETTING_NAMES = (
    :SHELL_THICKNESS,
)
