// SPDX-License-Identifier: LGPL-3.0-or-later

// Projects: the project folders, the state of their runs and the model of each.
//
// Contents:
//   1. Run folder: status, liveness, settle
//   2. Projects
//   3. Models

import {
    constants,
    copyFileSync,
    lstatSync,
    mkdirSync,
    rmSync,
    unlinkSync,
} from "node:fs"
import { hostname } from "node:os"
import { basename, join } from "node:path"
import { getTimeZones, type TimeZone } from "@vvo/tzdb"
import moment from "moment-timezone"
import { ensureDir, projectsRoot, RUN_FLOW } from "../core/environment.js"
import {
    entryNames,
    isDict,
    isFile,
    isFolder,
    ParentMissingError,
    readJson,
    sortNoCase,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { tooLong } from "../core/terminal.js"
import { checkPath } from "./lists.js"
import { readRunText } from "./run-archive.js"

// ========================================================================================
// 1. Run folder: status, liveness, settle
// ========================================================================================

/**
 * The runs of a project, as the program that makes them leaves them. A run is a folder
 * named by its start time (UTC); Julia creates it, the TUI only reads:
 *
 *     <project>/runs/<run name>/run.json   {"status": "running" | "done" | "failed" |
 *                                        "aborted", ...}
 *                            logs/, one folder per model, ...
 *
 * `runs/` is not made by the user or by a new project: a run makes it. Until then the
 * project has no runs, which is [[hasRuns]]. Nothing here deletes or overwrites a run.
 */

/** The folder of a project that holds its runs. */
const runsFolder = "runs"

/** The file of a run folder that says how the run ended. */
const runFileName = "run.json"

/**
 * How a run stands, as `run.json` says. `interrupted` is never written by Julia: it is
 * what a `running` run becomes when nobody is running it any more (see [[markStaleRuns]]).
 */
export type RunStatus = "running" | "done" | "failed" | "aborted" | "interrupted"

/** The statuses a `run.json` may hold; anything else reads as unknown. */
const statuses: readonly string[] = ["running", "done", "failed", "aborted", "interrupted"]

/** The lock file of a project's runs folder that serialises claims and sweeps. */
export const startLockName = ".start"

/**
 * The marker a starter leaves in a run folder it has claimed, until Julia has written its
 * own `run.json` (loading Julia can take a minute): `{pid, host, time}`, renewed while the
 * starter waits. It makes the folder count as live for that time, so a second start is
 * refused in the gap.
 */
export const CLAIM_FILE = ".claim"

/**
 * The name of a run folder: `HH-MM-SS-mmm_TZ_±HHMM_YYYY-MM-DD`, local time. `TZ` is any
 * run of 3 or more Unicode letters (accents allowed); it is opaque, never read.
 */
const runNameFormat =
    /^(\d\d)-(\d\d)-(\d\d)-(\d{3})_\p{L}{3,}_([+-])(\d\d)(\d\d)_(\d{4})-(\d\d)-(\d\d)$/u

/** The older name of a run folder: the UTC time as `yyyyMMddTHHmmssZ`. */
const oldRunNameFormat = /^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z$/

const pad = (n: number, width: number): string => String(n).padStart(width, "0")

/** What a zone-label source gave: the label and which link of the chain served it. */
export interface ZoneLabelResult {
    label: string
    source: "moment" | "tzdb" | "override" | "city" | "name"
}

/** A label stands for one zone offset: `[letters, offset east of UTC in minutes]`. */
type Abbreviation = readonly [string, number]

/**
 * Corrections and gaps of the two libraries: zone -> its standard and, for a zone with
 * daylight time, daylight abbreviation, each with the offset it stands for. An entry
 * comes first in the chain; an empty list says the libraries' abbreviation for this zone
 * is wrong (a neighbour's name, or a standard time at the wrong offset), so the zone's
 * city name is used. `test/run.test.ts` checks every entry against the zone's offsets.
 */
export const ZONE_OVERRIDES: Readonly<Record<string, readonly Abbreviation[]>> = {
    // tzdb groups them with a neighbour of the same clock: Mawson, Kosrae
    "Antarctica/Vostok": [["VOST", 300]],
    "Pacific/Pohnpei": [["PONT", 660]],
    "Pacific/Ponape": [["PONT", 660]],
    // tzdb: PGT (Papua New Guinea) for Yap, CST (China) at +06 for Xinjiang
    "Pacific/Yap": [],
    "Asia/Urumqi": [],
    "Asia/Kashgar": [],
    // tzdb: GMT for Troll (tzdata: +00 and +02, no GMT)
    "Antarctica/Troll": [],
    // tzdb: CLT (Chile Standard Time, standard offset -04) at their permanent -03
    "America/Punta_Arenas": [],
    "America/Coyhaique": [],
    "Antarctica/Palmer": [],
    "Antarctica/Rothera": [],
}

/** Letters only, 3 to `max` of them (a mixed `GMT+5` or `-03` is no abbreviation). */
const isAbbreviation = (text: string, max: number): boolean =>
    new RegExp(`^\\p{L}{3,${max}}$`, "u").test(text)

/** The offset east of UTC, in minutes, of a moment zone at an instant. */
const momentOffset = (zone: moment.MomentZone, ms: number): number => 0 - zone.utcOffset(ms)

/** The curated tzdb entry of every IANA name it knows (the entry's `group`), once. */
let tzdbByName: Map<string, TimeZone> | undefined
function tzdbEntry(name: string): TimeZone | undefined {
    if (tzdbByName === undefined) {
        tzdbByName = new Map()
        for (const entry of getTimeZones())
            for (const alias of entry.group) tzdbByName.set(alias, entry)
    }
    return tzdbByName.get(name)
}

/** The offsets a zone had on the first of every month of the year of `ms`. */
function yearOffsets(zone: moment.MomentZone, ms: number): Set<number> {
    const year = new Date(ms).getUTCFullYear()
    const offsets = new Set<number>()
    for (let month = 0; month < 12; month++)
        offsets.add(momentOffset(zone, Date.UTC(year, month, 1)))
    return offsets
}

/**
 * A curated abbreviation, only when the offset it stands for is the stamp's: the
 * standard one at the standard offset, the daylight one at the other offset the zone has
 * that year (never a winter label in summer, nor the reverse).
 */
function curated(
    zone: moment.MomentZone,
    ms: number,
    offset: number,
    standard: Abbreviation,
    daylight: Abbreviation | undefined,
): string | undefined {
    if (standard[1] === offset) return standard[0]
    if (daylight?.[1] === offset && yearOffsets(zone, ms).has(offset)) return daylight[0]
    return undefined
}

/**
 * The offset the daylight abbreviation of a tzdb entry stands for in the year of `ms`:
 * the zone's offset of that year that is not the standard one (`undefined` if none).
 */
function daylightOffset(
    zone: moment.MomentZone,
    ms: number,
    raw: number,
): number | undefined {
    return [...yearOffsets(zone, ms)].find((offset) => offset !== raw)
}

/** Whether two IANA names have the same clock history (a link, not a neighbour). */
function sameClock(a: moment.MomentZone, b: moment.MomentZone): boolean {
    const key = (z: moment.MomentZone) => JSON.stringify([z.abbrs, z.offsets, z.untils])
    return key(a) === key(b)
}

/** The letters of a name, NFC-normalised, whitespace and punctuation removed. */
const lettersOf = (text: string): string => text.normalize("NFC").replace(/[^\p{L}]/gu, "")

/** The number words of the fixed `Etc/GMT+N` zones, N = 1 to 14. */
const NUMBER_WORDS = [
    "", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten",
    "Eleven", "Twelve", "Thirteen", "Fourteen",
]

/** A fixed `Etc/GMT+5` zone read as words, as IANA names it: `GMTplusFive`. */
function fixedName(segment: string): string {
    const [, sign, digits] = /^GMT([+-])(\d+)$/.exec(segment) ?? []
    const word = NUMBER_WORDS[Number(digits)] ?? ""
    return `GMT${sign === "+" ? "plus" : "minus"}${word}`
}

/** A name without accents or case, for comparing a city with an IANA name. */
const folded = (text: string): string =>
    text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase()

/**
 * The official name of a zone's city from its tzdb entry: the listed city the IANA name
 * spells (`Sao_Paulo` -> `São Paulo`), else the entry's main city when the zone has the
 * same clock history as the entry's own zone (not for a zone of [[ZONE_OVERRIDES]]: a
 * neighbour of the same clock is no link); "" when neither.
 */
function cityName(
    zone: moment.MomentZone,
    iana: string,
    entry: TimeZone | undefined,
    alone: boolean,
): string {
    if (entry === undefined) return ""
    const own = folded((iana.split("/").pop() as string).replace(/_/g, " "))
    const listed = entry.mainCities.find((city) => folded(city) === own)
    if (listed !== undefined) return lettersOf(listed)
    const main = moment.tz.zone(entry.name)
    if (alone || main === null || !sameClock(zone, main)) return ""
    return lettersOf(entry.mainCities[0] ?? "")
}

/**
 * The label of an IANA zone at an instant, with the link of the chain that gave it. The
 * chain: (1) the `moment-timezone` abbreviation when it is 3 or 4 letters and its offset
 * is the stamp's; (2) the curated abbreviation of `@vvo/tzdb` (or of [[ZONE_OVERRIDES]]),
 * only when the offset it stands for is the stamp's; (3) the official name of the zone's
 * main city from `@vvo/tzdb`, accents kept, whitespace and punctuation removed; (4) the
 * IANA name's last segment, without underscores. `GMT` and `UTC` are never a stand-in.
 *
 * @param iana - the IANA zone name (`America/Sao_Paulo`).
 * @param ms - the instant, Unix ms.
 * @param offsetMinutes - the stamp's offset east of UTC, in minutes.
 * @returns the label (letters only, NFC) and its source.
 */
export function zoneLabelWithSource(
    iana: string,
    ms: number,
    offsetMinutes: number,
): ZoneLabelResult {
    const zone = moment.tz.zone(iana)
    const segment = iana.split("/").pop() as string
    if (zone === null) return { label: lettersOf(segment), source: "name" }
    const abbr = zone.abbr(ms)
    const consistent = momentOffset(zone, ms) === offsetMinutes
    if (consistent && isAbbreviation(abbr, 4))
        return { label: abbr.toUpperCase(), source: "moment" }
    const entry = tzdbEntry(iana)
    const given = ZONE_OVERRIDES[iana]
    if (given?.[0] !== undefined) {
        const label = curated(zone, ms, offsetMinutes, given[0], given[1])
        if (label !== undefined) return { label, source: "override" }
    }
    if (entry !== undefined && given === undefined) {
        const raw = entry.rawOffsetInMinutes
        const dst = daylightOffset(zone, ms, raw)
        const daylight =
            entry.dstAbbreviation !== undefined && dst !== undefined
                ? ([entry.dstAbbreviation, dst] as const)
                : undefined
        const label = curated(zone, ms, offsetMinutes, [entry.abbreviation, raw], daylight)
        if (label !== undefined && isAbbreviation(label, 5))
            return { label: label.toUpperCase(), source: "tzdb" }
    }
    const city = cityName(zone, iana, entry, given !== undefined)
    if (city.length >= 3) return { label: city, source: "city" }
    if (/^Etc\/GMT[+-]\d/.test(iana)) return { label: fixedName(segment), source: "name" }
    return { label: lettersOf(segment), source: "name" }
}

/**
 * The label of a zone for a run folder name (the chain of [[zoneLabelWithSource]]).
 * Julia's `_zone_label` has no tzdb: it keeps the platform's letters or the zone name.
 *
 * @param iana - the IANA zone name.
 * @param ms - the instant, Unix ms.
 * @param offsetMinutes - the stamp's offset east of UTC, in minutes.
 * @returns the label, 3 or more Unicode letters.
 */
export function zoneLabel(iana: string, ms: number, offsetMinutes: number): string {
    return zoneLabelWithSource(iana, ms, offsetMinutes).label
}

/** The label of this machine's time zone at an instant. */
function localZoneLabel(ms: number, offsetMinutes: number): string {
    const iana = new Intl.DateTimeFormat().resolvedOptions().timeZone
    return zoneLabel(iana, ms, offsetMinutes)
}

/**
 * The name of a run folder, the ONE definition of it (Julia's is `_run_stamp` in
 * `src/Pipeline/RunProject.jl`; both give the same text for the same instant, offset and
 * label): the local wall-clock time, the zone label, the offset from UTC and the local
 * date, `23-35-29-123_EST_-0500_2026-11-07`. Only digits, letters, hyphens and
 * underscores, so it needs no quoting anywhere.
 *
 * @param ms - the instant, Unix ms.
 * @param offsetMinutes - the zone's offset east of UTC in minutes (this machine's zone at
 *     `ms` when left out; tests give one).
 * @param zone - the label (this machine's when left out; 3 or 4 letters).
 * @returns the name.
 */
export function runStamp(
    ms: number,
    offsetMinutes: number = -new Date(ms).getTimezoneOffset(),
    zone: string = localZoneLabel(ms, offsetMinutes),
): string {
    const t = new Date(ms + offsetMinutes * 60000)
    const abs = Math.abs(offsetMinutes)
    const sign = offsetMinutes < 0 ? "-" : "+"
    const offset = `${sign}${pad(Math.floor(abs / 60), 2)}${pad(abs % 60, 2)}`
    const time = [t.getUTCHours(), t.getUTCMinutes(), t.getUTCSeconds()]
    const hms = time.map((n) => pad(n, 2)).join("-")
    const clock = `${hms}-${pad(t.getUTCMilliseconds(), 3)}`
    const day = `${pad(t.getUTCFullYear(), 4)}-${pad(t.getUTCMonth() + 1, 2)}`
    return `${clock}_${zone}_${offset}_${day}-${pad(t.getUTCDate(), 2)}`
}

/**
 * How a screen shows the name of a run: `23:35:29:123 EST -05:00 · 2026-11-07` for a name
 * of the current format (never the colon-less disk name), the same form with `UTC +00:00`
 * and `000` ms for an older `yyyyMMddTHHmmssZ` name, so that all rows look alike. A name
 * that is neither is shown as it is. Pure; every screen uses it.
 *
 * @param raw - the run folder's name.
 * @returns the text.
 */
export function runDisplay(raw: string): string {
    const name = raw.normalize("NFC")
    const m = runNameFormat.exec(name)
    if (m !== null && parseRunStamp(name) !== undefined) {
        const zone = name.split("_")[1] as string
        const clock = `${m[1]}:${m[2]}:${m[3]}:${m[4]}`
        return `${clock} ${zone} ${m[5]}${m[6]}:${m[7]} · ${m[8]}-${m[9]}-${m[10]}`
    }
    const old = oldRunNameFormat.exec(name)
    if (old !== null && parseRunStamp(name) !== undefined) {
        const day = `${old[1]}-${old[2]}-${old[3]}`
        return `${old[4]}:${old[5]}:${old[6]}:000 UTC +00:00 · ${day}`
    }
    return raw
}

/**
 * The name of a run in as few cells as tell two runs apart, `14:19:18 2026-11-09` (the
 * clock to the second and the date, no milliseconds or zone), for a question or a note
 * that has little room. A name that is not of either format is returned as it is.
 *
 * @param raw - the run folder's name.
 * @returns the text, 19 cells for a real run.
 */
export function runBrief(raw: string): string {
    const name = raw.normalize("NFC")
    const m = runNameFormat.exec(name)
    if (m !== null && parseRunStamp(name) !== undefined)
        return `${m[1]}:${m[2]}:${m[3]} ${m[8]}-${m[9]}-${m[10]}`
    const old = oldRunNameFormat.exec(name)
    if (old !== null && parseRunStamp(name) !== undefined)
        return `${old[4]}:${old[5]}:${old[6]} ${old[1]}-${old[2]}-${old[3]}`
    return raw
}

/** The ms of a UTC date and time, `undefined` when that day or time does not exist. */
function utcInstant(
    y: number,
    mo: number,
    d: number,
    h: number,
    mi: number,
    s: number,
    ms: number,
): number | undefined {
    if (h > 23 || mi > 59 || s > 59) return undefined
    const date = new Date(0)
    date.setUTCFullYear(y, mo - 1, d)
    date.setUTCHours(h, mi, s, ms)
    const real = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate()]
    return real.join() === [y, mo, d].join() ? date.getTime() : undefined
}

