// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { displayWidth } from "../src/core/text.js"
import {
    type AddEvent,
    AddFlow,
    type AddKind,
    basisNote,
    boxTop,
    bufferRow,
    countsText,
    DROPDOWN_ROWS,
    type DropdownStep,
    entries,
    entryTag,
    familyMatch,
    formatNumber,
    itemText,
    NO_MATCH,
    opensBelow,
    type PromptStep,
    paramsCell,
    parseField,
    pathHints,
    pathProblem,
    rowNote,
} from "../src/store/add-flow.js"
import { rowProblem } from "../src/store/buffer.js"
import type { CustomEntry } from "../src/store/custom.js"
import { Drafts } from "../src/store/draft.js"
import { MAX_ROWS } from "../src/store/limits.js"
import { resolveBuiltin } from "../src/store/solute-index.js"
import type { Solute } from "../src/store/solutes.js"
import { fixture as sharedFixture } from "./support/fixtures.js"

// ---- fixtures -------------------------------------------------------------------------

/** The fixture the Julia loader is tested against too. */
const fixture = sharedFixture("buffer/buffer.json").solutes as Record<string, unknown>[]

/** The fixture row of that name, as a solute of the table (`sigmaMM`). */
function fixtureRow(name: string): Solute {
    const row = fixture.find((r) => r.name === name)
    assert.ok(row, name)
    const { "sigma-mM": sigmaMM, ...rest } = row
    return { ...rest, sigmaMM } as Solute
}

const nacet: CustomEntry = {
    kind: "nonbiological",
    name: "N-acetylcysteine ethyl ester",
    formula: "C7H13NO3S",
    z: 102,
    pmv: 118.4,
    sigma: 4.0,
}
const ammonium: CustomEntry = {
    kind: "nonbiological",
    name: "amm-nitrate-x",
    formula: "NH4+ NO3-",
    z: 32,
    pmv: 46.7,
    sigma: null,
}
const chain1: CustomEntry = {
    kind: "polymer",
    name: "chain-1",
    "z-ends": 10,
    "pmv-ends": 19.24,
    "sigma-ends": null,
    units: [{ label: "A", formula: "C2H4O", z: 24, slope: 36.73, sigma: null }],
}
const chain4: CustomEntry = {
    kind: "polymer",
    name: "chain-4",
    "z-ends": 5,
    "pmv-ends": 7.0,
    "sigma-ends": 0.5,
    units: [
        { label: "A", formula: "C2H4O", z: 10, slope: 1.0, sigma: null },
        { label: "B", formula: "C3H6O", z: 20, slope: 2.0, sigma: 0.1 },
        { label: "C", formula: "C4H8O", z: 30, slope: 3.0, sigma: null },
        { label: "D", formula: "C5H10O", z: 40, slope: 4.0, sigma: 0.2 },
    ],
}
const customs = [nacet, ammonium, chain1, chain4]

/** A folder to write files in. */
const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

const empty = () => new Drafts<Solute>()

/** The events of typing `text`, the whole text each time as a screen's field holds it. */
function typing(text: string): AddEvent[] {
    return [{ type: "text", text }]
}
const submit: AddEvent = { type: "submit" }
const down: AddEvent = { type: "move", delta: 1 }
const esc: AddEvent = { type: "cancel" }

/** Forwards the events (a string is typed whole) and returns the flow. */
function feed(flow: AddFlow, ...inputs: (string | AddEvent)[]): AddFlow {
    for (const input of inputs) {
        for (const e of typeof input === "string" ? typing(input) : [input]) flow.send(e)
    }
    return flow
}

/** The flow of an add key over `table`. */
const add = (kind: AddKind = "nonbio", table = empty()) =>
    AddFlow.add(table, kind, { customs })

/** The solutes of the table. */
const rows = (flow: AddFlow) => flow.table.rows.map((_, i) => flow.table.value(i) as Solute)

/** The only row. */
function onlyRow(flow: AddFlow): Solute {
    assert.equal(rows(flow).length, 1)
    return rows(flow)[0]
}

/** Whether a row is the fixture row of that name but for its name, and valid. */
function sameAsFixture(row: Solute, name: string): void {
    const { name: _a, ...got } = bufferRow(row)
    const { name: _b, ...want } = bufferRow(fixtureRow(name))
    assert.deepEqual(got, want)
    assert.equal(rowProblem(bufferRow(row)), undefined)
}

const dropdown = (flow: AddFlow) => flow.step as DropdownStep
const prompt = (flow: AddFlow) => flow.step as PromptStep

/** The field a flow is typing into. */
function field(flow: AddFlow): string | undefined {
    const s = flow.state
    return s.kind === "edit" ? s.field : undefined
}

// ---- numbers --------------------------------------------------------------------------

