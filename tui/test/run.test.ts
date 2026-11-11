// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/run.ts: readiness, temperature prompt, claim, output tail, session.

import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    rmSync,
    writeFileSync,
} from "node:fs"
import { hostname } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { getTimeZones } from "@vvo/tzdb"
import moment from "moment-timezone"
import { RUN_FLOW } from "../src/core/environment.js"
import { writeJson } from "../src/core/file-system.js"
import { wrapLine } from "../src/core/terminal.js"
import { runNote, visibleTail } from "../src/screens/run-screens.js"
import { type BufferRow, bufferFile, writeSolutes } from "../src/store/buffer.js"
import { setEnergy, writeData } from "../src/store/data.js"
import {
    addModel,
    CLAIM_FILE,
    isoStamp,
    liveRun,
    markStaleRuns,
    RunInProgressError,
    runDirOf,
    runIds,
    runStatus,
} from "../src/store/projects.js"
import {
    claimRun,
    elapsedText,
    isEnd,
    juliaArgs,
    juliaCommand,
    type Launcher,
    markAllStaleRuns,
    OutputTail,
    parseTemperature,
    projectReadiness,
    quitAll,
    RunSession,
    snapshotInputs,
    temperatureStart,
} from "../src/store/run.js"
import {
    archivePath,
    isPacked,
    readRunText,
    runFolderFiles,
} from "../src/store/run-archive.js"
import {
    compareRunNames,
    parseRunStamp,
    runBrief,
    runDisplay,
    runStamp,
    ZONE_OVERRIDES,
    zoneLabel,
    zoneLabelWithSource,
} from "../src/store/run-stamp.js"
import { destructiveQuestion } from "../src/ui/input.js"
import { fixture, tempDir, tempDir as tmp } from "./support/fixtures.js"

// ========================================================================================
// 1. Readiness
// ========================================================================================

const row = (fixture("buffer/buffer.json").solutes as BufferRow[])[0] as BufferRow

/** A project folder and a model file in another folder. */
function setup(): { dir: string; model: string } {
    const dir = tempDir()
    const model = join(tempDir(), "m.pdb")
    writeFileSync(model, "ATOM\n")
    return { dir, model }
}

const curve = {
    q: Array.from({ length: 10 }, (_, k) => 0.01 * (k + 1)),
    i: Array.from({ length: 10 }, (_, k) => 10 - k),
    sigma: Array.from({ length: 10 }, () => 0.1),
    dropped: 0,
}

test("readiness: a run needs a model and a non-empty buffer", () => {
    const { dir, model } = setup()
    const ref = { id: "p", dir }
    assert.deepEqual(projectReadiness(ref), {
        models: false, buffer: false, data: false, run: false,
    })
    addModel(dir, model)
    assert.deepEqual(projectReadiness(ref), {
        models: true, buffer: false, data: false, run: false,
    })
    writeSolutes(dir, [])
    assert.equal(projectReadiness(ref).run, false, "an empty buffer is not a buffer")
    writeSolutes(dir, [row])
    assert.equal(projectReadiness(ref).buffer, false, "solutes without a pH are no buffer")
    writeSolutes(dir, [row], { pH: 7.4, "sigma-pH": 0.1 })
    assert.deepEqual(projectReadiness(ref), {
        models: true, buffer: true, data: false, run: false,
    })
    // data without an energy is not ready; the energy makes it ready
    writeData(dir, curve, "c.dat", "A-1")
    assert.equal(projectReadiness(ref).data, false)
    assert.equal(projectReadiness(ref).run, false)
    setEnergy(dir, 12400)
    assert.deepEqual(projectReadiness(ref), {
        models: true, buffer: true, data: true, run: true,
    })
    writeFileSync(join(dir, "data.json"), "{ garbled")
    assert.equal(projectReadiness(ref).run, false)
})

test("readiness: an unreadable buffer or a missing folder counts as missing", () => {
    const { dir, model } = setup()
    addModel(dir, model)
    writeFileSync(bufferFile(dir), "{ not json")
    assert.equal(projectReadiness({ id: "p", dir }).buffer, false)
    mkdirSync(join(dir, "x"))
    const gone = join(dir, "nowhere")
    assert.equal(projectReadiness({ id: "g", dir: gone }).run, false)
})

// ========================================================================================
// 2. Temperature prompt
// ========================================================================================

test("a temperature is a number in the range of the asset file", () => {
    for (const [text, value] of [
        ["25", 25],
        [" 4.5 ", 4.5],
        ["0", 0],
        ["100", 100],
        ["37.", 37],
    ] as const)
        assert.deepEqual(parseTemperature(text), { value }, text)
    for (const text of ["", "abc", "1e999", "25 C"])
        assert.deepEqual(parseTemperature(text), { error: "a number, please" }, text)
    for (const text of ["-1", "100.5", "-273.15", "300"])
        assert.deepEqual(parseTemperature(text), { error: "from 0 to 100 °C" }, text)
})