/**
 * The instant a run folder name denotes: the local time minus its offset, or the UTC time
 * of the older `yyyyMMddTHHmmssZ` name.
 *
 * @param raw - the folder name (NFC-normalised first: macOS may return it decomposed).
 * @returns Unix ms, `undefined` when the name is neither format (a near miss included).
 */
export function parseRunStamp(raw: string): number | undefined {
    const name = raw.normalize("NFC")
    const m = runNameFormat.exec(name)
    if (m !== null) {
        const [h, mi, s, ms, oh, om, y, mo, d] = [1, 2, 3, 4, 6, 7, 8, 9, 10].map((i) =>
            Number(m[i]),
        ) as [number, number, number, number, number, number, number, number, number]
        if (oh > 23 || om > 59) return undefined
        const local = utcInstant(y, mo, d, h, mi, s, ms)
        const offset = (oh * 60 + om) * 60000 * (m[5] === "-" ? -1 : 1)
        return local === undefined ? undefined : local - offset
    }
    const old = oldRunNameFormat.exec(name)
    if (old === null) return undefined
    const [y, mo, d, h, mi, s] = old.slice(1).map(Number) as [
        number, number, number, number, number, number,
    ]
    return utcInstant(y, mo, d, h, mi, s, 0)
}

/**
 * Orders run folder names by the instant they denote, oldest first, in either format. A
 * name that is neither format sorts before every real one (so it comes last in the
 * newest-first lists), among its kind by name; equal instants by name.
 */