test("numbers", () => {
    assert.equal(formatNumber(200.0), "200")
    assert.equal(formatNumber(1.0e-5), "0.00001")
    assert.equal(formatNumber(null), "")
    assert.deepEqual(parseField("sigmaMM", " 0.5 "), { value: 0.5 })
    assert.ok("error" in parseField("mM", "0"))
    assert.deepEqual(parseField("mM", "-1"), { error: "mM must be > 0" })
    assert.deepEqual(parseField("sigmaMM", "-1"), { error: "not below 0" })
    assert.deepEqual(parseField("sigmaMM", ""), { error: "a number, please" })
    assert.deepEqual(parseField("sigmaMM", "1e999"), { error: "a number, please" })
    assert.deepEqual(parseField("name", " x "), { value: "x" })
    assert.deepEqual(parseField("name", " "), { error: "name needed" })
})

// ---- the dropdown ---------------------------------------------------------------------

test("the entries of each add key", () => {
    assert.deepEqual(entries("nonbio", "", []), [])
    assert.deepEqual(entries("polymer", "", []), [])
    assert.equal(entries("nonbio", "tris", [])[0].name, "tris")
    const queries = ["a", "e", "peg", "chain", "ficoll", "dna", "n", "co"]
    const kinds = (k: "nonbio" | "polymer") =>
        new Set(queries.flatMap((q) => entries(k, q, customs).map((e) => e.kind)))
    const nonbio = kinds("nonbio")
    assert.ok(nonbio.size > 0)
    for (const k of nonbio) assert.ok(["nonbiological", "custom-nonbio"].includes(k), k)
    const polymer = kinds("polymer")
    assert.ok(polymer.size > 0)
    for (const k of polymer) {
        assert.ok(["polymer", "polymer-family", "custom-polymer"].includes(k), k)
    }
    // a name is found only under the key of its kind
    assert.equal(entries("nonbio", "nacl", [])[0].name, "nacl")
    assert.deepEqual(entries("polymer", "nacl", []), [])
    assert.deepEqual(entries("nonbio", "ficoll 70", []), [])
    assert.equal(entries("polymer", "peg", [])[0].kind, "polymer-family")
    // tags
    assert.equal(entryTag(entries("nonbio", "nacl", [])[0]), "solute")
    assert.equal(entryTag(entries("polymer", "peg", [])[0]), "family")
    assert.equal(entryTag(entries("polymer", "ficoll 70", [])[0]), "polymer")
    assert.equal(entryTag(entries("polymer", "chain-4", customs)[0]), "custom")
    assert.equal(entryTag(entries("nonbio", "amm-nitrate-x", customs)[0]), "custom")
    // the custom entries carry their entry
    const e = entries("nonbio", "n-acetylcysteine ethyl ester", customs)[0]
    assert.equal(e.kind, "custom-nonbio")
    assert.deepEqual(e.entry, nacet)
    assert.equal(entries("polymer", "chain-1", customs)[0].kind, "custom-polymer")
    assert.deepEqual(entries("nonbio", "chain-1", customs), [])
})

test("the name dropdown keys", () => {
    const f = () => add("polymer")
    // typing narrows, the first entry is highlighted
    let d = dropdown(feed(f(), "chain"))
    assert.equal(d.typed, "chain")
    assert.equal(d.index, 0)
    assert.equal(d.items[0].text, "chain-1")
    // up and down wrap
    const n = d.items.length
    const flow = feed(f(), "chain")
    d = dropdown(feed(flow, { type: "move", delta: -1 }))
    assert.equal(d.index, n - 1)
    for (let k = 0; k < n; k++) feed(flow, down)
    assert.equal(dropdown(flow).index, n - 1)
    // Tab completes to the highlighted name; with no entry it is idle
    assert.equal(dropdown(feed(f(), "chai", { type: "complete" })).typed, "chain-1")
    assert.equal(dropdown(feed(f(), { type: "complete" })).typed, "")
    // a shorter text narrows again
    assert.equal(dropdown(feed(f(), "chai", "cha")).typed, "cha")
    // Escape drops the row
    const out = feed(f(), esc)
    assert.ok(out.done)
    assert.equal(rows(out).length, 0)
    // a typo, or nothing typed, finds nothing: Enter takes nothing
    for (const flow of [feed(f(), "qqqqzzzz"), f()]) {
        feed(flow, submit)
        assert.equal(dropdown(flow).problem, "no match")
        assert.equal(dropdown(flow).items.length, 0)
        assert.equal(dropdown(feed(flow, down)).index, 0)
    }
    // the text typed stops at 60 characters
    const long = feed(f(), "a".repeat(60), "a".repeat(61))
    assert.equal(dropdown(long).typed, "a".repeat(60))
    assert.equal(dropdown(long).problem, "name too long (60 at most)")
})

