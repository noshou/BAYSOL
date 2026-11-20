# SPDX-License-Identifier: LGPL-3.0-or-later

# The species ladders of the buffer templates (`tui/assets/data/buffer_templates.json`)
# against the solute table. The speciation itself (fractions from pH and the pK of each
# step, Davies activities, the counter-ion that balances the charge) runs in the TUI
# (`tui/src/store/buffer-templates.ts`, tested in `tui/test/template-defs.test.ts`) for
# any number of steps; what a Julia fit needs from it is that every species row it
# writes is a real row of the solute table with the right charge and protonation. A
# template with `speciesRows` (glycine, phosphate, citrate, carbonate, bis-tris
# propane, ...) lists one name per species, most protonated first, so the rows must
# resolve in `nonbio_lookup.json`, carry the charge the ladder gives (`zAcid` of the
# first step, then every `zBase`), lose exactly one hydrogen per step and keep the same
# electron count (a proton carries none), which is what `ϕ°` assumes. The glycylglycine
# ladder is made of `Polymer` rows (`polymers.tsv`), checked on its own below. Two
# ladders are written differently on purpose and only have to resolve: borate (the base is
# tetrahydroxyborate, boric acid plus a water) and cacodylate (the base row is the
# sodium salt).
include(joinpath(@__DIR__, "..", "testsetup.jl"))

const SPECIES_TABLES = BAYSOL.BulkElectronDensity
const LADDER_NOT_PROTONS = ["borate", "cacodylate"]
const LADDER_POLYMERS = ["glycylglycine"]
const SPECIES_JSON = SPECIES_TABLES.JSON3
const TEMPLATES_FILE = normpath(
    joinpath(pathof(BAYSOL), "..", "..", "tui", "assets", "data", "buffer_templates.json"),
)
const POLYMER_TSV = normpath(
    joinpath(pathof(BAYSOL), "..", "bulk-electron-density", "polymers", "polymers.tsv"),
)
const SPECIES_TSV = normpath(
    joinpath(
        pathof(BAYSOL), "..", "bulk-electron-density", "non-biological",
        "nonbiological.tsv",
    ),
)

# charge and number of hydrogens of each non-rejected row of the table, by iupac key
# (lowercase); a species may appear in several rows (several sources) with one formula
function speciesFormulas()
    out = Dict{String,Tuple{Int,Int}}()
    lines = readlines(SPECIES_TSV)
    for l in lines[2:end]
        f = split(l, '\t'; keepempty = true)
        f[7] == "rejected" && continue
        hydrogens = something(match(r"H(\d*)(?![a-z])", f[3]), (; captures = ["0"]))
        h = hydrogens.captures[1] == "" ? 1 : parse(Int, hydrogens.captures[1])
        out[lowercase(f[2])] = (parse(Int, f[4]), h)
    end
    return out
end

# charge and hydrogens of each row of `polymers.tsv` by its iupac key (lowercase)
function polymerFormulas()
    out = Dict{String,Tuple{Int,Int}}()
    for l in readlines(POLYMER_TSV)[2:end]
        f = split(l, '\t'; keepempty = true)
        length(f) < 8 && continue
        hydrogens = match(r"H(\d*)(?![a-z])", f[3])
        hydrogens === nothing && continue
        out[lowercase(f[2])] = (parse(Int, f[4]), parse(Int, hydrogens.captures[1]))
    end
    return out
end