test("the prompt starts at the last temperature, else at the default", () => {
    assert.equal(temperatureStart(), "25")
    assert.equal(temperatureStart(37.5), "37.5")
})

// ========================================================================================
// 3. Claim
// ========================================================================================


/** A project folder with the inputs of a run. */
function project(): string {
    const dir = tmp()
    writeFileSync(join(dir, "buffer.json"), '{"solutes": []}\n')
    writeFileSync(join(dir, "data.tsv"), "0.1\t5\t0.1\n")
    writeFileSync(join(dir, "data.json"), '{"units": "A-1", "energy": 8000}\n')
    return dir
}

/** The run.json of a run that Julia is running now, with a fresh heartbeat. */
function liveJson(pid: number, ms: number = Date.now()): string {
    return writeJson({
        status: "running",
        pid,
        host: hostname(),
        heartbeat: isoStamp(ms),
    })
}

test("the name is HH-MM-SS-mmm_TZ_±HHMM_YYYY-MM-DD, local time, Julia's name too", () => {
    // the literals of `run_project: UTC time without a package` in test_runproject.jl
    const at = Date.UTC(2026, 10, 8, 4, 35, 29, 123)
    assert.equal(runStamp(at, -300, "EST"), "23-35-29-123_EST_-0500_2026-11-07")
    assert.equal(runStamp(at, 0, "UTC"), "04-35-29-123_UTC_+0000_2026-11-08")
    const sample = Date.UTC(2023, 10, 14, 22, 13, 20, 123)
    assert.equal(runStamp(sample, 330, "GMT"), "03-43-20-123_GMT_+0530_2023-11-15")
    assert.equal(runStamp(sample - 123, -300, "EST"), "17-13-20-000_EST_-0500_2023-11-14")
    assert.equal(runStamp(0, 0, "UTC"), "00-00-00-000_UTC_+0000_1970-01-01")
    // this machine's zone, whatever it is
    const shape = /^\d\d-\d\d-\d\d-\d{3}_\p{L}{3,}_[+-]\d{4}_\d{4}-\d\d-\d\d$/u
    assert.match(runStamp(Date.now()), shape)
    assert.equal(runStamp(at, -300, "EST").length, 33)
    assert.equal(runStamp(at, 120, "CEST").length, 34)
    // an accented label is one text in both languages (Julia's test has the same literal)
    const late = Date.UTC(2026, 10, 8, 2, 35, 29, 123)
    assert.equal(runStamp(late, -180, "SãoPaulo"), "23-35-29-123_SãoPaulo_-0300_2026-11-07")
})

test("the zone label: moment, tzdb (offset checked), city name, no GMT stand-in", () => {
    const winter = Date.UTC(2026, 0, 15, 12)
    const summer = Date.UTC(2026, 6, 15, 12)
    const cases: [string, number, number, string][] = [
        ["America/Toronto", winter, -300, "EST"], ["America/Toronto", summer, -240, "EDT"],
        ["Europe/London", winter, 0, "GMT"], ["Europe/London", summer, 60, "BST"],
        ["Europe/Berlin", summer, 120, "CEST"], ["Australia/Sydney", winter, 600, "AEST"],
        ["Asia/Kolkata", winter, 330, "IST"], ["Etc/UTC", winter, 0, "UTC"],
        // no abbreviation in tzdata: the curated one of tzdb
        ["Europe/Istanbul", winter, 180, "TRT"], ["America/Sao_Paulo", winter, -180, "BRT"],
        ["America/Santiago", summer, -240, "CLT"],
        ["America/Santiago", winter, -180, "CLST"],
        // the offset is not the one the abbreviation stands for: the city, accents kept
        ["America/Sao_Paulo", winter, -120, "SãoPaulo"],
        ["America/Sao_Paulo", Date.UTC(2010, 0, 1), -120, "SãoPaulo"],
        // no abbreviation anywhere: the city of tzdb, or the zone's name
        ["Asia/Almaty", winter, 300, "Almaty"], ["Asia/Damascus", winter, 180, "Damascus"],
        ["Africa/Casablanca", winter, 60, "Casablanca"],
        ["Asia/Urumqi", winter, 360, "Ürümqi"],
        ["Etc/GMT+5", winter, -300, "GMTplusFive"],
        ["Etc/GMT-14", winter, 840, "GMTminusFourteen"],
        ["Mars/Olympus_Mons", winter, 0, "OlympusMons"],
        // a neighbour's abbreviation is not used (tzdb has MAWT, KOST, PGT, CST here)
        ["Antarctica/Vostok", winter, 300, "VOST"],
        ["Pacific/Pohnpei", winter, 660, "PONT"],
        ["Pacific/Yap", winter, 600, "Yap"], ["Asia/Kashgar", winter, 360, "Kashgar"],
    ]
    for (const [name, at, offset, label] of cases)
        assert.equal(zoneLabel(name, at, offset), label, `${name} ${offset}`)
})