test("a dropdown line and the status row", () => {
    const e = {
        name: "a-rather-long-solute-name-that-will-not-fit-in-the-dropdown-at-all",
        tag: "solute",
        kind: "nonbiological",
    }
    const others = [
        e,
        { name: "ficoll 70", kind: "polymer", tag: "polymer" },
        { name: "x", tag: "custom" },
        { name: "peg", kind: "polymer-family", tag: "polymer" },
    ]
    for (const room of [20, 45, 60]) {
        for (const entry of others) {
            assert.equal(displayWidth(itemText(entry, room)), room, `${room} ${entry.name}`)
        }
    }
    assert.ok(itemText(e, 45).endsWith("…  solute"))
    assert.ok(
        itemText({ name: "peg", kind: "polymer-family", tag: "polymer" }, 30).endsWith(
            "family",
        ),
    )
    assert.equal(dropdown(add("nonbio")).status, "type a solute name")
    assert.equal(dropdown(add("polymer")).status, "type a polymer name")
    assert.equal(dropdown(feed(add("polymer"), "qqqqzzzz")).status, NO_MATCH)
    assert.equal(dropdown(feed(add("polymer"), "peg")).status, undefined)
    assert.ok(NO_MATCH.length <= 40)
})

test("the basis", () => {
    assert.equal(basisNote("per monomer unit"), "mM per monomer unit")
    assert.equal(basisNote("per 1000 Da"), "mM per 1000 Da")
    assert.equal(basisNote(null), undefined)
    assert.equal(dropdown(feed(add("polymer"), "ficoll 70")).note, "mM per 1000 Da")
    assert.equal(dropdown(feed(add("nonbio"), "tris")).note, undefined)
    assert.equal(dropdown(feed(add("polymer"), "peg")).note, undefined, "a family has none")
    assert.equal(rowNote({ kind: "polymer", arg: "ficoll 70" } as Solute), "mM per 1000 Da")
    assert.equal(rowNote({ kind: "polymer", arg: "PEG n=22" } as Solute), undefined)
    assert.equal(rowNote({ kind: "nonbiological", arg: "nacl" } as Solute), undefined)
})

test("placement", () => {
    // the body of the real tables starts on line 3 and is 15 rows tall
    assert.equal(DROPDOWN_ROWS, 8)
    assert.ok(opensBelow(0, 15))
    assert.ok(opensBelow(6, 15))
    assert.ok(!opensBelow(7, 15))
    assert.equal(boxTop(0, 15, 8, 3), 4)
    assert.equal(boxTop(6, 15, 8, 3), 10)
    assert.equal(boxTop(7, 15, 8, 3), 2)
    assert.equal(boxTop(14, 15, 3, 3), 3 + 14 - 3)
    assert.equal(boxTop(0, 18, 8, 2), 3)
})

// ---- the params of a row --------------------------------------------------------------

test("params of a row", () => {
    const w = 22
    const p = (name: string) => paramsCell(fixtureRow(name), w)
    const na = { text: "n/a", align: "center" }
    assert.deepEqual(p("NaCl"), na)
    assert.deepEqual(p("NACET"), na)
    assert.deepEqual(paramsCell({ kind: "polymer", arg: "ficoll 70" }, w), na)
    assert.deepEqual(p("PEG 3350"), { text: "Mn=3350", align: "left" })
    assert.deepEqual(p("PEG 22"), { text: "n=22", align: "left" })
    assert.deepEqual(p("Pluronic"), { text: "nEO=100 nPO=65", align: "left" })
    assert.deepEqual(p("one-unit chain"), { text: "nA=22", align: "left" })
    assert.deepEqual(p("four-unit chain"), { text: "nA=3 nB=4 nC=5 nD=6", align: "left" })
    assert.deepEqual(p("primer-A"), { text: "ACGTTGCA (8 nt)", align: "left" })
    assert.equal(p("carrier").text, "MKTAYIAKQR (10 aa)")
    const long = paramsCell({ kind: "dna", arg: "ACGT".repeat(200) }, w).text
    assert.equal(long.length, w)
    assert.ok(long.endsWith("(800 nt)"))
    // a row that is not complete yet does not break the cell
    assert.equal(paramsCell({ kind: "polymer", arg: "" }, w).text, "n/a")
    assert.equal(paramsCell({ kind: "custom-polymer" }, w).text, "")
    assert.equal(countsText([{ label: "A" }, { label: "B" }], [1.5]), "nA=1.5")
})

test("the family of an arg", () => {
    assert.deepEqual(familyMatch("PEG n=22")?.values, { n: "22" })
    assert.deepEqual(familyMatch("peg 3350")?.values, { Mn: "3350" })
    assert.deepEqual(familyMatch("Brij nC=12 nEO=9")?.values, { nC: "12", nEO: "9" })
    assert.equal(familyMatch("PEG 3350")?.formIndex, 1)
    assert.equal(familyMatch("ficoll 70"), undefined)
    assert.equal(familyMatch("PEG 3350 extra"), undefined)
    assert.equal(familyMatch(""), undefined)
    assert.equal(familyMatch(null), undefined)
})

