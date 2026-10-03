# SPDX-License-Identifier: LGPL-2.1-or-later

#-----------------------
# Form-factor constants
#-----------------------

"Upper end of the Waasmaier-Kirfel f0 fit range, s = sin θ/λ in Å⁻¹. Beyond it the ion fits diverge; see the FormFactor README."
const WK_S_MAX = 6.0

"""
Floor applied to Chantler f2 table values before the log-log interpolation in
`FormFactor.f1f2`: f2 is positive and spans decades, and the floor keeps the log
finite where the table stores an exact zero.
"""
const F2_LOG_FLOOR = 1e-99