export function compareRunNames(a: string, b: string): number {
    const ta = parseRunStamp(a)
    const tb = parseRunStamp(b)
    if (ta !== undefined && tb !== undefined && ta !== tb) return ta - tb
    if (ta === undefined !== (tb === undefined)) return ta === undefined ? -1 : 1
    return a < b ? -1 : a > b ? 1 : 0
}

/**
 * The names of the runs of a project.
 *
 * @returns the folder names under `runs/` (not the dot-names, which are locks), oldest
 *     first by the instant the name denotes ([[compareRunNames]]); empty if the folder is
 *     not there.
 */
export function runIds(projectDir: string): string[] {
    const dir = join(projectDir, runsFolder)
    return entryNames(dir)
        // a name with a dot in front is a lock (`.start.lock`), never a run
        .filter((name) => !name.startsWith(".") && isFolder(join(dir, name)))
        .sort(compareRunNames)
}

/** Whether a project has at least one run folder. */
export function hasRuns(projectDir: string): boolean {
    return runIds(projectDir).length > 0
}

/**
 * How one run ended, from its `run.json`.
 *
 * @returns the status, or `undefined` when the file is missing, unreadable or says
 *     something else.
 */
export function runStatus(projectDir: string, id: string): RunStatus | undefined {
    const status = readObject(join(projectDir, runsFolder, id, runFileName))?.status
    return typeof status === "string" && statuses.includes(status)
        ? (status as RunStatus)
        : undefined
}