// Every zone moment-timezone knows, at a winter and a summer
// instant of 2026 and just before and after each of its changes
// of 2025-2026 (the ACCURACY REQUIREMENT of the label).
test("the zone label is accurate for every zone, at every change of the clock", () => {
    const entries = new Map<string, ReturnType<typeof getTimeZones>[number]>()
    for (const entry of getTimeZones())
        for (const alias of entry.group) entries.set(alias, entry)
    const first = Date.UTC(2025, 0, 1)
    const last = Date.UTC(2027, 0, 1)
    let checked = 0
    for (const name of moment.tz.names()) {
        const zone = moment.tz.zone(name) as moment.MomentZone
        const instants = [Date.UTC(2026, 0, 15, 12), Date.UTC(2026, 6, 15, 12)]
        for (const until of zone.untils)
            if (until > first && until < last) instants.push(until - 1, until)
        for (const at of instants) {
            const offset = 0 - zone.utcOffset(at)
            const { label, source } = zoneLabelWithSource(name, at, offset)
            const where = `${name} at ${new Date(at).toISOString()} (${offset})`
            checked++
            assert.match(label, /^\p{L}{3,}$/u, where)
            assert.equal(label, label.normalize("NFC"), where)
            const own = zone.abbr(at)
            if (label === "GMT" || label === "UTC") assert.equal(label, own, where)
            if (source === "moment") assert.equal(label, own.toUpperCase(), where)
            const entry = entries.get(name)
            if (source === "tzdb") {
                assert.notEqual(entry, undefined, where)
                const raw = entry?.rawOffsetInMinutes
                if (label === entry?.abbreviation) assert.equal(offset, raw, where)
                else {
                    assert.equal(label, entry?.dstAbbreviation, where)
                    assert.notEqual(offset, raw, where)
                }
            }
            if (source === "override") {
                const [standard, daylight] = ZONE_OVERRIDES[name] ?? []
                const stands = [standard, daylight].find((a) => a?.[0] === label)
                assert.equal(stands?.[1], offset, where)
            }
        }
    }
    assert.ok(checked > 2500)
})

test("every override stands for an offset its zone has, in the letters it names", () => {
    for (const [name, abbreviations] of Object.entries(ZONE_OVERRIDES)) {
        const zone = moment.tz.zone(name)
        assert.notEqual(zone, null, name)
        const offsets = new Set((zone as moment.MomentZone).offsets.map((o) => 0 - o))
        for (const [letters, offset] of abbreviations) {
            assert.match(letters, /^\p{L}{3,5}$/u, name)
            assert.ok(offsets.has(offset), `${name} never had ${offset}`)
        }
    }
})

test("the library's label of this machine's zone is Unicode letters", () => {
    // moment-timezone and tzdb (IANA tzdata) are what runStamp asks
    assert.match(runStamp(Date.UTC(2026, 0, 15, 12)), /_\p{L}{3,}_/u)
    assert.match(runStamp(Date.UTC(2026, 6, 15, 12)), /_\p{L}{3,}_/u)
})

test("a name is shown as 23:35:29:123 EST -05:00 · 2026-11-07, an old one too", () => {
    assert.equal(
        runDisplay("23-35-29-123_EST_-0500_2026-11-07"),
        "23:35:29:123 EST -05:00 · 2026-11-07",
    )
    assert.equal(
        runDisplay("04-35-29-123_UTC_+0000_2026-11-08"),
        "04:35:29:123 UTC +00:00 · 2026-11-08",
    )
    assert.equal(
        runDisplay("20261106T193308Z"),
        "19:33:08:000 UTC +00:00 · 2026-11-06",
    )
    assert.equal(
        runDisplay("23-35-29-123_SãoPaulo_-0300_2026-11-07"),
        "23:35:29:123 SãoPaulo -03:00 · 2026-11-07",
    )
    const decomposed = "23-35-29-123_Sa\u0303oPaulo_-0300_2026-11-07"
    assert.equal(runDisplay(decomposed), "23:35:29:123 SãoPaulo -03:00 · 2026-11-07")
    assert.equal(runDisplay("odd-name"), "odd-name")
    const bad = "25-35-29-123_EST_-0500_2026-11-07"
    assert.equal(runDisplay(bad), bad)
    const ist = runDisplay(runStamp(0, 330, "IST"))
    assert.equal(ist, "05:30:00:000 IST +05:30 · 1970-01-01")
})

