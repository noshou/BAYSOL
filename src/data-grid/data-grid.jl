# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Everything between a measured SAXS curve and the fit that depends on the curve
alone, not on the model parameters.

-   `diameter.jl`: [`cloudDiameter`](@ref), the exact diameter `D` of the scatterer cloud
    (a 3-D quickhull in `quick-hull.jl`, then the farthest pair of the hull vertices).
-   `shannon.jl`: Shannon sampling. A particle of diameter `D` has a curve that carries
    no information at a q spacing finer than `π/D` (one *Shannon channel*), so a curve of
    thousands of points holds only `(qMax - qMin)·D/π` independent values.
    [`shannonData`](@ref) bins the measured curve to that resolution.
-   `band-limit.jl`: [`autoLmax`](@ref), the band limit the binned q range needs.
-   `interpolation.jl`: [`modelOnRaw`](@ref) and [`rawInterpolation`](@ref), the model
    on the fitted grid brought back onto the measured one.
-   `residuals.jl`: [`residualStructure`](@ref), whether the residuals are white.
"""
module DataGrid

export ShannonInfo, SHANNON_REBIN, BIN_BIAS_MAX, cloudDiameter, autoLmax,
    shannonData, binBiasRatio, modelOnRaw, rawInterpolation, residualStructure

"""
Default number of bins per Shannon channel (`k`): the bin width is `π/(k·D)`. Binning
at `k ≥ 8` preserved the Laplace posterior width and moved the MAP by less than the
posterior σ on the fitting tests (see the Shannon section of the Fitting-test README).
"""
const SHANNON_REBIN = 12

"""
Largest worst-case bias of the binning, as a fraction of the smallest binned
relative error ([`binBiasRatio`](@ref)), that [`shannonData`](@ref)
accepts: if the requested `rebin` gives more, the bins are made finer until
the bound is met (or the curve is fitted unbinned). 0.3 keeps the binning's
systematic shift of any bin under a third of that bin's smallest error bar.
"""
const BIN_BIAS_MAX = 0.3

"""
How many tolerances `ε` thick the first tetrahedron of the hull must be, for a hull to be
built at all: a thinner cloud is compared pair by pair. Hulls of clouds only a few `ε`
thick were measured to lose vertices, from 25ε thick down.
"""
const FLAT_FACTOR = 1000.0

include("quick-hull.jl")
include("diameter.jl")
include("band-limit.jl")
include("shannon.jl")
include("interpolation.jl")
include("residuals.jl")

end # module
