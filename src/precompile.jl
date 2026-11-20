# SPDX-License-Identifier: LGPL-3.0-or-later

# Precompile workload: small end-to-end fits (a 16-atom helix, 60 q points, 40-iteration
# NUTS chains) through the whole pipeline, so the methods every fit compiles on its first
# call are in the package's compiled cache instead of being compiled in the first fit of
# every process. That compile time was most of the wall clock of a first fit; it is paid
# once, at precompilation. What it fires: structure loading (protein, DNA, RNA, and a
# protein with DNA), SASA, the Gram matrix, the MAP search, NUTS with ForwardDiff (the
# chains as tasks too, the sampled-c1 five-parameter run of a kinked fit), the extra
# chains of the optima, the statistics recorder, the
# figures and the workbook, the run log and the model comparison. It needs no network, no
# PROPKA/pdb2pqr (`addHydrogens = false`) and writes nothing outside a temporary directory.
# Every part runs on its own, so a failing part costs only its own speed, never the
# package.

using PrecompileTools: @setup_workload, @compile_workload
using Base.CoreLogging: with_logger, NullLogger   # (the Logging stdlib is not a dependency)

@setup_workload begin
    pdb = mktempdir()

    # One PDB of ATOM records. `atoms` holds `(name, residue, chain, number, element)`;
    # the coordinates come from `place(i)`, the position of atom `i` (from 0).
    function writePdb(path, atoms, place)
        open(path, "w") do io
            for (i, (name, residue, chain, number, element)) in enumerate(atoms)
                x, y, z = place(i - 1)
                println(
                    io,
                    rpad(
                        string("ATOM  ", lpad(i, 5), " ", rpad(name, 4), " ",
                            lpad(residue, 3), " ", chain, lpad(number, 4), "    ",
                            lpad(string(round(x; digits = 3)), 8),
                            lpad(string(round(y; digits = 3)), 8),
                            lpad(string(round(z; digits = 3)), 8),
                            "  1.00  0.00          ", lpad(element, 2)), 80),
                )
            end
            println(io, "END")
        end
        return path
    end

    # `n` alanines (N, CA, C, O) as one chain
    function alanines(n, chain = "A")
        names = ("N", "CA", "C", "O")
        elems = ("N", "C", "C", "O")
        return [
            (names[k+1], "ALA", chain, r + 1, elems[k+1]) for r in 0:(n-1) for k in 0:3
        ]
    end

    # the heavy atoms of a nucleotide: a phosphate, the sugar and the base
    sugar = (("P", "P"), ("OP1", "O"), ("OP2", "O"), ("O5'", "O"), ("C5'", "C"),
        ("C4'", "C"), ("O4'", "O"), ("C3'", "C"), ("O3'", "O"), ("C2'", "C"),
        ("C1'", "C"))
    bases = Dict(
        "DA" => (("N9", "N"), ("C8", "C"), ("N7", "N"), ("C5", "C"), ("C6", "C"),
            ("N6", "N"), ("N1", "N"), ("C2", "C"), ("N3", "N"), ("C4", "C")),
        "DT" => (("N1", "N"), ("C2", "C"), ("O2", "O"), ("N3", "N"), ("C4", "C"),
            ("O4", "O"), ("C5", "C"), ("C7", "C"), ("C6", "C")),
        "A" => (("N9", "N"), ("C8", "C"), ("N7", "N"), ("C5", "C"), ("C6", "C"),
            ("N6", "N"), ("N1", "N"), ("C2", "C"), ("N3", "N"), ("C4", "C")),
        "U" => (("N1", "N"), ("C2", "C"), ("O2", "O"), ("N3", "N"), ("C4", "C"),
            ("O4", "O"), ("C5", "C"), ("C6", "C")),
    )
    sugars(residue) = residue in ("A", "U") ? (sugar..., ("O2'", "O")) : sugar
    function nucleotides(residues, chain)
        atoms = Tuple{String,String,String,Int,String}[]
        for (r, residue) in enumerate(residues)
            for (name, element) in (sugars(residue)..., bases[residue]...)
                push!(atoms, (name, residue, chain, r, element))
            end
        end
        return atoms
    end

    # a helix of radius 1.6 Å (a rise of 0.55 Å per atom), as the first atoms of a chain,
    # and a wider one (radius 9 Å, shifted by 30 Å along the axis) for the nucleic acid
    helix(i) = (1.6 * cos(0.85 * i), 1.6 * sin(0.85 * i), 0.55 * i)
    strand(i) = (9.0 * cos(0.31 * i), 9.0 * sin(0.31 * i), 30.0 + 0.28 * i)
    mixed(i) = i < 16 ? helix(i) : strand(i - 16)

    path = writePdb(joinpath(pdb, "precompile.pdb"), alanines(4), helix)
    dna = writePdb(
        joinpath(pdb, "precompile_dna.pdb"), nucleotides(("DA", "DT"), "B"), strand)
    rna = writePdb(
        joinpath(pdb, "precompile_rna.pdb"), nucleotides(("A", "U"), "B"), strand)
    both = writePdb(
        joinpath(pdb, "precompile_mixed.pdb"),
        vcat(alanines(4), nucleotides(("DA", "DT"), "B")), mixed)

    # 4,400 atoms on a lattice (a compact block of 1,100 "residues"): above the
    # atom count from which the static build runs on several threads
    # (`ATOM_PARALLEL_MIN`, `B_LM_PARALLEL_MIN`), so those paths are compiled too
    big = writePdb(
        joinpath(pdb, "precompile_big.pdb"), alanines(1100),
        function (i)
            k = i % 4
            cell = i ÷ 4                      # one residue per lattice cell of 4 Å
            x, y, z = 4.0 * (cell % 11), 4.0 * ((cell ÷ 11) % 10), 4.0 * (cell ÷ 110)
            return (x + 1.2 * (k & 1), y + 1.2 * (k >> 1), z)
        end)
    qBig = collect(range(0.01, 0.06; length = 260))
    iBig = 100 .* exp.(-(qBig .* 30) .^ 2 ./ 3) .+ 0.5
    q = collect(range(0.02, 0.30; length = 60))
    I = 100 .* exp.(-(q .* 6) .^ 2 ./ 3) .+ 0.5
    σ = 0.02 .* I
    solutes = BulkElectronDensity.Solute[BulkElectronDensity.NonBiological(
        0.15,
        0.001,
        "sodium chloride",
    )]
    load(file; kw...) = seedModel(
        MolecularStructure.LocalPathSource(file), 9000.0, q, I, σ, 7.0, 0.1, solutes;
        addHydrogens = false, kw...)

    # One part of the workload, quiet (the sampler prints its statistics to stdout; nothing
    # of the workload should reach the installer's terminal) and on its own: a failing part
    # must cost only speed, never the package, so it warns and the next part carries on
    function part(work, label)
        try
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    with_logger(NullLogger()) do
                        work()
                    end
                end
            end
        catch e
            @warn(
                "BAYSOL precompile workload part `$label` failed; " *
                "the first fit of each process will compile instead",
                exception = (e, catch_backtrace()))
        end
        return nothing
    end

    @compile_workload begin
        local seed, result
        part("fit") do
            seed = load(path)
            # (no rerun for R̂: 40 iterations never reach 1.01 and the rerun is
            # 2000 warm-up and 2000 draws per chain)
            result = runModel(seed, 40, 20; retry = false)
        end
        # the chains run as tasks only when more than one worker is available, which the
        # one-thread precompilation process is not: run them once as tasks too, so that
        # first fits with several threads find the task machinery compiled
        part("tasks") do
            Runtime.withWorkers(4) do
                runModel(seed, 40, 20; retry = false)
            end
        end
        # (no retry or ladder part: their ~30 s of compilation save only ~3.5 s, once, in a
        # process that retries; the fit above already covers the sampled-c1 run)
        # the chains the optima of the draws get, as the run starts them
        part("extra chains") do
            sp = Inference._samplingSpace(seed)
            w = [zero(Inference.SVector{4,Float64}), zero(Inference.SVector{4,Float64})]
            Inference._runExtraChains(seed, sp, 40, 20, 0.8, UInt64(7), w, 4)
        end
        # the figures (terminal, .tex) and the workbook with all its sheets, the run log
        # and the comparison of two fits, with their timings; no LaTeX is run, as in a
        # fit's script
        part("results") do
            reference = Reference("reference", q, I)
            results(result, seed; dir = pdb, name = "precompile", io = IOBuffer(),
                references = reference, refChi2 = "1.0", tex = true, compile = false,
                tuiDir = joinpath(pdb, "tui"))
            writeLog(result; refChi2 = "1.0", path = joinpath(pdb, "precompile.LOG"),
                name = "precompile")
            compareResults([result, result], (q, I, σ); names = ["a", "b"],
                references = reference, dir = pdb, name = "compare", io = IOBuffer(),
                tex = true, compile = false, tuiDir = joinpath(pdb, "tui"))
        end
        # the structure side of a nucleic acid (DNA, RNA) and of a protein with DNA
        part("nucleic acids") do
            load(dna)
            load(rna)
            load(both)
        end
        # the static build of a structure above the thread thresholds, as tasks
        part("large structure") do
            Runtime.withWorkers(4) do
                seedModel(MolecularStructure.LocalPathSource(big), 9000.0,
                    qBig, iBig, 0.02 .* iBig, 7.0, 0.1,
                    solutes; addHydrogens = false)
            end
        end
    end
    rm(pdb; recursive = true, force = true)
end
