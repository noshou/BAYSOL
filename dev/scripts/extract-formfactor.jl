# SPDX-License-Identifier: LGPL-3.0-or-later

# Extract data from xraydb.sqlite into one compact database.

using DBInterface
using SQLite

"""
    numbers(json, what) -> Vector{Float64}

The numbers of a JSON array of plain numbers (`"[1, 2.5, 3e-4]"`) as a vector of doubles.
"""
function numbers(json::AbstractString, what)
    text = replace(json, r"^[\[\]\s]+|[\[\]\s]+$" => "")
    out = Float64[]
    for tok in split(text, ',')
        tok = strip(tok)
        occursin(r"^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$", tok) ||
            error("$what: '$tok' is not a number")
        push!(out, parse(Float64, tok))
    end
    return out
end

"A sequence of doubles as the bytes of a little-endian Float64 array (bound as a BLOB)."
blob(xs) = collect(reinterpret(UInt8, htol.(Float64.(xs))))

# The schema, one statement per element and written out verbatim (not indented or
# reformatted): the DDL text is stored in sqlite_master, and the bundled database has this
# exact text.
const SCHEMA = [
    """CREATE TABLE waasmaier (
    ion     TEXT PRIMARY KEY,
    element TEXT NOT NULL,
    z       INTEGER NOT NULL,
    c       REAL NOT NULL,
    a1 REAL NOT NULL, a2 REAL NOT NULL, a3 REAL NOT NULL, a4 REAL NOT NULL, \
a5 REAL NOT NULL,
    b1 REAL NOT NULL, b2 REAL NOT NULL, b3 REAL NOT NULL, b4 REAL NOT NULL, b5 REAL NOT NULL
)""",
    "CREATE INDEX idx_waasmaier_element ON waasmaier(element)",
    """CREATE TABLE chantler (
    element TEXT PRIMARY KEY,
    z       INTEGER NOT NULL,
    npts    INTEGER NOT NULL,
    emin    REAL NOT NULL,
    emax    REAL NOT NULL,
    energy  BLOB NOT NULL,
    f1      BLOB NOT NULL,
    f2      BLOB NOT NULL
)""",
    "CREATE TABLE provenance (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
]

# Where the data came from, in the provenance table.
const PROVENANCE = [
    "f0_source" =>
        "Waasmaier & Kirfel (1995) Acta Cryst A51, 416-431; " *
        "doi:10.1107/S0108767394013292",
    "f0_form" =>
        "f0(s) = c + sum_{i=1..5} a_i*exp(-b_i*s^2), s = q/(4*pi) [1/Ang], " *
        "valid 0 <= s <= 6",
    "anomalous_source" =>
        "Chantler FFAST (NIST), fine grid; J. Phys. Chem. Ref. Data 24 " *
        "71 (1995), 29 597 (2000)",
    "anomalous_form" =>
        "f1 stored as f1_FFAST - Z + f_rel(3/5 CL) + f_NT (xraydb " *
        "convention); f = f0 + f1 + i*f2",
    "extracted_from" => "xraydb 4.5.8 xraydb.sqlite",
    "license" =>
        "CC0 1.0 - xraydb LICENSE dedicates xraydb.sqlite and data_sources/ to " *
        "the public domain",
]

query(db, sql) = [NamedTuple(r) for r in DBInterface.execute(db, sql)]
execute!(db, sql, params = ()) = DBInterface.execute(db, sql, params)

# Copies the Waasmaier-Kirfel f0 coefficients: one row per ion, the offset c, five
# Gaussian amplitudes a1..a5 and five exponents b1..b5 (the source keeps the two
# five-element lists as JSON text).
function add_waasmaier!(src, dst)
    rows = query(
        src,
        "SELECT atomic_number, element, ion, offset, scale, exponents " *
        "FROM Waasmaier",
    )
    for r in rows
        a = numbers(r.scale, "Waasmaier $(r.ion) scale")
        b = numbers(r.exponents, "Waasmaier $(r.ion) exponents")
        (length(a) == 5 && length(b) == 5) || error(
            "Waasmaier $(r.ion): expected 5 " *
            "amplitudes and 5 exponents, got " *
            "$(length(a)) and $(length(b))",
        )
        execute!(dst,
            "INSERT INTO waasmaier VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            Any[
                lowercase(r.ion),
                lowercase(r.element),
                r.atomic_number,
                r.offset,
                a...,
                b...,
            ])
    end
    return length(rows)