// ---- paths ----------------------------------------------------------------------------

test("paths", () => {
    const root = tempRoot()
    writeFileSync(join(root, "a.fasta"), ">a\nACGT\n")
    assert.equal(pathProblem(""), "type a path first!")
    assert.equal(pathProblem("a.fasta"), "use a full path")
    assert.equal(pathProblem(join(root, "none.fa")), "no such file")
    assert.equal(pathProblem(root), "that is a folder")
    assert.equal(pathProblem(join(root, "a.fasta")), undefined)
    for (const m of [
        "type a path first!",
        "use a full path",
        "no such file",
        "that is a folder",
    ]) {
        assert.ok(m.length <= 22)
    }
    writeFileSync(join(root, "b.txt"), "x")
    writeFileSync(join(root, "c.FQ"), "@a\nA\n+\nI\n")
    mkdirSync(join(root, "dir"))
    assert.deepEqual(pathHints(`${root}/`), ["dir/", "a.fasta", "c.FQ"])
    assert.deepEqual(pathHints(`${root}/a`), ["a.fasta"])
})

// ---- the steps of the flow, row by row against the fixture ----------------------------

test("non-biological solutes and grades", () => {
    let flow = feed(add(), "nacl", submit)
    assert.equal(field(flow), "mM")
    assert.equal(prompt(flow).label, "mM")
    flow = feed(flow, "200", submit)
    assert.equal(field(flow), "sigmaMM")
    flow = feed(flow, "10", submit)
    const row = onlyRow(flow)
    assert.ok(flow.done)
    assert.equal(row.name, "nacl", "the picked name is the row's name")
    sameAsFixture(row, "NaCl")
    assert.equal(flow.table.mark(0), "*", "a draft, nothing saved")
    assert.equal(flow.cursor, 0)

    const grade = onlyRow(
        feed(add("polymer"), "ficoll 70", submit, "0.05", submit, "0.003", submit),
    )
    assert.deepEqual(grade, {
        kind: "polymer",
        name: "ficoll 70",
        arg: resolveBuiltin("ficoll 70")?.target,
        mM: 0.05,
        sigmaMM: 0.003,
    })
    assert.equal(rowProblem(bufferRow(grade)), undefined)
    assert.deepEqual(paramsCell(grade, 22), { text: "n/a", align: "center" })
})

test("polymer families", () => {
    // PEG by n: a choice of the forms first, then the number in the params cell
    let flow = feed(add("polymer"), "peg", submit)
    assert.equal(dropdown(flow).label, "form")
    flow = feed(flow, submit)
    assert.equal(field(flow), "params")
    assert.equal(prompt(flow).note, "units n", "the prompt is in the border note")
    flow = feed(flow, "22", submit)
    assert.equal(field(flow), "mM")
    sameAsFixture(onlyRow(feed(flow, "0.1", submit, "0.01", submit)), "PEG 22")
    // PEG by Mn: the second form
    flow = feed(add("polymer"), "peg", submit, down, submit)
    assert.equal(prompt(flow).note, "Mn (g/mol)")
    sameAsFixture(
        onlyRow(feed(flow, "3350", submit, "0.05", submit, "0.003", submit)),
        "PEG 3350",
    )
    // two arguments: both asked, shown as typed
    flow = feed(add("polymer"), "pluronic", submit)
    assert.equal(prompt(flow).note, "ethylene oxide units nEO")
    flow = feed(flow, "100", submit)
    assert.equal(prompt(flow).note, "propylene oxide units nPO")
    assert.equal(prompt(feed(flow, "6")).shown, "nEO=100 nPO=6")
    assert.equal(prompt(flow).cell.column, 3)
    sameAsFixture(
        onlyRow(feed(flow, "65", submit, "0.01", submit, "0.001", submit)),
        "Pluronic",
    )
    // an error of the family stays in the cell and says why
    flow = feed(add("polymer"), "peg", submit, submit, "1", submit)
    assert.equal(prompt(flow).problem, "n: at least 2")
    assert.equal(field(flow), "params")
    assert.equal(prompt(flow).typed, "1")
    assert.equal(prompt(feed(flow, "x", submit)).problem, "n: not a number")
    assert.equal(field(feed(flow, "5", submit)), "mM")
    // dextran by Mn below 1000 says it counts as kDa, while mM is typed
    flow = feed(add("polymer"), "dextran", submit, down, submit, "40", submit)
    assert.equal(field(flow), "mM")
    assert.equal(prompt(flow).note, "below 1000 counts as kDa")
    assert.equal(onlyRow(feed(flow, "1", submit, "0.1", submit)).arg, "dextran 40")
    flow = feed(add("polymer"), "dextran", submit, down, submit, "40", submit, "1", submit)
    assert.equal(prompt(flow).note, undefined, "the note goes with the mM cell")
    flow = feed(add("polymer"), "dextran", submit, down, submit, "40000", submit)
    assert.equal(prompt(flow).note, undefined)
})

