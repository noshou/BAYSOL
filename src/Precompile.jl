# SPDX-License-Identifier: LGPL-2.1-or-later

# Precompile workload: one small end-to-end fit (a 16-atom helix, 60 q points, a 40-iteration NUTS chain) through the
# whole pipeline, so the methods every fit compiles on its first call (structure loading, SASA, the Gram matrix, the
# MAP search, NUTS with ForwardDiff, the report) are in the package's compiled cache instead of being compiled in the
# first fit of every process. That compile time was most of the wall clock of a first fit; it is paid once, at
# precompilation. It needs no network, no PROPKA/pdb2pqr (`add_hydrogens = false`) and writes nothing outside a
# temporary directory.

using PrecompileTools: @setup_workload, @compile_workload
using Base.CoreLogging: with_logger, NullLogger   # (the Logging stdlib is not a dependency)

@setup_workload begin
    # 16 atoms on a helix, as ATOM records of four alanines (N, CA, C, O)
    pdb = mktempdir()
    path = joinpath(pdb, "precompile.pdb")
    open(path, "w") do io
        names = ("N", "CA", "C", "O"); elems = ("N", "C", "C", "O")
        for i in 0:15
            res, k = divrem(i, 4)
            x, y, z = 1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i
            println(io, rpad(string("ATOM  ", lpad(i + 1, 5), " ", rpad(names[k+1], 4), " ALA A", lpad(res + 1, 4), "    ",
                lpad(string(round(x; digits = 3)), 8), lpad(string(round(y; digits = 3)), 8), lpad(string(round(z; digits = 3)), 8),
                "  1.00  0.00          ", lpad(elems[k+1], 2)), 80))
        end
        println(io, "END")
    end
    q = collect(range(0.02, 0.30; length = 60))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    σ = 0.02 .* I
    solutes = Fitting.Solute[Fitting.NonBiological(0.15, 0.001, "sodium chloride")]

    @compile_workload begin
        # a failing workload must cost only speed, never the package: warn and carry on
        try
            # the sampler prints its statistics to stdout; nothing of the workload should reach the installer's terminal
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    with_logger(NullLogger()) do
                        seed = seed_model(MolecularStructure.LocalPathSource(path), 9000.0, q, I, σ, 7.0, 0.1, solutes;
                                          add_hydrogens = false)
                        result = run_model(seed, 40, 20)
                        write_report(IOBuffer(), result)
                    end
                end
            end
        catch e
            @warn "BAYSOL precompile workload failed; the first fit of each process will compile instead" exception = (e, catch_backtrace())
        end
    end
    rm(pdb; recursive = true, force = true)
end
