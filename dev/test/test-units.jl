# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl fits units`: the check that a fitting script converts the deposited q
# to Å⁻¹ exactly when the data are in nm⁻¹.

using Test
using Dev

const U = Dev.Fits.Units

const DAT_NM = " 0.09 45.3 0.2\n 4.69 0.08 0.1\nangular-unit: nanometer\nunit-time: 1\n"
const DAT_PLAIN = " 0.09 45.3 0.2\n 4.69 0.08 0.1\n"
const FIT_A = string(
    "file.pdb Dro:0.025\n 0.0 0.0 0.0 46.4\n",
    " 0.009 45.3 0.2 45.6\n 0.469 0.08 0.1 0.27\n",
)
# the depositor fitted only the low-q part of a curve in Å⁻¹: the ratio (17) is no unit,
# the matching q are
const DAT_WIDE = " 0.025 1 1\n 0.1 1 1\n 0.3 1 1\n 5.0 1 1\n"
const FIT_PART = "x\n 0.0 0.0 0.0 1\n 0.025 1 1 1\n 0.1 1 1 1\n 0.3 1 1 1\n"
const SCRIPT_CONV =
    "x = 1\nqvals, iExp, σ_exp = _readCurve(_DATA_PATH)\n" *
    "qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹\n"
const SCRIPT_PLAIN = "qvals, iExp, σ_exp = _readCurve(_DATA_PATH)\ncheckQAngstrom(qvals)\n"

@testset "footer, q-max and the unit of the data" begin
    @test U.footer_unit(DAT_NM) == :nm
    @test U.footer_unit("angular-unit: angstrom\n") == :angstrom
    @test U.footer_unit(DAT_PLAIN) === nothing
    @test U.footer_unit("angular-unit: furlong\n") === nothing
    @test U.max_q(DAT_PLAIN) == 4.69
    @test U.max_q("only text\n") === nothing
    @test U.max_q(FIT_A) == 0.469
    # the footer wins; without it the ratio decides (10 = nm, 1 = Å); neither is unknown
    @test U.unit_of(DAT_NM, nothing)[1:2] == (:nm, :footer)
    @test U.unit_of(DAT_PLAIN, FIT_A)[1:2] == (:nm, :ratio)
    @test U.unit_of(FIT_A, FIT_A)[1:2] == (:angstrom, :ratio)
    @test U.unit_of(DAT_WIDE, FIT_PART)[1:2] == (:angstrom, :ratio)
    @test U.unit_of(DAT_PLAIN, nothing)[1:2] == (nothing, :unknown)
    # a footer against the opposite ratio is a conflict
    @test U.unit_of("angular-unit: angstrom\n" * DAT_PLAIN, FIT_A)[3] !== nothing
end

@testset "a script's conversion against its data" begin
    @test U.script_converts(SCRIPT_CONV) == true
    @test U.script_converts(SCRIPT_PLAIN) == false
    @test U.script_converts("# NM_INV_PER_ANGSTROM_INV in a comment\n") === nothing
    @test U.script_converts(
        "_readCurve(p)\n# qvals = qvals ./ NM_INV_PER_ANGSTROM_INV\n",
    ) == false
    @test U.check_script(SCRIPT_CONV, DAT_NM, nothing) === nothing
    @test U.check_script(SCRIPT_CONV, DAT_PLAIN, FIT_A) === nothing
    @test occursin("does not divide", U.check_script(SCRIPT_PLAIN, DAT_NM, nothing))
    @test occursin("does not divide", U.check_script(SCRIPT_PLAIN, DAT_PLAIN, FIT_A))
    @test occursin("divides", U.check_script(SCRIPT_CONV, DAT_PLAIN, DAT_PLAIN))
    # unknown unit, or a script that reads q from the .fit: nothing to judge
    @test U.check_script(SCRIPT_PLAIN, DAT_PLAIN, nothing) === nothing
    @test U.check_script("no curve here\n", DAT_NM, nothing) === nothing
end

@testset "bysl fits units on real entries and its command line" begin
    @test U.run(["SASDJX7", "SASDJL6"]) == 0
    @test U.run(["--help"]) == 0
    @test_throws Dev.Common.ToolError U.run(["--nope"])
    @test_throws Dev.Common.ToolError U.run(["SASDNOPE"])
end