test("a name parses back to its instant, in both formats; near misses are no stamp", () => {
    const instants = [0, Date.UTC(2023, 10, 14, 22, 13, 20, 123)]
    instants.push(Date.UTC(2000, 1, 29, 23, 59, 59, 999))
    for (const offset of [0, -300, 330, 840, -90])
        for (const ms of instants)
            assert.equal(parseRunStamp(runStamp(ms, offset, "CEST")), ms)
    // any Unicode letters, and a decomposed name (macOS) is the same name
    const late = Date.UTC(2026, 10, 8, 2, 35, 29, 123)
    assert.equal(parseRunStamp("23-35-29-123_SãoPaulo_-0300_2026-11-07"), late)
    assert.equal(parseRunStamp("23-35-29-123_Sa\u0303oPaulo_-0300_2026-11-07"), late)
    assert.equal(parseRunStamp("23-35-29-123_Ürümqi_-0300_2026-11-07"), late)
    assert.equal(parseRunStamp("20231114T221320Z"), Date.UTC(2023, 10, 14, 22, 13, 20))
    for (const bad of [
        "", "run", "17-13-20-000_EST_-0500_14-11-2023", "17-13-20-00_EST_-0500_2023-11-14",
        "17:13:20-000_EST_-0500_2023-11-14", "17-13-20-000_EST_0500_2023-11-14",
        "17-13-20-000__-0500_2023-11-14", "17-13-20-000_ES_-0500_2023-11-14",
        "17-13-20-000_E1T_-0500_2023-11-14", "17-13-20-000_UTC-0500_2023-11-14",
        "17-13-20-000_EST_-0500_2023-02-31", "24-13-20-000_EST_-0500_2023-11-14",
        "17-60-20-000_EST_-0500_2023-11-14", "17-13-20-000_EST_-0560_2023-11-14",
        "17-13-20-000_EST_-0500_2023-13-14", "20231314T221320Z", "20231114T251320Z",
        "17-13-20-000_E-T_-0500_2023-11-14", "17-13-20-000_E_T_-0500_2023-11-14",
        " 17-13-20-000_EST_-0500_2023-11-14", "17-13-20-000_EST_-0500_2023-11-14 ",
    ])
        assert.equal(parseRunStamp(bad), undefined, bad)
})

test("names sort by the instant, not the text; odd names come first (oldest)", () => {
    const names = [
        "23-35-29-123_EST_-0500_2026-11-07", // 04:35:29.123Z on the 8th
        "20261108T043529Z", //                  an older, UTC, 123 ms earlier
        "01-00-00-000_GMT_+0100_2026-11-08", //  00:00Z on the 8th
        "zz-not-a-run",
        "00-00-00-000_UTC_+0000_2026-11-09",
        "20261101T000000Z",
        "23-35-29-123_SãoPaulo_-0300_2026-11-08", // 02:35:29.123Z on the 9th
    ]
    assert.deepEqual([...names].sort(compareRunNames), [
        "zz-not-a-run",
        "20261101T000000Z",
        "01-00-00-000_GMT_+0100_2026-11-08",
        "20261108T043529Z",
        "23-35-29-123_EST_-0500_2026-11-07",
        "00-00-00-000_UTC_+0000_2026-11-09",
        "23-35-29-123_SãoPaulo_-0300_2026-11-08",
    ])
})

test("a claim makes runs/<name>/ with its marker; a clash takes the next ms", () => {
    const p = project()
    const at = Date.UTC(2026, 10, 6, 12, 0, 0, 500)
    const first = claimRun(p, at)
    assert.equal(first.id, runStamp(at), "the machine's own zone label")
    assert.equal(parseRunStamp(first.id), at)
    assert.equal(existsSync(join(first.dir, CLAIM_FILE)), true)
    // the first run is live (the marker of this very process), so a second is refused...
    assert.throws(() => claimRun(p, at), RunInProgressError)
    // ...until it is over; then the same millisecond is taken, and the next one is used
    writeFileSync(join(first.dir, "run.json"), writeJson({ status: "done" }))
    const second = claimRun(p, at)
    assert.equal(second.id, runStamp(at + 1))
    writeFileSync(join(second.dir, "run.json"), writeJson({ status: "done" }))
    assert.equal(claimRun(p, at).id, runStamp(at + 2))
    assert.equal(runIds(p).length, 3, "nothing was overwritten")
    assert.deepEqual(runIds(p), [first.id, second.id, runStamp(at + 2)], "oldest first")
    // the lock folder is no run
    assert.equal(readdirSync(join(p, "runs")).includes(".start.lock"), false)
})

