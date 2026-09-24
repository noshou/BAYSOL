# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared baseline so every test_*.jl in this directory can run standalone
# (`julia --project=test test/unit_tests/test_X.jl`) or aggregated via
# run_unit_tests.jl. Include-guarded so re-including it (as happens when the
# aggregator includes every file in one process) is a no-op past the first hit.
if !@isdefined(check_float)
    using Test
    using BAYSOL
    using BAYSOL.Constants: DEFAULT_ATOL

    check_float(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol
    check_complex(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol
end
