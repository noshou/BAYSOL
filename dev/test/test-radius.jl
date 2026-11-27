# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl fits radius`: the table, the .fit header, the LOG sections, the skip
# rules and the child's output (no BAYSOL and no fit needed).

using Test
using Dev
using Dev.Report

const R = Dev.Fits.Radius

# Absolute tolerance of the checks on computed numbers (the dev tests have no shared one).
const RADIUS_ATOL = 1e-6

const LOG_TEXT = """
datetime\t22-11-2026 23:50:39 -0500

=== SASDMC6 ===
refChi2                 \tCRYSOL 3.235
c1                      \t1.25400

=== fit3_model1 ===
refChi2                 \tFoXS 1.2
c1                      \t1.22200

=== fit4_model1 ===
status                  \tfailed
"""

@testset "fits radius" begin
    rows = [
        (; label = "SASDMC6", rM = 1.153, c1 = 1.254, reference = "CRYSOL", refR0 = 1.5),
        (; label = "SASDVL8", rM = 1.084, c1 = 1.222, reference = "CRYSOL", refR0 = 1.4),
    ]

    @testset "table" begin
        expected = [
            "┌─────────┬─────────────────┬────────┬────────┬───────────┬──────────────┐",
            "│         │       rM        │ BAYSOL │ BAYSOL │ Reference │      r₀      │",
            "│         │ (hydrogenated,  │   c1   │ r₀ =   │           │     (Å)      │",
            "│         │       Å)        │        │ c1·rM  │           │              │",
            "│         │                 │        │  (Å)   │           │              │",
            "├─────────┼─────────────────┼────────┼────────┼───────────┼──────────────┤",
            "│ SASDMC6 │ 1.153           │ 1.254  │ 1.45   │ CRYSOL    │ 1.50         │",
            "├─────────┼─────────────────┼────────┼────────┼───────────┼──────────────┤",
            "│         │                 │        │        │           │ 1.40 (at     │",
            "│ SASDVL8 │ 1.084           │ 1.222  │ 1.32   │ CRYSOL    │ CRYSOL's     │",
            "│         │                 │        │        │           │ lower limit) │",
            "└─────────┴─────────────────┴────────┴────────┴───────────┴──────────────┘",
        ]
        @test R.format_radius_table(rows) == expected
        @test all(l -> length(l) == length(expected[1]), expected)
    end

    @testset ".fit header" begin
        crysol = "Monomer_  Dro:0.075  Ra:1.800  RGT:23.93  Vol: 59086.  Chi^2:34.546"
        @test R.fit_header_r0(crysol) ≈ 1.8 atol = RADIUS_ATOL
        @test R.fit_header_r0("x Ra: 1.62 y\nz") ≈ 1.62 atol = RADIUS_ATOL
        @test R.fit_header_r0("# FoXS  c1 = 1.02  c2 = 2.1") === nothing
        @test R.fit_header_r0("") === nothing
        @test R.r0_limit_note(1.4) == " (at CRYSOL's lower limit)"
        @test R.r0_limit_note(1.4 + 5e-10) == " (at CRYSOL's lower limit)"
        @test R.r0_limit_note(1.8) == " (at CRYSOL's upper limit)"
        @test R.r0_limit_note(1.6) == ""
        @test R.r0_limit_note(1.4 + 1e-6) == ""
        @test R.r0_cell(1.8) == "1.80 (at CRYSOL's upper limit)"
        @test R.r0_cell(1.234) == "1.23"
        @test R.r0_cell(nothing) == "—"
    end

    @testset "LOG sections, tags and c1" begin
        sections = parse_log(LOG_TEXT)
        @test R.section_tag("SASDMC6", sections[1][1]) == ""
        @test R.section_tag("SASDMC6", sections[2][1]) == "fit3_model1"
        @test R.spec_of("SASDMC6", "") == "SASDMC6"
        @test R.spec_of("SASDMC6", "fit3_model1") == "SASDMC6:fit3_model1"
        @test R.run_label("SASDMC6", "SASDMC6") == "SASDMC6"
        @test R.run_label("SASDMC6", "fit3_model1") == "SASDMC6 fit3_model1"
        @test R.log_c1(sections[1][2]) ≈ 1.254 atol = RADIUS_ATOL
        @test R.log_c1(sections[3][2]) === nothing
        @test R.reference_name(sections[1][2]) == "CRYSOL"
        @test R.reference_name(sections[2][2]) == "FoXS"
        @test R.reference_name(sections[3][2]) == "—"
    end

    @testset "child output" begin
        text = join(
            [
                "warning: chatter",
                "SASDMC6\t1.153\tok\tSASDMC6_fit1.fit\t-\tMonomer_ Ra:1.5 | b\tcached",
                "SASDMC6:fit3_model1\t1.084\tok\tf.fit\tFoXS\t# FoXS | x\thydrogenated",
                "SASDMC6:fit4_model1\t-\tno atoms\tin the structure",
                "SASDMC6:fit5_model1\t-\tnoRa",
            ],
            "\n",
        )
        c = R.parse_child_output(text)
        @test length(c) == 4
        @test c["SASDMC6"].ok && !c["SASDMC6"].noRa
        @test c["SASDMC6"].rM ≈ 1.153 atol = RADIUS_ATOL
        @test c["SASDMC6"].fitFile == "SASDMC6_fit1.fit"
        @test c["SASDMC6"].software == ""
        @test c["SASDMC6"].status == "cached"
        @test c["SASDMC6:fit3_model1"].status == "hydrogenated"
        @test R.fit_header_r0(c["SASDMC6"].header) ≈ 1.5 atol = RADIUS_ATOL
        @test c["SASDMC6:fit3_model1"].software == "FoXS"
        @test !c["SASDMC6:fit4_model1"].ok && !c["SASDMC6:fit4_model1"].noRa
        @test c["SASDMC6:fit4_model1"].error == "no atoms in the structure"
        @test c["SASDMC6:fit5_model1"].noRa && !c["SASDMC6:fit5_model1"].ok
    end

    @testset "rows, dropping and skipping" begin
        sections = parse_log(LOG_TEXT)
        entries = [(; id = "SASDMC6", title = t, run = r) for (t, r) in sections]
        entries = vcat(entries, [(; id = "SASDMC6", title = "fit9", run = sections[1][2])])
        entries = vcat(entries, [(; id = "SASDMC6", title = "fit8", run = sections[1][2])])
        c = R.parse_child_output(
            join(
                [
                    "SASDMC6\t1.153\tok\ta.fit\t-\tMonomer_ Ra:1.500\tcached",
                    "SASDMC6:fit3_model1\t1.084\tok\tb.fit\tFoXS\t# FoXS\thydrogenated",
                    "SASDMC6:fit4_model1\t1.0\tok\tc.fit\t-\t\tcached",
                    "SASDMC6:fit8\t-\tnoRa",
                ],
                "\n",
            ),
        )
        rows, skipped, dropped = R.build_rows(entries, c)
        # fit3 has an ok line but no Ra in its header: dropped, not a row
        @test [r.label for r in rows] == ["SASDMC6"]
        @test rows[1].refR0 ≈ 1.5 atol = RADIUS_ATOL
        @test rows[1].reference == "CRYSOL" && rows[1].status == "cached"
        @test dropped == 2    # fit3 (no Ra in the header) and fit8 (noRa)
        # fit4: no c1 (checked before the child's line); fit9: the child never answered
        @test [s.label for s in skipped] == ["SASDMC6 fit4_model1", "SASDMC6 fit9"]
        @test occursin("no c1", skipped[1].reason)
        @test occursin("no line", skipped[2].reason)
        # a failing child line skips the run, with the child's reason
        rows2, skipped2, dropped2 = R.build_rows(
            entries[1:1],
            R.parse_child_output("SASDMC6\t-\tboom"),
        )
        @test isempty(rows2) && skipped2[1].reason == "boom" && dropped2 == 0
        text = R.output_text(rows, skipped, dropped)
        @test occursin("\nskipped:\n    SASDMC6 fit4_model1: ", text)
        @test endswith(
            text,
            "dropped 2 runs without a reference r₀ (no Ra in the .fit header)\n",
        )
        @test !occursin("skipped:", R.output_text(rows, [], 1))
        @test occursin("dropped 1 run without", R.output_text(rows, [], 1))
        @test !occursin("dropped", R.output_text(rows, [], 0))
    end

    @testset "cache line" begin
        mk(s) = (; status = s)
        @test R.cache_line([mk("cached"), mk("cached"), mk("hydrogenated")]) ==
              "2 cached, 1 hydrogenated"
        @test R.cache_line([]) == "0 cached, 0 hydrogenated"
    end

    @testset "r0 = c1 * rM" begin
        @test R.baysol_r0(1.254, 1.153) ≈ 1.445862 atol = RADIUS_ATOL
        @test R.baysol_r0(1.222, 1.084) ≈ 1.324648 atol = RADIUS_ATOL
        # the cell rounds to two decimals, so a last-digit change does not move it
        @test round(R.baysol_r0(1.254, 1.153); digits = 2) == 1.45
    end

    @testset "command" begin
        cmd = R.child_command(["SASDMC6"])
        @test any(endswith("radius.jl"), cmd) && last(cmd) == "SASDMC6"
        @test any(startswith("--project="), cmd)
    end
end