test("a start is refused while a run is live, with its pid; a dead one is not", () => {
    const p = project()
    const runs = join(p, "runs")
    mkdirSync(join(runs, "20260101T000000Z"), { recursive: true })
    writeFileSync(join(runs, "20260101T000000Z", "run.json"), liveJson(process.pid))
    assert.deepEqual(liveRun(p)?.pid, process.pid)
    assert.throws(
        () => claimRun(p),
        (e: Error) =>
            e instanceof RunInProgressError &&
            e.message === `a run is in progress (pid ${process.pid})`,
    )
    // a heartbeat a minute old, or a pid that does not exist, is not live
    writeFileSync(
        join(runs, "20260101T000000Z", "run.json"),
        liveJson(process.pid, Date.now() - 61_000),
    )
    assert.equal(liveRun(p), undefined)
    writeFileSync(join(runs, "20260101T000000Z", "run.json"), liveJson(2 ** 22 + 12345))
    assert.equal(liveRun(p), undefined)
    assert.ok(claimRun(p).id)
})

test("a project that is gone is not made again by a claim", () => {
    const gone = join(tmp(), "gone")
    assert.throws(() => claimRun(gone), /no longer exists/)
    assert.equal(existsSync(gone), false)
})

test("the snapshot copies the inputs into the run folder; no settings.json: {}", () => {
    const p = project()
    const run = claimRun(p)
    snapshotInputs(p, run.dir)
    const logs = run.dir
    assert.equal(readFileSync(join(logs, "settings.json"), "utf-8"), "{}\n")
    for (const name of ["buffer.json", "data.tsv", "data.json"])
        assert.equal(
            readFileSync(join(logs, name), "utf-8"),
            readFileSync(join(p, name), "utf-8"),
        )
    // a missing curve stops the start with a clear message
    const q = project()
    rmSync(join(q, "data.tsv"))
    const run2 = claimRun(q)
    assert.throws(() => snapshotInputs(q, run2.dir), /no data\.tsv/)
})

test("the snapshot also copies model-settings.json and the reference files", () => {
    const p = project()
    const run = claimRun(p)
    snapshotInputs(p, run.dir)
    const logs = run.dir
    assert.equal(existsSync(join(logs, "model-settings.json")), false)
    assert.deepEqual(
        readdirSync(logs).filter((n) => n.startsWith("reference-fit")),
        [],
        "none made without any",
    )
    // a project with both: only the files Julia reads, whole
    const q = project()
    const models = '{"crambin":{"model":{"Q_MAX":{"value":0.3}}}}\n'
    writeFileSync(join(q, "model-settings.json"), models)
    mkdirSync(join(q, "reference-fit", "folder.dat"), { recursive: true })
    writeFileSync(join(q, "reference-fit", "CRYSOL.tsv"), "0.1\t2\n0.2\t1\n0.3\t1\n")
    writeFileSync(join(q, "reference-fit", "foxs.DAT"), "0.1 2\n")
    writeFileSync(join(q, "reference-fit", "notes.md"), "not a curve")
    const run2 = claimRun(q)
    snapshotInputs(q, run2.dir)
    const out = run2.dir
    assert.equal(readFileSync(join(out, "model-settings.json"), "utf-8"), models)
    assert.deepEqual(
        readdirSync(out).filter((n) => n.startsWith("reference-fit-")).sort(),
        ["reference-fit-CRYSOL.tsv", "reference-fit-foxs.DAT"],
    )
    assert.equal(
        readFileSync(join(out, "reference-fit-CRYSOL.tsv"), "utf-8"),
        readFileSync(join(q, "reference-fit", "CRYSOL.tsv"), "utf-8"),
    )
})

test("the snapshot of a project with the old references/ folder moves it", () => {
    const q = project()
    mkdirSync(join(q, "references"))
    writeFileSync(join(q, "references", "CRYSOL.tsv"), "0.1\t2\n0.2\t1\n0.3\t1\n")
    const run = claimRun(q)
    snapshotInputs(q, run.dir)
    assert.equal(existsSync(join(q, "references")), false, "moved")
    assert.deepEqual(readdirSync(join(q, "reference-fit")), ["CRYSOL.tsv"])
    assert.ok(existsSync(join(run.dir, "reference-fit-CRYSOL.tsv")))
    assert.equal(existsSync(join(run.dir, "references")), false)
})

test("the startup sweep marks a dead run interrupted, and leaves a live one alone", () => {
    const root = tmp()
    const a = join(root, "a")
    const b = join(root, "b")
    for (const dir of [a, b]) {
        mkdirSync(join(dir, "runs", "20260101T000000Z"), { recursive: true })
        writeFileSync(
            join(dir, "project.json"),
            writeJson({ id: dir === a ? "a" : "b", created: "x" }),
        )
    }
    writeFileSync(join(a, "runs", "20260101T000000Z", "run.json"), liveJson(2 ** 22 + 777))
    writeFileSync(join(b, "runs", "20260101T000000Z", "run.json"), liveJson(process.pid))
    assert.deepEqual(markAllStaleRuns(root), ["a/20260101T000000Z"])
    assert.equal(runStatus(a, "20260101T000000Z"), "interrupted")
    assert.equal(runStatus(b, "20260101T000000Z"), "running")
    // run.json keeps what Julia wrote, and gets an end time
    const json = JSON.parse(
        readFileSync(join(a, "runs", "20260101T000000Z", "run.json"), "utf-8"),
    )
    assert.equal(json.pid, 2 ** 22 + 777)
    assert.match(json.ended, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/)
    assert.deepEqual(markAllStaleRuns(root), [], "idempotent")
})