test("custom solutes", () => {
    // a custom non-biological solute stores a snapshot of the entry
    const row = onlyRow(
        feed(add(), "n-acetylcysteine ethyl ester", submit, "5", submit, "0.1", submit),
    )
    sameAsFixture({ ...row, custom: nacet.name } as Solute, "NACET")
    assert.deepEqual(row, {
        kind: "custom-nonbio",
        custom: "N-acetylcysteine ethyl ester",
        z: 102,
        pmv: 118.4,
        "sigma-pmv": 4.0,
        name: "N-acetylcysteine ethyl ester",
        mM: 5,
        sigmaMM: 0.1,
    })
    // a blank sigma of the entry is kept as null
    const amm = onlyRow(feed(add(), "amm-nitrate-x", submit, "10", submit, "0.2", submit))
    assert.equal(amm["sigma-pmv"], null)
    assert.ok("sigma-pmv" in amm)
    // a custom polymer asks the count of each unit in the params cell
    let flow = feed(add("polymer"), "chain-4", submit)
    assert.equal(field(flow), "params")
    assert.equal(prompt(flow).note, "nA")
    flow = feed(flow, "3", submit, "4", submit)
    assert.equal(prompt(flow).note, "nC")
    assert.equal(prompt(feed(flow, "5")).shown, "nA=3 nB=4 nC=5")
    flow = feed(flow, "5", submit, "6", submit)
    assert.equal(field(flow), "mM")
    sameAsFixture(onlyRow(feed(flow, "0.01", submit, "0.0001", submit)), "four-unit chain")
    // one unit
    const one = onlyRow(
        feed(
            add("polymer"),
            "chain-1",
            submit,
            "22",
            submit,
            "0.01",
            submit,
            "0.0001",
            submit,
        ),
    )
    sameAsFixture(one, "one-unit chain")
    assert.deepEqual(one.counts, [22])
    // an entry that does not make a valid row is refused with a note
    const bad = { ...nacet, z: null, name: "broken" }
    const refused = feed(
        AddFlow.add(empty(), "nonbio", { customs: [bad] }),
        "broken",
        submit,
    )
    assert.equal(dropdown(refused).problem, "custom entry invalid")
    assert.equal(refused.state.kind, "name")
    // a counts of zero is refused
    assert.equal(
        prompt(feed(add("polymer"), "chain-1", submit, "0", submit)).problem,
        "must be > 0",
    )
    assert.equal(
        prompt(feed(add("polymer"), "chain-1", submit, "x", submit)).problem,
        "a number, please",
    )
})

/** A file in `dir`, its path. */
function seqFile(dir: string, name: string, text: string): string {
    const path = join(dir, name)
    writeFileSync(path, text)
    return path
}

/** The flow of an add key of a sequence, at its path prompt. */
function toPath(kind: "dna" | "rna" | "protein", table = empty()): AddFlow {
    if (kind === "protein") return add("protein", table)
    return feed(add("nucleotide", table), ...(kind === "rna" ? [down] : []), submit)
}

