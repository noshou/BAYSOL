# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises what a relocated app (a sysimage built elsewhere) relies on: the bundled
# tables (`Runtime.memoryDb`, no data folder) and the `REVISION` file that a packaged
# copy of the sources carries in place of a git checkout (`Pipeline._logRevision`).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Runtime: memoryDb
using BAYSOL.Runtime: DBInterface
using BAYSOL.Pipeline: _logRevision

@testset "Packaging" begin

    @testset "the bundled tables are inside the package, no data folder" begin
        # a relocated app (no source tree, no BAYSOL_DATA) reads them from the image
        withenv("BAYSOL_DATA" => joinpath(tempdir(), "nowhere")) do
            @test BAYSOL.Scattering.f0("c", 0.1) > 0
            @test BAYSOL.MolecularStructure.ionRadius("fe3+") !== nothing
            @test haskey(BAYSOL.MolecularStructure._readComponents(), "ALA")
        end
    end

    @testset "memoryDb: a database from bytes, read-only; garbage is refused" begin
        bytes = BAYSOL.Scattering._DB_BYTES
        db = memoryDb(bytes)
        try
            n = 0
            for r in DBInterface.execute(db, "SELECT ion FROM waasmaier")
                n += 1
            end
            @test n > 0
            @test_throws Exception DBInterface.execute(db, "CREATE TABLE t(x)")
        finally
            DBInterface.close!(db)
        end
        @test_throws ErrorException memoryDb(rand(UInt8, 4096))
    end

    @testset "_logRevision: BAYSOL_REVISION (the launcher's) wins" begin
        withenv("BAYSOL_REVISION" => "abc1234") do
            @test _logRevision() == "abc1234"
        end
    end

    @testset "_logRevision: the REVISION file of a packaged copy, else git" begin
        file = joinpath(pkgdir(BAYSOL), "REVISION")
        rev = _logRevision()
        @test rev isa String && !isempty(rev)
        # a packaged copy has the file, a checkout does not; never touch the real folder
        isfile(file) && @test rev == strip(read(file, String))
    end
end