/** The folder of a run. */
export function runDirOf(projectDir: string, id: string): string {
    return join(projectDir, runsFolder, id)
}

/** The error of a start or a deletion refused because a run is live. */
export class RunInProgressError extends Error {
    constructor(readonly pid: number) {
        super(`a run is in progress (pid ${pid})`)
    }
}

/**
 * The JSON object in a file.
 *
 * @returns the object, or `undefined` when the file is missing, unreadable or no object.
 */
function readObject(file: string): Record<string, unknown> | undefined {
    const value = readJson<undefined>(file, undefined)
    return isDict(value) ? value : undefined
}

/**
 * A run folder as the lists read it: its name, folder and `run.json` object.
 *
 * @property id - the run's name.
 * @property dir - the run folder.
 * @property json - the `run.json` object, `undefined` when missing or unreadable.
 */
export type RunEntry = {
    id: string
    dir: string
    json: Record<string, unknown> | undefined
}

/**
 * The runs of a project, newest first, each with its `run.json` read: the one walk the
 * run list and the `open runs` list share.
 *
 * @returns one entry per run folder that is still there when it is read (one deleted
 *     since the listing is skipped).
 */
export function newestRuns(projectDir: string): RunEntry[] {
    const entries: RunEntry[] = []
    for (const id of runIds(projectDir).reverse()) {
        const dir = runDirOf(projectDir, id)
        if (!isFolder(dir)) continue // deleted since `runIds` looked
        entries.push({ id, dir, json: readObject(join(dir, runFileName)) })
    }
    return entries
}