test("sequences from files", () => {
    const root = tempRoot()
    const dna = seqFile(root, "primer.fasta", ">p1\nACGTTGCA\n")
    const two = seqFile(root, "two.fa", ">r1 first\nAC\nGT\n>r2\nGGCC\n")
    const rna = seqFile(root, "guide.fa", ">g1\nACGUUGCA\n")
    const prot = seqFile(root, "carrier.fa", ">sp|P1\nMKTAYIAKQR\n")
    const fq = seqFile(root, "reads.fastq", "@q1\nACGT\n+\nIIII\n@q2\nTTGA\n+\nIIII\n")
    // DNA: the choice, a path, then mM and +- once
    let flow = toPath("dna")
    assert.equal(flow.state.kind, "path")
    assert.equal(dropdown(flow).label, "path")
    flow = feed(flow, dna, submit)
    assert.equal(field(flow), "mM")
    const made = onlyRow(feed(toPath("dna"), dna, submit, "0.01", submit, "0.001", submit))
    sameAsFixture(made, "primer-A")
    assert.equal(made.name, "p1", "the record id names the row")
    assert.equal(
        onlyRow(feed(toPath("dna"), dna, submit, "1", submit, "0", submit)).source,
        "primer.fasta",
    )
    // RNA and protein
    sameAsFixture(
        onlyRow(feed(toPath("rna"), rna, submit, "0.02", submit, "0.002", submit)),
        "guide",
    )
    const p = onlyRow(
        feed(toPath("protein"), prot, submit, "0.02", submit, "0.002", submit),
    )
    sameAsFixture(p, "carrier")
    assert.equal(p.name, "sp|P1")
    // several records: one row each, mM and +- for all
    const many = feed(toPath("dna"), two, submit, "1.5", submit, "0.1", submit)
    assert.deepEqual(
        rows(many).map((r) => [r.name, r.arg]),
        [
            ["r1", "ACGT"],
            ["r2", "GGCC"],
        ],
    )
    assert.ok(rows(many).every((r) => r.mM === 1.5 && r.sigmaMM === 0.1))
    assert.deepEqual(
        rows(many).map((r) => r.source),
        ["two.fa", "two.fa"],
    )
    assert.deepEqual(
        rows(many).map((r) => r.record),
        ["r1", "r2"],
    )
    assert.ok(rows(many).every((r) => rowProblem(bufferRow(r)) === undefined))
    assert.deepEqual(
        many.table.rows.map((_, i) => many.table.mark(i)),
        ["*", "*"],
    )
    // a FASTQ file is read like a FASTA one
    const q = feed(toPath("dna"), fq, submit, "1", submit, "0.1", submit)
    assert.deepEqual(
        rows(q).map((r) => [r.name, r.arg]),
        [
            ["q1", "ACGT"],
            ["q2", "TTGA"],
        ],
    )
    // errors keep the prompt open, with a note of at most 22 characters
    const cases: [string, string][] = [
        ["", "type a path first!"],
        ["rel.fa", "use a full path"],
        [join(root, "none.fa"), "no such file"],
        [root, "that is a folder"],
        [seqFile(root, "bad.fa", ">x\nAC9\n"), "bad letter 9 (DNA)"],
        [seqFile(root, "none.txt", "hello"), "wrong format"],
        [seqFile(root, "empty.fa", ""), "no records"],
    ]
    for (const [typed, note] of cases) {
        const f = feed(toPath("dna"), ...(typed ? [typed] : []), submit)
        assert.equal(f.state.kind, "path", typed)
        assert.equal(dropdown(f).problem, note, typed)
        assert.ok(note.length <= 22)
        assert.equal(rows(f).length, 1, "only the draft row so far")
    }
    // a pasted path with a newline is trimmed
    assert.equal(field(feed(toPath("dna"), `${dna}\n`, submit)), "mM")
    // the 999-row cap stops a file that would not fit, adding nothing
    const full = Drafts.of<Solute>(
        Array.from({ length: MAX_ROWS - 1 }, () => ({
            kind: "nonbiological",
            name: "s",
            arg: "s",
            mM: 1,
            sigmaMM: 0.1,
        })),
    )
    let capped = feed(toPath("dna", full), two, submit)
    assert.equal(capped.state.kind, "path")
    assert.equal(dropdown(capped).problem, "over 999 rows")
    assert.equal(rows(capped).length, MAX_ROWS, "only the draft row, nothing of the file")
    assert.equal(rows(feed(capped, esc)).length, MAX_ROWS - 1)
    capped = feed(toPath("dna", full), dna, submit)
    assert.equal(rows(capped).length, MAX_ROWS, "one record still fits")
    // a DNA file with a U is refused as DNA, an RNA file with a T as RNA
    const u = seqFile(root, "u.fa", ">x\nACGU\n")
    const t = seqFile(root, "t.fa", ">x\nACGT\n")
    assert.equal(dropdown(feed(toPath("dna"), u, submit)).problem, "bad letter U (DNA)")
    assert.equal(dropdown(feed(toPath("rna"), t, submit)).problem, "bad letter T (RNA)")
    assert.equal(field(feed(toPath("dna"), t, submit)), "mM")
    assert.equal(field(feed(toPath("rna"), u, submit)), "mM")
    // the desktop's file picker: the first file is taken, a problem is a note
    const picker = (result: AddEvent) => feed(toPath("dna"), result)
    assert.equal(dropdown(picker({ type: "files", result: { files: [dna] } })).typed, dna)
    assert.equal(
        dropdown(picker({ type: "files", result: { problem: "no desktop" } })).problem,
        "no desktop",
    )
    assert.equal(dropdown(picker({ type: "files", result: { files: [] } })).typed, "")
    assert.equal(dropdown(toPath("dna")).filePicker, true)
    // hints: Tab completes
    const tab = feed(toPath("dna"), `${root}/c`, { type: "complete" })
    assert.equal(dropdown(tab).typed, `${root}/carrier.fa`)
    assert.equal(
        dropdown(feed(toPath("dna"), "x".repeat(301))).problem,
        "path too long (300 at most)",
    )
})

// ---- cancel at every stage, and editing -----------------------------------------------

