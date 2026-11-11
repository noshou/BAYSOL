// SPDX-License-Identifier: LGPL-3.0-or-later

// Run stamps: the names of run folders (`HH-MM-SS-mmm_TZ_±HHMM_YYYY-MM-DD`), their
// zone labels, display forms, parsing and order. Run folders themselves are in
// `projects.ts`.

import { getTimeZones, type TimeZone } from "@vvo/tzdb"
import moment from "moment-timezone"

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
 * @param raw - the folder name (NFC-normalized first: macOS may return it decomposed).
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