/**
 * The default of the temperature prompt: the `temperature_c` row (`name<spaces><TAB>value`,
 * in the header that ends at the first `---`) of the newest FINISHED run's
 * `logs/run.LOG`. A run that is live or aborted, or whose log is missing or has no such
 * row, is skipped for the next older one.
 *
 * @param projectDir - the project's folder.
 * @returns the temperature in °C, or `undefined` when no run has one.
 */
export function defaultTemperature(projectDir: string): number | undefined {
    for (const { dir, json } of newestRuns(projectDir)) {
        if (json?.status !== "done" && json?.status !== "failed") continue
        try {
            // the log of a packed run is read from its archive, a plain one from its folder
            const log = readRunText(dir, "logs/run.LOG", RUN_FLOW.log.maxBytes)
            const header = log.split(/^---/m)[0] ?? ""
            const t = Number(/^temperature_c[ \t]*\t[ \t]*(\S+)/m.exec(header)?.[1])
            if (Number.isFinite(t)) return t
        } catch {
            // no log: the next older run
        }
    }
    return undefined
}

/** The time of a `yyyy-MM-ddTHH:mm:ssZ` string, the way Julia writes times. */
function isoTime(text: unknown): number | undefined {
    if (typeof text !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(text))
        return undefined
    const t = Date.parse(text)
    return Number.isNaN(t) ? undefined : t
}

/** A time as Julia writes it. */
export function isoStamp(ms: number): string {
    return `${new Date(ms).toISOString().slice(0, 19)}Z`
}

/**
 * Whether a process with this id exists on this machine (a process of another user, which
 * the system will not let us signal, exists too).
 */
function pidExists(pid: number): boolean {
    try {
        process.kill(pid, 0)
        return true
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === "EPERM"
    }
}

/** Whether a time is recent enough for a heartbeat. */
const fresh = (time: number | undefined, now: number): boolean =>
    time !== undefined && now - time < RUN_FLOW.liveness.staleSeconds * 1000

/**
 * The pid of a live run, which is Julia's rule exactly: its `run.json` says `running`,
 * the heartbeat is under a minute old and, when the run is on this host, its process
 * exists. A run folder that has no `run.json` yet but a fresh claim marker of a living
 * starter (Julia is still loading) is live too. A file that cannot be read is no run.
 *
 * @returns the pid (0 when it is not known), or `undefined` when the run is not live.
 */
export function livePid(runDir: string, now: number = Date.now()): number | undefined {
    const json = readObject(join(runDir, runFileName))
    if (json !== undefined && json.status !== "running") return undefined
    const record = json ?? readObject(join(runDir, CLAIM_FILE))
    if (record === undefined) return undefined
    if (!fresh(isoTime(json ? record.heartbeat : record.time), now)) return undefined
    const pid = Number.isInteger(record.pid) ? (record.pid as number) : undefined
    if (pid !== undefined && record.host === hostname() && !pidExists(pid)) return undefined
    return pid ?? 0
}

/** The live run of a project, if there is one (a project has at most one). */
export function liveRun(
    projectDir: string,
    now: number = Date.now(),
): { id: string; pid: number } | undefined {
    for (const id of runIds(projectDir)) {
        const pid = livePid(runDirOf(projectDir, id), now)
        if (pid !== undefined) return { id, pid }
    }
    return undefined
}

/**
 * Refuses when a run of the project is live.
 *
 * @throws [[RunInProgressError]] (`a run is in progress (pid N)`).
 */
export function assertNoLiveRun(projectDir: string): void {
    const live = liveRun(projectDir)
    if (live !== undefined) throw new RunInProgressError(live.pid)
}

/**
 * Gives a run that is not being run any more its final status, by an atomic replace of
 * `run.json` under its lock. The status is only changed when it is `running` NOW (the
 * file is read again under the lock), and with `ifStale` only when the run is not live
 * either, so a run of another copy that is alive is never touched. A run folder that has
 * no `run.json` (a start that never got to Julia) gets a small one.
 *
 * @param options - `ifStale`: leave a live run alone (the startup sweep); without it the
 *     caller knows the run is over (its own child has exited).
 * @throws FileInUseError if another copy holds the lock of `run.json` for 3 s.
 */
export function settleRun(
    runDir: string,
    status: RunStatus,
    options: { ifStale?: boolean } = {},
): boolean {
    const file = join(runDir, runFileName)
    return withFileLock(
        file,
        () => {
            const json = readObject(file)
            const ended = isoStamp(Date.now())
            if (json !== undefined) {
                if (json.status !== "running") return false
                if (options.ifStale && livePid(runDir) !== undefined) return false
                writeAtomic(
                    file,
                    writeJson({ ...json, status, ended: json.ended ?? ended }),
                    { createParents: false },
                )
                return true
            }
            const claim = readObject(join(runDir, CLAIM_FILE))
            // no file and no claim is no run of ours: not a folder to name a status for
            if (options.ifStale && (claim === undefined || livePid(runDir) !== undefined))
                return false
            const started = isoTime(claim?.time) === undefined ? ended : claim?.time
            writeAtomic(
                file,
                writeJson({ schema: 1, status, ui: "tui", started, ended }),
                { createParents: false },
            )
            return true
        },
        { createParents: false },
    )
}

