# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of dev/scripts/extract-formfactor.jl on a tiny synthetic
# xraydb.sqlite: the rows and blobs it writes, the de-duplication of repeated
# grid energies, and that a failure leaves an existing output untouched.
using DBInterface
using SQLite
using Test

const SCRIPT = joinpath(@__DIR__, "..", "scripts", "extract-formfactor.jl")
const PROJECT = dirname(Base.active_project())

function with_db(f, path)
    db = SQLite.DB(path)
    try
        return f(db)
    finally
        SQLite.close(db)
    end
end

rows(path, sql) = with_db(path) do db
    [NamedTuple(r) for r in DBInterface.execute(db, sql)]
end

execute(path, sql) = with_db(path) do db
    DBInterface.execute(db, sql)
    nothing
end

# A source database at `path`; `scale` is the JSON text of the amplitudes (wrong length:
# the tool must fail).
function make_source(path, scale)
    execute(
        path,
        "CREATE TABLE Waasmaier (atomic_number INTEGER, element TEXT, ion TEXT, " *
        "offset REAL, scale TEXT, exponents TEXT)",
    )
    execute(path, "CREATE TABLE Chantler (element TEXT, energy TEXT, f1 TEXT, f2 TEXT)")
    execute(path, "CREATE TABLE elements (element TEXT, atomic_number INTEGER)")
    execute(
        path,
        "INSERT INTO Waasmaier VALUES (6, 'C', 'C', 0.2156, '$scale', " *
        "'[20.8439, 10.2075, 0.5687, 51.6512, 0.2156]')",
    )
    execute(path, "INSERT INTO elements VALUES ('C', 6)")
    execute(
        path,
        "INSERT INTO Chantler VALUES ('C', '[1.0, 2.0, 2.0, 3.0]', " *
        "'[0.1, 0.2, 0.3, 0.4]', '[1.1, 1.2, 1.3, 1.4]')",
    )
end

doubles_of(bytes) = collect(reinterpret(Float64, bytes))

# Runs the script; (succeeded, its output).
function extract(src, dst...)
    out = IOBuffer()
    p = run(
        pipeline(
            ignorestatus(`$(Base.julia_cmd()) --project=$PROJECT $SCRIPT $src $dst`);
            stdout = out, stderr = out),
    )
    return success(p), String(take!(out))
end

@testset "rows, lower-cased names, de-duplicated grid, blobs of little-endian doubles" begin
    dir = mktempdir()
    make_source(joinpath(dir, "src.sqlite"), "[2.31, 1.02, 1.5886, 0.865, 0.2156]")
    ok, _ = extract(joinpath(dir, "src.sqlite"), joinpath(dir, "out.sqlite3"))
    out = joinpath(dir, "out.sqlite3")
    @test ok
    w = only(
        rows(out, "SELECT ion, element, z, c, a1, a5, b1 FROM waasmaier WHERE ion = 'c'"),
    )
    @test w == (ion = "c", element = "c", z = 6, c = 0.2156, a1 = 2.31, a5 = 0.2156,
        b1 = 20.8439)
    c = only(
        rows(
            out,
            "SELECT element, z, npts, emin, emax, length(energy) AS n, f1 " *
            "FROM chantler WHERE element = 'c'",
        ),
    )
    @test (c.element, c.z, c.npts, c.emin, c.emax, c.n) == ("c", 6, 3, 1.0, 3.0, 24)
    @test doubles_of(c.f1) == [0.1, 0.2, 0.4]
    @test sort([
        r.name for r in rows(out, "SELECT name FROM sqlite_master " *
                       "WHERE type = 'table'")
    ]) ==
          ["chantler", "provenance", "waasmaier"]
    # deuterium is a copy of hydrogen's rows; none here, since the source has no hydrogen
    @test isempty(rows(out, "SELECT * FROM waasmaier WHERE ion = 'd'"))
end

@testset "a bad source leaves the old output byte for byte and no .part file" begin
    dir = mktempdir()
    make_source(joinpath(dir, "good.sqlite"), "[2.31, 1.02, 1.5886, 0.865, 0.2156]")
    make_source(joinpath(dir, "bad.sqlite"), "[1, 2, 3]")
    extract(joinpath(dir, "good.sqlite"), joinpath(dir, "keep.sqlite3"))
    before = read(joinpath(dir, "keep.sqlite3"))
    ok, out = extract(joinpath(dir, "bad.sqlite"), joinpath(dir, "keep.sqlite3"))
    @test !ok && occursin("expected 5 amplitudes", out)
    @test read(joinpath(dir, "keep.sqlite3")) == before
    @test !ispath(joinpath(dir, "keep.sqlite3.part"))
end

@testset "an element with no atomic number is an error, not a dropped element" begin
    dir = mktempdir()
    make_source(joinpath(dir, "z.sqlite"), "[2.31, 1.02, 1.5886, 0.865, 0.2156]")
    execute(joinpath(dir, "z.sqlite"), "DELETE FROM elements")
    ok, out = extract(joinpath(dir, "z.sqlite"), joinpath(dir, "z.out"))
    @test !ok && occursin("no atomic number", out)
    @test !ispath(joinpath(dir, "z.out"))
end

@testset "usage and a missing source" begin
    ok, out = extract("only-one-argument")
    @test !ok && occursin("usage:", out)
    ok, out = extract("/no/such/file", "/tmp/x.sqlite3")
    @test !ok && occursin("no such file", out)
end

@testset "anything but plain numbers in a JSON array is an error" begin
    dir = mktempdir()
    make_source(joinpath(dir, "n.sqlite"), "[2.31, oops, 1.5886, 0.865, 0.2156]")
    ok, out = extract(joinpath(dir, "n.sqlite"), joinpath(dir, "n.out"))
    @test !ok && occursin("is not a number", out)
end