test("a claimed folder whose starter died (no run.json) becomes interrupted too", () => {
    const p = project()
    const dir = join(p, "runs", "20260101T000000Z")
    mkdirSync(dir, { recursive: true })
    writeFileSync(
        join(dir, CLAIM_FILE),
        writeJson({ pid: 2 ** 22 + 99, host: hostname(), time: isoStamp(Date.now()) }),
    )
    assert.equal(liveRun(p), undefined)
    assert.deepEqual(markStaleRuns(p), ["20260101T000000Z"])
    assert.equal(runStatus(p, "20260101T000000Z"), "interrupted")
    assert.deepEqual(markStaleRuns(p), [], "a second sweep finds nothing to do")
})

// ========================================================================================
// 4. Output tail
// ========================================================================================

test("lines end at newlines; the unfinished line is shown too", () => {
    const t = new OutputTail(10)
    t.feed(0, "one\ntwo\nthr")
    assert.deepEqual(t.lines, ["one", "two", "thr"])
    t.feed(0, "ee\n")
    assert.deepEqual(t.lines, ["one", "two", "three"])
})

test("a carriage return sends the writing back; CRLF is an ordinary line end", () => {
    const t = new OutputTail(10)
    t.feed(0, "10%\r50%\r100%\ndone\r\nnext")
    assert.deepEqual(t.lines, ["100%", "done", "next"])
})

test("escape sequences are dropped, even when a chunk splits them", () => {
    const t = new OutputTail(10)
    t.feed(0, "\x1b[3")
    t.feed(0, "1mred\x1b[0m \x1b]0;title\x07ok\x1b(B\n")
    assert.deepEqual(t.lines, ["red ok"])
    t.feed(0, "\x1b[2K\x1b[1Ago\tx\x00\x01y\n")
    assert.deepEqual(t.lines, ["red ok", "go    xy"])
})

test("the oldest lines go beyond the maximum; each stream has its own open line", () => {
    const t = new OutputTail(3)
    t.feed(0, "a\nb\nc\nd\ne\n")
    assert.deepEqual(t.lines, ["c", "d", "e"])
    t.feed(0, "out")
    t.feed(1, "err")
    assert.deepEqual(t.lines, ["c", "d", "e", "out", "err"])
})

test("the screen shows the newest lines that fit, each wrapped to the panel", () => {
    const lines = ["1", "2", "3", "4", "a very long line indeed"]
    assert.deepEqual(visibleTail(lines, 3, 80), ["3", "4", "a very long line indeed"])
    assert.deepEqual(visibleTail(lines, 2, 8), ["  line", "  indeed"])
    assert.deepEqual(wrapLine("  Checks: a b c d e f", 12), [
        "  Checks:",
        "    a b c d",
        "    e f",
    ])
    assert.deepEqual(visibleTail([], 5, 80), [])
})

test("the note under the output: what the run is doing, else what it has to tell", () => {
    assert.equal(runNote("running", undefined), undefined)
    assert.equal(runNote("aborting", "x"), "stopping the run...")
    assert.equal(runNote("packing", "x"), "packing the run...")
    assert.equal(
        runNote("failed", "could not start julia: ENOENT"),
        "could not start julia: ENOENT",
    )
    assert.equal(runNote("done", undefined), undefined)
})

// ========================================================================================
// 5. Session
// ========================================================================================

const fake = fileURLToPath(new URL("./support/fake-julia.ts", import.meta.url))

/** The launcher that runs the fake Julia in `mode`, in a process group of its own. */
function fakeLauncher(mode: string, pidfile?: string): Launcher {
    return (spec) =>
        spawn(
            process.execPath,
            [
                "--import",
                "tsx",
                fake,
                spec.projectDir,
                String(spec.temperature),
                spec.runDir,
            ],
            {
                detached: true,
                stdio: ["pipe", "pipe", "pipe"],
                env: { ...process.env, FAKE_MODE: mode, FAKE_PIDFILE: pidfile ?? "" },
            },
        )
}

/** Waits until `ok()` holds (polling), or fails after `ms`. */
async function until(ok: () => boolean, what: string, ms = 20000): Promise<void> {
    const end = Date.now() + ms
    while (!ok()) {
        assert.ok(Date.now() < end, `timed out waiting for ${what}`)
        await new Promise((r) => setTimeout(r, 25))
    }
}