test("the add keys start the right flow", () => {
    for (const kind of ["nonbio", "polymer"] as const) {
        const flow = add(kind)
        assert.equal(flow.state.kind, "name")
        assert.deepEqual(dropdown(flow).items, [])
    }
    // the dropdowns list only their kind, whatever is typed
    const allowed = {
        nonbio: ["nonbiological", "custom-nonbio"],
        polymer: ["polymer", "polymer-family", "custom-polymer"],
    }
    for (const typed of ["peg", "nacl", "chain", "tris", "dna", "ficoll"]) {
        for (const kind of ["nonbio", "polymer"] as const) {
            const s = feed(add(kind), typed).state
            assert.equal(s.kind, "name")
            if (s.kind === "name")
                assert.ok(s.matches.every((m) => allowed[kind].includes(m.kind)))
        }
    }
    // ^f asks the path of a protein at once; ^e asks DNA or RNA first
    const f = add("protein")
    assert.equal(f.state.kind, "path")
    const e = add("nucleotide")
    assert.equal(dropdown(e).label, "DNA or RNA")
    assert.deepEqual(
        dropdown(e).items.map((i) => i.text),
        ["DNA", "RNA"],
    )
    const seqKind = (fl: AddFlow) =>
        fl.state.kind === "path" ? fl.state.seqKind : undefined
    assert.equal(seqKind(feed(add("nucleotide"), submit)), "dna")
    assert.equal(seqKind(feed(add("nucleotide"), down, submit)), "rna")
    assert.equal(seqKind(feed(add("nucleotide"), { type: "pick", index: 1 })), "rna")
    assert.equal(rows(e).length, 1, "one draft row")
    // Escape at every stage drops the new row
    const stages: [string, AddFlow][] = [
        ["^n name", add("nonbio")],
        ["^n typed", feed(add("nonbio"), "tr")],
        ["^p name", add("polymer")],
        ["^f path", add("protein")],
        ["^f typed", feed(add("protein"), "/x")],
        ["^e choice", add("nucleotide")],
        ["^e path", feed(add("nucleotide"), submit)],
    ]
    for (const [label, flow] of stages) {
        feed(flow, esc)
        assert.equal(rows(flow).length, 0, label)
        assert.ok(flow.done, label)
    }
})

test("a flow of a full table", () => {
    const full = Drafts.of<Solute>(
        Array.from({ length: MAX_ROWS }, () => fixtureRow("NaCl")),
    )
    const flow = AddFlow.add(full, "nonbio", { customs: [] })
    assert.ok(flow.done)
    assert.equal(flow.table, full)
})

test("cancel drops the new rows", () => {
    const base = feed(add(), "tris", submit, "1", submit, "0.1", submit)
    assert.equal(rows(base).length, 1)
    const stages: [string, "nonbio" | "polymer", (string | AddEvent)[]][] = [
        ["name", "polymer", []],
        ["name typed", "polymer", ["pe"]],
        ["form", "polymer", ["peg", submit]],
        ["params", "polymer", ["peg", submit, submit]],
        ["second arg", "polymer", ["pluronic", submit, "10", submit]],
        ["counts", "polymer", ["chain-4", submit, "1", submit]],
        ["mM", "nonbio", ["tris", submit]],
        ["±", "nonbio", ["tris", submit, "1", submit]],
    ]
    for (const [label, kind, keys] of stages) {
        const f = AddFlow.add(base.table, kind, { customs, cursor: 0 })
        feed(f, ...keys)
        assert.equal(rows(f).length, 2, `${label}: the draft is there`)
        feed(f, esc)
        assert.equal(rows(f).length, 1, `${label}: dropped`)
        assert.ok(f.done, label)
        assert.equal(f.cursor, 0, `${label}: the cursor is where it was`)
    }
    // a file's rows all go, after the mM was taken
    const root = tempRoot()
    const two = seqFile(root, "two.fa", ">r1\nAC\n>r2\nGG\n")
    const flow = feed(add("nucleotide", base.table), submit, two, submit, "1", submit)
    assert.equal(rows(flow).length, 3)
    feed(flow, esc)
    assert.equal(rows(flow).length, 1)
    // a saved row is never dropped
    const saved = Drafts.of([fixtureRow("NaCl")])
    const kept = feed(add("nonbio", saved), esc)
    assert.deepEqual(rows(kept), [fixtureRow("NaCl")])
})