@testset "buffer template species ladders" begin
    templates = SPECIES_JSON.read(read(TEMPLATES_FILE, String))
    lookup = SPECIES_TABLES.NONBIO_LOOKUP
    solutes = SPECIES_TABLES._SOLUTES
    formulas = speciesFormulas()
    laddered = [t for t in templates if haskey(t, :speciesRows)]

    @testset "the polyprotic templates all have a ladder" begin
        ids = Set(String(t.id) for t in laddered)
        # every buffer with more than one step has species rows (a template without
        # them writes one row for the whole molarity, wrong for a two-pK buffer)
        multi = [t for t in templates if t.kind == "buffer" && length(t.groups) > 1]
        @test !isempty(multi)
        @test all(t -> String(t.id) in ids || !get(t, :available, true), multi)
        @test "bis-tris-propane" in ids
        @test "glycylglycine" in ids
    end

    for t in laddered
        String(t.id) in LADDER_POLYMERS && continue
        groups = t.groups
        names = String.(t.speciesRows)
        charges = [Int(groups[1].zAcid); [Int(g.zBase) for g in groups]]
        @testset "$(t.id)" begin
            @test length(names) == length(groups) + 1
            targets = [lowercase(get(lookup, lowercase(n), "")) for n in names]
            @test all(!isempty, targets)
            @test all(x -> haskey(solutes, x), targets)
            @test allunique(targets)
            if String(t.id) in LADDER_NOT_PROTONS
                @test all(x -> haskey(formulas, x), targets)
            elseif all(x -> haskey(formulas, x), targets)
                @test [formulas[x][1] for x in targets] == charges
                # one hydrogen less per step
                @test diff([formulas[x][2] for x in targets]) == fill(-1, length(groups))
                # a proton has no electrons: the species share one electron count
                @test length(unique(solutes[x][1] for x in targets)) == 1
            else
                @test false
            end
            # the charge steps are unit steps
            @test all(d -> d == -1, diff(charges))
        end
    end

    @testset "glycylglycine: three Polymer species, two pK" begin
        t = only(t for t in templates if t.id == "glycylglycine")
        @test get(t, :available, false)
        @test length(t.groups) == 2
        @test [Int(g.zAcid) for g in t.groups] == [1, 0]
        @test [Int(g.zBase) for g in t.groups] == [0, -1]
        names = String.(t.speciesRows)
        @test length(names) == 3
        formulas = polymerFormulas()
        poly = SPECIES_TABLES.POLYMER_LOOKUP
        grades = SPECIES_TABLES._POLYMERS
        keys = [lowercase(get(poly, lowercase(n), lowercase(n))) for n in names]
        @test all(k -> haskey(grades, k), keys)
        @test allunique(keys)
        # the charges of the ladder, one hydrogen less per step, one electron count
        @test [formulas[k][1] for k in keys] == [1, 0, -1]
        @test diff([formulas[k][2] for k in keys]) == [-1, -1]
        @test length(unique(grades[k][1] for k in keys)) == 1
        # the volumes: zwitterion measured 76.3, +1 and -1 predicted (the estimate the
        # owner accepted, 2026-11-18)
        @test [grades[k][2] for k in keys] == [84.7, 76.3, 80.4]
        # the row the template writes is the fixed grade, not a parsed peptide: the
        # name `glycylglycine` is read as the peptide GG (termini titrated with pH on
        # top of the ladder), the IUPAC spelling of the template is not
        @test SPECIES_TABLES._polymer_family_ϕ°("glycylglycine") !== nothing
        for n in names
            @test SPECIES_TABLES._polymer_family_ϕ°(n) === nothing
            key = lowercase(get(poly, lowercase(n), n))
            @test SPECIES_TABLES._polymer_ϕ°(n)[2] == grades[key][2]
        end
    end

    @testset "bis-tris propane: three species, two pK" begin
        t = only(t for t in templates if t.id == "bis-tris-propane")
        @test length(t.groups) == 2
        @test [Int(g.zAcid) for g in t.groups] == [2, 1]
        @test [Int(g.zBase) for g in t.groups] == [1, 0]
        @test [lowercase(String(n)) for n in t.speciesRows] ==
              ["bis-tris propane dication", "bis-tris propane cation", "bis-tris propane"]
        # the aliases a script may use for each species reach the same rows
        @test lookup["btp(2+)"] == lookup["bis-tris propane dication"]
        @test lookup["bis-tris propane monocation"] == lookup["bis-tris propane cation"]
        @test lookup["btp"] == lookup["bis-tris propane"]
    end
end