/** Whether a process exists. */
function alive(pid: number): boolean {
    try {
        process.kill(pid, 0)
        return true
    } catch {
        return false
    }
}

/** The text of a file of the run, from its archive or its plain folder. */
const logText = (dir: string, name: string): string => readRunText(dir, name)

test("a normal run: tail, packing, done, logs in the archive, conditions", async () => {
    const p = project()
    const session = RunSession.begin(p, 21.5, fakeLauncher("done"))
    const phases: string[] = []
    session.subscribe(() => {
        if (phases.at(-1) !== session.view.phase) phases.push(session.view.phase)
    })
    const phase = await session.done
    assert.ok(phases.includes("packing"), phases.join(","))
    assert.equal(phases.at(-1), "done")
    assert.equal(phase, "done")
    const view = session.view
    assert.ok(isEnd(view.phase) && view.endedMs !== undefined)
    // the progress bar rewrote its line, the colour codes are gone
    assert.ok(view.lines.includes("fake julia started"), view.lines.join("|"))
    assert.ok(view.lines.includes("progress 100%"))
    assert.ok(!view.lines.some((l) => l.includes("progress 10%") || l.includes("\x1b")))
    assert.ok(view.lines.includes("colour on stderr"))
    const dir = runDirOf(p, view.id)
    assert.equal(runStatus(p, view.id), "done")
    // packed: ONE archive beside where the folder was, with everything (run.json too)
    assert.ok(isPacked(dir) && !existsSync(dir), "the folder is gone")
    assert.ok(existsSync(archivePath(dir)))
    assert.deepEqual(readdirSync(join(dir, "..")).filter((n) => !n.startsWith(".")), [
        `${view.id}.7z`,
    ])
    const names = [...runFolderFiles(dir, "").keys()]
    for (const n of ["run.json", "run.LOG", "settings.json", "buffer.json", "data.tsv"])
        assert.ok(names.includes(n), n)
    assert.match(logText(dir, "run.LOG"), /temperature_c\t21\.5/)
    assert.equal(session.view.note, undefined)
})

test("a pack that fails leaves the run folder as it was and says why", async () => {
    const p = project()
    const session = RunSession.begin(p, 21.5, fakeLauncher("done"), async () => {
        throw new Error("7-Zip failed: disk full")
    })
    assert.equal(await session.done, "done")
    const dir = runDirOf(p, session.view.id)
    assert.match(session.view.note ?? "", /not packed: .*disk full/)
    assert.equal(isPacked(dir), false)
    assert.match(readFileSync(join(dir, "run.LOG"), "utf-8"), /temperature_c/)
})

test("a run that failed ends failed with its error line as the note", async () => {
    const p = project()
    const session = RunSession.begin(p, 20, fakeLauncher("failed"))
    assert.equal(await session.done, "failed")
    assert.equal(runStatus(p, session.view.id), "failed")
    // the note row tells why: the first line of the ERRORS section of run.LOG
    assert.equal(session.view.note, "fake: it did not go well")
})

test("abort stops the child and its grandchild and finishes the log", async () => {
    const p = project()
    const pids = join(tmp(), "pids")
    const session = RunSession.begin(p, 20, fakeLauncher("hang", pids))
    await until(() => session.view.lines.includes("ready"), "the child")
    const [child, grandchild] = readFileSync(pids, "utf-8").trim().split(" ").map(Number)
    assert.ok(alive(child as number) && alive(grandchild as number))
    // a second start is refused while this one lives, with its pid
    assert.throws(
        () => RunSession.begin(p, 20, fakeLauncher("done")),
        (e: Error) =>
            e instanceof RunInProgressError &&
            /a run is in progress \(pid \d+\)/.test(e.message),
    )
    const stopped = session.abort("^c")
    assert.equal(session.view.phase, "aborting")
    await stopped
    assert.equal(session.view.phase, "aborted")
    await until(
        () => !alive(child as number) && !alive(grandchild as number),
        "no process left",
    )
    assert.equal(runStatus(p, session.view.id), "aborted")
    assert.ok(logText(runDirOf(p, session.view.id), "run.LOG").length > 0)
    // the project can start a new run again
    const again = RunSession.begin(p, 20, fakeLauncher("done"))
    assert.equal(await again.done, "done")
    assert.notEqual(again.view.id, session.view.id)
})