test("editing rows", () => {
    const on = (name: string) => Drafts.of([fixtureRow(name)])
    const fields = (table: Drafts<Solute>) => {
        const flow = AddFlow.edit(table, 0)
        const seen: string[] = []
        while (!flow.done) {
            seen.push(field(flow) as string)
            flow.send(submit)
        }
        return seen
    }
    // the fields of an edit, in order, skipping what does not apply
    assert.deepEqual(fields(on("NaCl")), ["name", "mM", "sigmaMM"])
    assert.deepEqual(fields(on("NACET")), ["name", "mM", "sigmaMM"])
    assert.deepEqual(fields(on("PEG 22")), ["name", "params", "mM", "sigmaMM"])
    assert.deepEqual(fields(on("Pluronic")), ["name", "params", "params", "mM", "sigmaMM"])
    assert.deepEqual(fields(on("four-unit chain")), [
        "name",
        "params",
        "params",
        "params",
        "params",
        "mM",
        "sigmaMM",
    ])
    assert.deepEqual(
        fields(on("primer-A")),
        ["name", "mM", "sigmaMM"],
        "a sequence has no params",
    )
    const grade = Drafts.of<Solute>([
        { kind: "polymer", name: "F", arg: "ficoll 70", mM: 1, sigmaMM: 0.1 },
    ])
    assert.deepEqual(fields(grade), ["name", "mM", "sigmaMM"])
    // the name is a free label: arg and kind stay
    let flow = feed(AddFlow.edit(on("NaCl"), 0), { type: "text", text: "salt" }, submit)
    let row = rows(flow)[0]
    assert.deepEqual(
        [row.name, row.arg, row.kind],
        ["salt", "sodium chloride", "nonbiological"],
    )
    assert.equal(field(flow), "mM")
    flow = feed(AddFlow.edit(on("NaCl"), 0), { type: "text", text: "" }, submit)
    assert.equal(prompt(flow).problem, "name needed")
    // a family's numbers are re-typed and the arg rebuilt
    flow = feed(AddFlow.edit(on("PEG 22"), 0), submit)
    assert.equal(field(flow), "params")
    assert.equal(prompt(flow).typed, "22", "the old number is the start")
    assert.equal(prompt(flow).note, "units n")
    flow = feed(flow, "30", submit)
    row = rows(flow)[0]
    assert.equal(row.arg, "PEG n=30")
    assert.equal(paramsCell(row, 22).text, "n=30")
    // a custom polymer's counts are re-typed
    flow = feed(AddFlow.edit(on("one-unit chain"), 0), submit)
    assert.equal(prompt(flow).typed, "22")
    flow = feed(flow, "50", submit)
    assert.deepEqual(rows(flow)[0].counts, [50])
    assert.equal(rows(flow)[0].custom, "chain-1")
    // Escape stops the edit and what was taken stays a draft
    flow = feed(AddFlow.edit(on("NaCl"), 0), submit, "150", submit, esc)
    assert.ok(flow.done)
    assert.equal(rows(flow)[0].mM, 150)
    assert.equal(flow.table.mark(0), "*")
    // a sequence row says the sequence is not edited here
    flow = AddFlow.edit(on("carrier"), 0)
    assert.equal(prompt(flow).note, "re-add to change the sequence")
    assert.equal(prompt(feed(flow, submit)).note, undefined)
    // old-style rows (names not in the index) still edit
    const old: Solute = {
        kind: "nonbiological",
        name: "my buffer salt",
        arg: "my buffer salt",
        mM: 5,
        sigmaMM: 0.5,
    }
    flow = feed(AddFlow.edit(Drafts.of([old]), 0), submit, "6", submit, "0.6", submit)
    assert.deepEqual(rows(flow)[0], { ...old, mM: 6, sigmaMM: 0.6 })
    assert.deepEqual(paramsCell(old, 22), { text: "n/a", align: "center" })
    // a removed row cannot be edited
    assert.ok(AddFlow.edit(on("NaCl").remove(0), 0).done)
    assert.ok(AddFlow.edit(empty(), 0).done)
})

test("what a screen draws", () => {
    // the name being searched shows in the name cell
    let d = dropdown(feed(add("polymer"), "pe"))
    assert.deepEqual(d.cell, { row: 0, column: 0 })
    assert.equal(d.typed, "pe")
    // the params cell shows the arguments as typed
    const p = prompt(feed(add("polymer"), "pluronic", submit, "1"))
    assert.deepEqual(p.cell, { row: 0, column: 3 })
    assert.equal(p.shown, "nEO=1")
    assert.equal(p.typed, "1")
    // mM and +- sit in their columns
    assert.equal(prompt(feed(add("nonbio"), "tris", submit)).cell.column, 1)
    assert.equal(prompt(feed(add("nonbio"), "tris", submit, "1", submit)).cell.column, 2)
    // a finished flow says so and holds the rows
    const flow = feed(add("nonbio"), "tris", submit, "1", submit, "0.1", submit)
    assert.equal(flow.step.type, "done")
    d = dropdown(add("nonbio"))
    assert.equal(d.type, "dropdown")
    // events after done change nothing
    assert.equal(feed(flow, submit).table, flow.table)
})