/**
 * The startup sweep for one project: every `running` run that is not live (its Julia was
 * killed, its machine rebooted, its starter died) becomes `interrupted`, each under the
 * lock of its `run.json` after the staleness is checked again. It also runs under the
 * project's `.start` lock, so it never meets a folder in the middle of being claimed.
 *
 * @throws FileInUseError if a lock stays taken for 3 s.
 */
export function markStaleRuns(projectDir: string): string[] {
    const runs = join(projectDir, runsFolder)
    if (!isFolder(runs)) return []
    return withFileLock(
        join(runs, startLockName),
        () =>
            runIds(projectDir).filter((id) =>
                settleRun(runDirOf(projectDir, id), "interrupted", { ifStale: true }),
            ),
        { createParents: false },
    )
}

// ========================================================================================
// 2. Projects
// ========================================================================================

/**
 * The projects: one folder for each in the `projects` folder of the BAYSOL folder, named
 * by its id (the name the user typed). A folder is a project when it has a `project.json`
 * that says so (`{"id": "name", "created": "<time>"}` with the id of the folder's own
 * name); any other folder or file there is not one and is left alone, but its name is
 * taken.
 *
 * A new project gets an exact copy of the global `settings.json` as its own, which is its
 * starting point; what it changes after that is the project's alone. The copy is the
 * business of the settings module, so [[createProject]] takes it as a hook.
 *
 * A name must be new in the folder, without regard to case (a file system that does not
 * tell `Run` from `run` would not keep two apart), and a name that every system accepts:
 * letters, digits, `.`, `_` and `-`, starting with a letter or a digit, not ending in
 * `.`, at most 40 characters, and not a name a Windows device has (`con`, `nul`,
 * `com1`, ...).
 */

/**
 * A project the user is working in.
 *
 * @property id - the project's name (also its folder's name).
 * @property dir - the project's folder.
 */
export type ProjectRef = { id: string; dir: string }

/** The most characters a project name may have. */
const maxName = 40

/** The name of the file that makes a folder a project. */
const projectFileName = "project.json"

/** Names a Windows file system keeps for devices, whatever the extension. */
const reserved: ReadonlySet<string> = new Set([
    "con",
    "prn",
    "aux",
    "nul",
    ...[1, 2, 3, 4, 5, 6, 7, 8, 9].flatMap((n) => [`com${n}`, `lpt${n}`]),
])

/** What a name may be made of: the characters every file system takes. */
const nameCharacters = /^[A-Za-z0-9._-]+$/

/** What a name must start with. */
const nameStart = /^[A-Za-z0-9]/

/** The message of a name that is taken by a project or by anything else in the folder. */
const takenMessage = "that project already exists!"

/** The message of a name that is taken by a folder with a `project.json` of no use. */
const brokenMessage = "that name is taken by a broken project folder!"

/**
 * What is wrong with `id` as the name of a new project, as a short message (the main
 * menu has room for 29 characters; the one for a broken folder is longer and the menu
 * makes room). The checks run in this order: empty, too long, characters, the first
 * character, a trailing dot, a reserved name, a name taken by a broken project folder,
 * a name taken.
 *
 * @param existing - every name already in the projects folder, projects or not.
 * @param broken - the names of the folders that have a `project.json` that cannot be
 *     used ([[brokenNames]]): they are neither listed nor free.
 */
export function projectNameProblem(
    id: string,
    existing: readonly string[],
    broken: readonly string[] = [],
): string | undefined {
    const lower = id.toLowerCase()
    const same = (names: readonly string[]) => names.some((n) => n.toLowerCase() === lower)
    if (id.trim() === "") return "type a name first!"
    if (id.length > maxName) return tooLong("name", maxName)
    if (!nameCharacters.test(id)) return "use only a-z 0-9 . _ -"
    if (!nameStart.test(id)) return "start with a letter or digit"
    if (id.endsWith(".")) return "must not end with a dot"
    if (reserved.has(lower.split(".")[0] ?? "")) return "reserved name, pick another"
    if (same(broken)) return brokenMessage
    if (same(existing)) return takenMessage
    return undefined
}

/**
 * What a `project.json` holds.
 *
 * @property id - the project's name, the same as its folder's.
 * @property created - the time it was made (ISO 8601, UTC), if the file says.
 */
export type ProjectInfo = {
    id: string
    created?: string
}

/**
 * The `project.json` of a project folder.
 *
 * @returns what it holds, or `undefined` if the folder is not a project: no such file,
 *     text that is not JSON, not an object, or an `id` that is not the folder's name.
 */
export function readProject(dir: string): ProjectInfo | undefined {
    const file = join(dir, projectFileName)
    if (!isFile(file)) return undefined
    const info = readJson<undefined>(file, undefined)
    if (!isDict(info)) return undefined
    if (info.id !== basename(dir)) return undefined
    const created = info.created
    return typeof created === "string" ? { id: info.id, created } : { id: info.id }
}

/**
 * The names of the folders of a projects folder that have a `project.json` that cannot
 * be used ([[readProject]]): [[listProjects]] hides them, but their names are taken.
 */
export function brokenNames(root: string): string[] {
    return entryNames(root).filter((name) => {
        const dir = join(root, name)
        return isFolder(dir) && isFile(join(dir, projectFileName)) && !readProject(dir)
    })
}