test("a child that ignores SIGTERM is killed after the grace, with a note", async () => {
    const flow = RUN_FLOW
    const before = flow.abort.graceSeconds
    flow.abort.graceSeconds = 0.4
    try {
        const p = project()
        const pids = join(tmp(), "pids")
        const session = RunSession.begin(p, 20, fakeLauncher("stubborn", pids))
        await until(() => session.view.lines.includes("ready"), "the child")
        const [child, grandchild] = readFileSync(pids, "utf-8")
            .trim()
            .split(" ")
            .map(Number)
        await session.abort("^d")
        assert.equal(session.view.phase, "aborted")
        await until(
            () => !alive(child as number) && !alive(grandchild as number),
            "no process left",
        )
        // julia could not finish its files: the status and the note are written here
        assert.equal(runStatus(p, session.view.id), "aborted")
        const log = await logText(runDirOf(p, session.view.id), "run.LOG")
        assert.match(
            log,
            /=== ERRORS ===\ntui: aborted from the terminal interface \(\^d\); killed/,
        )
    } finally {
        flow.abort.graceSeconds = before
    }
})

test("a child that dies without finishing its files: failed, exit recorded", async () => {
    const p = project()
    const session = RunSession.begin(p, 20, fakeLauncher("crash"))
    assert.equal(await session.done, "failed")
    assert.equal(runStatus(p, session.view.id), "failed")
    assert.match(
        await logText(runDirOf(p, session.view.id), "run.LOG"),
        /tui: julia ended unexpectedly \(exit code 3\)/,
    )
})

test("a child that writes nothing still leaves a failed run with its reason", async () => {
    const p = project()
    const session = RunSession.begin(p, 20, fakeLauncher("silent"))
    assert.equal(await session.done, "failed")
    assert.equal(runStatus(p, session.view.id), "failed")
    assert.match(await logText(runDirOf(p, session.view.id), "run.LOG"), /exit code 1/)
})

test("a Julia that cannot be started is told, not a crash", async () => {
    const p = project()
    const missing: Launcher = () =>
        spawn("/no/such/julia", [], { detached: true, stdio: ["pipe", "pipe", "pipe"] })
    const session = RunSession.begin(p, 20, missing)
    assert.equal(await session.done, "failed")
    assert.match(session.view.note ?? "", /could not start julia/)
    assert.equal(runStatus(p, session.view.id), "failed")
})

test("a start with missing inputs fails before any process; folder stays failed", () => {
    const p = project()
    rmSync(join(p, "buffer.json"))
    let launched = false
    assert.throws(
        () =>
            RunSession.begin(p, 20, () => {
                launched = true
                throw new Error("must not be started")
            }),
        /no buffer\.json/,
    )
    assert.equal(launched, false)
    const [id] = readdirSync(join(p, "runs")).filter((n) => !n.startsWith("."))
    assert.equal(runStatus(p, id as string), "failed")
})

test("quitAll aborts the run that is going and waits until it is over", async () => {
    const p = project()
    const session = RunSession.begin(p, 20, fakeLauncher("hang"))
    await until(() => session.view.lines.includes("ready"), "the child")
    await quitAll("SIGHUP")
    assert.equal(session.view.phase, "aborted")
    assert.equal(runStatus(p, session.view.id), "aborted")
})

test("the clock reads m:ss, then h:mm:ss", () => {
    assert.equal(elapsedText(0), "0:00")
    assert.equal(elapsedText(59_999), "0:59")
    assert.equal(elapsedText(61_000), "1:01")
    assert.equal(elapsedText(3_600_000 + 61_000), "1:01:01")
    assert.equal(elapsedText(-5), "0:00")
})

test("the Julia command and arguments: values travel in ARGS, not in the code", () => {
    assert.equal(juliaCommand({}), "julia")
    assert.equal(juliaCommand({ JULIA: "/opt/julia/bin/julia" }), "/opt/julia/bin/julia")
    assert.equal(juliaCommand({ JULIA: "  " }), "julia")
    const spec = { projectDir: "/p q/it's", runDir: "/p q/it's/runs/x", temperature: 22.5 }
    const args = juliaArgs(spec, "/repo", "auto,1")
    assert.deepEqual(args.slice(0, 4), [
        "--startup-file=no",
        "--color=no",
        "--threads=auto,1",
        "--project=/repo",
    ])
    assert.equal(args[4], "-e")
    assert.ok(!args[5]?.includes("/p q"), "the code holds no path")
    assert.match(args[5] ?? "", /ui = :tui/)
    assert.deepEqual(args.slice(6), ["/p q/it's", "22.5", "/p q/it's/runs/x"])
    assert.ok(!juliaArgs(spec, undefined, "1").some((a) => a.startsWith("--project")))
})

test("runBrief: a run in as few cells as tell runs apart", () => {
    assert.equal(runBrief("14-19-18-912_EST_-0500_2026-11-09"), "14:19:18 2026-11-09")
    assert.equal(runBrief("20260101T120000Z"), "12:00:00 2026-01-01")
    assert.equal(runBrief("not-a-run"), "not-a-run")
    const brief = runBrief("14-19-18-912_EST_-0500_2026-11-09")
    assert.equal(
        destructiveQuestion(`run ${brief}`).text,
        "delete run 14:19:18 2026-11-09? this cannot be undone!",
    )
})