end

"""
    dedupe_grid(energies) -> Vector{Int}

The (1-based) indices of the grid points to keep: the first, then each point above the
last one kept.
"""
function dedupe_grid(energies)
    kept = [1]
    last_e = energies[1]
    for i in 2:length(energies)
        if energies[i] > last_e
            last_e = energies[i]
            push!(kept, i)
        end
    end
    return kept
end

# Copies the Chantler FFAST anomalous terms: one row per element, the energy grid and f1,
# f2 on it, packed as Float64 blobs.
function add_chantler!(src, dst)
    rows = query(
        src,
        "SELECT c.element AS element, c.energy AS energy, c.f1 AS f1, " *
        "c.f2 AS f2, e.atomic_number AS z " *
        "FROM Chantler c LEFT JOIN elements e ON e.element = c.element",
    )
    total = 0
    for r in rows
        ismissing(r.z) && error("Chantler $(r.element) has no atomic number in the " *
              "elements table")
        e = numbers(r.energy, "Chantler $(r.element) energy")
        y1 = numbers(r.f1, "Chantler $(r.element) f1")
        y2 = numbers(r.f2, "Chantler $(r.element) f2")
        length(e) == length(y1) == length(y2) || error(
            "Chantler $(r.element): grid " *
            "lengths differ ($(length(e)), " *
            "$(length(y1)), $(length(y2)))",
        )
        kept = dedupe_grid(e)
        nAll = length(e)
        e, y1, y2 = e[kept], y1[kept], y2[kept]
        length(kept) != nAll &&
            println("  deduped ", r.element, ": ", nAll, " -> ", length(kept), " points")
        execute!(dst, "INSERT INTO chantler VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            Any[lowercase(r.element), r.z, length(e), first(e), last(e), blob(e), blob(y1),
                blob(y2)])
        total += length(e)
    end
    return length(rows), total
end

# Adds deuterium `d` as a copy of hydrogen `h` in both tables.
function add_deuterium!(dst)
    execute!(
        dst,
        "INSERT INTO waasmaier SELECT 'd', 'd', z, c, a1, a2, a3, a4, a5, " *
        "b1, b2, b3, b4, b5 FROM waasmaier WHERE ion = 'h'",
    )
    execute!(
        dst,
        "INSERT INTO chantler SELECT 'd', z, npts, emin, emax, energy, f1, f2 " *
        "FROM chantler WHERE element = 'h'",
    )
    note = "d is a copy of h: same electron cloud, hence the same f0, f1, f2 for X-rays"
    execute!(dst, "INSERT INTO provenance VALUES (?, ?)", Any["deuterium", note])
end

"""
Reads the source database `src_path` and writes the compact database `dst_path` (which
must not exist).
"""
function build(src_path, dst_path)
    src = SQLite.DB(src_path)
    dst = SQLite.DB(dst_path)
    try
        foreach(sql -> execute!(dst, sql), SCHEMA)
        n_w = add_waasmaier!(src, dst)
        n_c, total = add_chantler!(src, dst)
        for (k, v) in PROVENANCE
            execute!(dst, "INSERT INTO provenance VALUES (?, ?)", Any[k, v])
        end
        add_deuterium!(dst)
        execute!(dst, "VACUUM")
        println("waasmaier: ", n_w, " species, chantler: ", n_c, " elements / ", total,
            " grid points")
    finally
        SQLite.close(src)
        SQLite.close(dst)
    end
end

# Builds the database in a temporary file next to the destination and renames it over the
# destination only when it is complete, so a failure midway leaves any existing
# destination untouched and no partial file behind.
function main(args)
    if length(args) != 2
        println(stderr, "usage: extract-formfactor.jl xraydb.sqlite form_factors.sqlite3")
        return 2
    end
    src, dst = args
    if !isfile(src)
        println(stderr, "no such file: ", src)
        return 1
    end
    part = dst * ".part"
    rm(part; force = true)
    try
        build(src, part)
        mv(part, dst; force = true)
        println("size: ", filesize(dst), " bytes")
    finally
        rm(part; force = true)
    end
    return 0
end

exit(main(ARGS))