/**
 * The ids of the projects in a projects folder.
 *
 * @returns the ids, sorted without regard to case; empty if there is none.
 */
export function listProjects(root: string): string[] {
    const projects = entryNames(root).filter((name) => {
        const dir = join(root, name)
        return isFolder(dir) && readProject(dir) !== undefined
    })
    return sortNoCase(projects)
}

/**
 * The error of a write into a project whose folder is gone (another copy of the program
 * deleted the project). Nothing is made then: a write must not bring a deleted project
 * back as a broken folder that blocks its name.
 */
export class ProjectGoneError extends ParentMissingError {
    constructor(readonly projectDir: string) {
        super(projectDir)
        this.message = `project ${basename(projectDir)} no longer exists`
    }
}

/**
 * Runs a write inside a project's folder, which must exist already. Use
 * `createParents: false` ([[FolderOptions]]) for the folders the work makes itself.
 *
 * @throws [[ProjectGoneError]] if the folder is not there before the work or goes
 *     missing during it; whatever `fn` throws.
 */
export function inProject<T>(projectDir: string, fn: () => T): T {
    if (!isFolder(projectDir)) throw new ProjectGoneError(projectDir)
    try {
        return fn()
    } catch (error) {
        const gone =
            error instanceof ParentMissingError ||
            (error as NodeJS.ErrnoException).code === "ENOENT"
        if (gone && !isFolder(projectDir)) throw new ProjectGoneError(projectDir)
        throw error
    }
}

/** [[inProject]] around the files' locks (nested, in order, never making parents). */
export function lockedIn<T>(projectDir: string, files: string | string[], fn: () => T): T {
    const options = { createParents: false }
    const locked = (rest: string[]): T =>
        rest.length === 0
            ? fn()
            : withFileLock(rest[0], () => locked(rest.slice(1)), options)
    return inProject(projectDir, () => locked([files].flat()))
}

/**
 * The error of a name that is not valid or is taken.
 *
 * @param reason - what [[projectNameProblem]] says, short enough for the main menu.
 */
export class InvalidNameError extends Error {
    constructor(
        readonly reason: string,
        readonly id: string,
    ) {
        super(reason)
    }
}

/**
 * What [[createProject]] leaves to the settings module.
 *
 * @property prepareGlobal - makes and checks the global `settings.json` before anything
 *     is made (it may throw: then no project is made).
 * @property copySettings - copies the global `settings.json` into the folder it is given
 *     as the project's own (it may throw: the half-made project is removed).
 */
export type CreateHooks = {
    prepareGlobal: () => void
    copySettings: (projectDir: string) => void
}

/**
 * Makes a project: its folder, its `project.json` and, through the hook, an exact copy
 * of the global settings.
 *
 * @throws [[InvalidNameError]] if the name is not valid or is taken, and anything the
 *     hooks throw. A project that was half made is removed again (only the folder this
 *     call made).
 */
export function createProject(
    appRoot: string,
    id: string,
    hooks: CreateHooks,
    now: Date = new Date(),
): string {
    const root = ensureDir(projectsRoot(appRoot))
    const problem = projectNameProblem(id, entryNames(root), brokenNames(root))
    if (problem !== undefined) throw new InvalidNameError(problem, id)
    const dir = join(root, id)
    hooks.prepareGlobal()
    try {
        mkdirSync(dir)
    } catch {
        throw new InvalidNameError(takenMessage, id)
    }
    try {
        writeAtomic(
            join(dir, projectFileName),
            writeJson({ id, created: now.toISOString() }),
        )
        hooks.copySettings(dir)
        return dir
    } catch (error) {
        rmSync(dir, { recursive: true, force: true })
        throw error
    }
}

/**
 * Deletes a project: its folder and everything in it, for good. Because this removes
 * what the user made, it checks first and deletes nothing unless every check passes:
 * the id is a valid project name (so it cannot be a path: no `/`, no `..`, no empty
 * name), the folder is a real directory (not a symbolic link, which could lead
 * anywhere) directly below `<root>/projects`, and it is a project (a readable
 * `project.json` with the same id), and no run of it is live (that check runs under the
 * lock that claims a run, so no run can start between the check and the removal).
 *
 * @throws [[RunInProgressError]] (`a run is in progress (pid N)`) for a live run; Error
 *     with a clear message when a check fails; nothing is deleted then. A
 *     folder that is already gone is not an error (it was deleted meanwhile).
 */
export function deleteProject(appRoot: string, id: string): void {
    if (id === "" || !nameCharacters.test(id) || !nameStart.test(id))
        throw new Error(`not a project name: "${id}"`)
    const dir = join(projectsRoot(appRoot), id)
    let stat: ReturnType<typeof lstatSync>
    try {
        stat = lstatSync(dir)
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return
        throw error
    }
    if (stat.isSymbolicLink()) throw new Error(`${id} is a link, not a project folder`)
    if (!stat.isDirectory()) throw new Error(`${id} is not a folder`)
    if (readProject(dir)?.id !== id) throw new Error(`${id} is not a valid project`)
    // a live run protects its project; the check shares the lock that claims a run, so a
    // run cannot be started between the check and the removal
    const runs = join(dir, "runs")
    if (isFolder(runs))
        withFileLock(
            join(runs, startLockName),
            () => {
                assertNoLiveRun(dir)
                rmSync(dir, { recursive: true, force: true })
            },
            { createParents: false },
        )
    else rmSync(dir, { recursive: true, force: true })
}

