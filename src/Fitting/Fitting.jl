# SPDX-License-Identifier: LGPL-3.0-or-later
module Fitting

include("WLS.jl")
include("DensityOfSolvent.jl")

export WLSError, WLSFit, wls_fit, wls_predict, wls_prof_nll, wls_marg_nll, 
Solute, Protein, NonBiological, dns_prior

end # module