// ========================================================================================
// 3. Models
// ========================================================================================

/**
 * The models of a project: the structure files (`.cif` or `.pdb`) in its `models/`
 * folder. A model is always a COPY of the file the user named, never the file itself, so
 * adding one cannot lose anything; the only way a model leaves the folder is
 * [[deleteModel]], which the screen asks twice for. A project with no `models/` folder,
 * or an empty one, or one whose files were all deleted, has no models: nothing here
 * tells these apart ([[listModels]] is empty for all three, and the folder is never
 * removed).
 */

/** The file modelExtensions a model may have, lower case, without the dot. */
const modelExtensions: ReadonlySet<string> = new Set(["cif", "pdb"])

/** The message for a copy that failed for a reason the checks could not see. */
export const copyFailed = "could not copy the file!"

/**
 * The `models/` folder of a project.
 *
 * @param projectDir - the project's folder.
 * @returns `<project>/models`; it may not exist yet.
 */
export function modelsDir(projectDir: string): string {
    return join(projectDir, "models")
}

/**
 * Whether a file name has an extension a model may have.
 *
 * @param fileName - the name.
 * @returns the answer (case does not matter).
 */
export function accepted(fileName: string): boolean {
    const dot = fileName.lastIndexOf(".")
    return dot >= 0 && modelExtensions.has(fileName.slice(dot + 1).toLowerCase())
}

/**
 * The names of the models of a project.
 *
 * @param projectDir - the project's folder.
 * @returns the `.cif` and `.pdb` files in its `models/` folder, sorted without regard
 *     to case; empty when there are none, whether the folder is missing, empty or
 *     emptied.
 */
export function listModels(projectDir: string): string[] {
    const dir = modelsDir(projectDir)
    const files = entryNames(dir).filter(
        (name) => accepted(name) && isFile(join(dir, name)),
    )
    return sortNoCase(files)
}

/** The model prompt takes only structure files. */
const ONLY_STRUCTURES = { accept: accepted, message: "only .cif and .pdb files" }

/**
 * What is wrong with a path as the file to add as a model.
 *
 * The checks run in this order: empty, not absolute, not there, a folder, the wrong
 * kind of file, not readable, name taken.
 *
 * @param path - the path typed.
 * @param existing - the names of the models there are.
 * @returns a short message (42 characters at most), or `undefined` if it is fine.
 */
export function modelPathProblem(
    path: string,
    existing: readonly string[],
): string | undefined {
    const problem = checkPath(path, 42, ONLY_STRUCTURES)
    if (problem !== undefined) return problem
    const lower = basename(path).toLowerCase()
    return existing.some((n) => n.toLowerCase() === lower)
        ? "a model with that name exists"
        : undefined
}

/**
 * Copies a file into the `models/` folder of a project, made if need be, under the same
 * name. The original is not touched, and a model that is there is never overwritten.
 *
 * @param projectDir - the project's folder.
 * @param path - the file to copy.
 * @returns the copy.
 * @throws ProjectGoneError if the project's folder does not exist (it is not made);
 *     an error if the copy cannot be made, a model of that name being there included;
 *     nothing is deleted then.
 */
export function addModel(projectDir: string, path: string): string {
    const dir = modelsDir(projectDir)
    const target = join(dir, basename(path))
    return inProject(projectDir, () => {
        try {
            mkdirSync(dir) // not recursive: the project's folder must be there
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error
        }
        copyFileSync(path, target, constants.COPYFILE_EXCL)
        return target
    })
}

/**
 * The outcome of [[addModels]].
 *
 * @property copied - the names of the models added.
 * @property skipped - the paths left out, each with its reason.
 */
export type AddResult = {
    copied: string[]
    skipped: [path: string, reason: string][]
}

/**
 * Adds each of the files as [[addModel]] does; the ones that fail [[modelPathProblem]] (or
 * whose copy fails) are left out. A name that comes twice is added once (the first
 * wins). Nothing here throws.
 *
 * @param projectDir - the project's folder.
 * @param paths - the files.
 * @returns what was copied and what was skipped.
 */
export function addModels(projectDir: string, paths: readonly string[]): AddResult {
    const result: AddResult = { copied: [], skipped: [] }
    for (const path of paths) {
        const existing = [...listModels(projectDir), ...result.copied]
        let reason = modelPathProblem(path, existing)
        if (reason === undefined) {
            try {
                addModel(projectDir, path)
            } catch {
                reason = copyFailed
            }
        }
        if (reason === undefined) result.copied.push(basename(path))
        else result.skipped.push([path, reason])
    }
    return result
}

/**
 * Deletes a model from the `models/` folder of a project. This is destructive and there
 * is no way back, so only a file that [[listModels]] lists is deleted, by its plain name
 * (a name with a path in it is refused).
 *
 * @param projectDir - the project's folder.
 * @param modelName - the model's name.
 * @returns `true` if the file was deleted.
 */
export function deleteModel(projectDir: string, modelName: string): boolean {
    if (!listModels(projectDir).includes(modelName)) return false
    try {
        unlinkSync(join(modelsDir(projectDir), modelName))
        return true
    } catch {
        return false
    }
}
