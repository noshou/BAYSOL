// SPDX-License-Identifier: LGPL-3.0-or-later

import { useSyncExternalStore } from "react"
import { sixelShown } from "../ui/sixel-view.js"
import { displayWidth } from "./terminal.js"

/**
 * The width in cells of the longest clock text over every IANA zone of
 * `Intl.supportedValuesOf("timeZone")`, every month of a year and every weekday
 * (measured 2026-11-27, `Wed, 22 Oct 2026, 22:30:30-<name> (UTC+10:00)` style strings;
 * `test/clock.test.ts` recomputes it and fails when this number is too small).
 */
export const CLOCK_MAX_CELLS = 53

const MINUTES_PER_HOUR = 60
const MS_PER_MINUTE = 60_000
const TICK_MS = 1000

/** Zero-pads a number to two digits. */
function pad2(n: number): string {
    return String(n).padStart(2, "0")
}

/** The three-letter month names `Intl` gives in `en-US`, in order. */
const MONTHS = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
]

/** A zone name `Intl` could not abbreviate: `GMT+1`, `GMT-3:30` (no letters of its own). */
const GMT_STYLE = /^GMT[+-]/

/** The parts of `date` in a zone, in one locale. */
function zoneParts(
    date: Date,
    locale: string,
    timeZone?: string,
): Intl.DateTimeFormatPart[] {
    return new Intl.DateTimeFormat(locale, {
        timeZone,
        weekday: "short",
        day: "2-digit",
        month: "short",
        year: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hourCycle: "h23",
        timeZoneName: "short",
    }).formatToParts(date)
}

/**
 * The name shown for a zone: its abbreviation (`CET`, `EST`, `UTC`; `en-US` first, then
 * `en-GB`), else, where no abbreviation exists, the place of its IANA name (`Dubai`,
 * `Sao Paulo`).
 */
function zoneName(date: Date, first: string, timeZone?: string): string {
    if (!GMT_STYLE.test(first)) return first
    const gb = zoneParts(date, "en-GB", timeZone).find((p) => p.type === "timeZoneName")
    if (gb !== undefined && !GMT_STYLE.test(gb.value)) return gb.value
    const id = timeZone ?? new Intl.DateTimeFormat().resolvedOptions().timeZone
    return (id.split("/").pop() ?? id).replace(/_/g, " ")
}

/**
 * The clock text `<Wkd>, dd Mon yyyy, hh:mm:ss-<name> (UTC+/-hh:mm)`, 24-hour, e.g.
 * `Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)` or
 * `Fri, 27 Nov 2026, 17:03:22-Dubai (UTC+04:00)`.
 *
 * @param date - the instant.
 * @param timeZone - an IANA zone name; the machine's zone when absent.
 * @returns the text (not padded).
 */
export function formatClock(date: Date, timeZone?: string): string {
    const parts = zoneParts(date, "en-US", timeZone)
    const get = (type: string): string => parts.find((p) => p.type === type)?.value ?? ""
    const local = Date.UTC(
        Number(get("year")),
        MONTHS.indexOf(get("month")),
        Number(get("day")),
        Number(get("hour")) % 24,
        Number(get("minute")),
        Number(get("second")),
    )
    const utc = Math.floor(date.getTime() / 1000) * 1000
    const minutes = Math.round((local - utc) / MS_PER_MINUTE)
    const sign = minutes < 0 ? "-" : "+"
    const abs = Math.abs(minutes)
    const hh = pad2(Math.floor(abs / MINUTES_PER_HOUR))
    const offset = `UTC${sign}${hh}:${pad2(abs % MINUTES_PER_HOUR)}`
    const hms = `${pad2(Number(get("hour")) % 24)}:${get("minute")}:${get("second")}`
    const name = zoneName(date, get("timeZoneName"), timeZone)
    const stamp = `${get("day")} ${get("month")} ${get("year")}`
    return `${get("weekday")}, ${stamp}, ${hms}-${name} (${offset})`
}

/** The clock text padded on the left to [[CLOCK_MAX_CELLS]], so ticking never shifts it. */
export function paddedClock(date: Date, timeZone?: string): string {
    const text = formatClock(date, timeZone)
    return " ".repeat(Math.max(0, CLOCK_MAX_CELLS - displayWidth(text))) + text
}

// One interval for the whole app: it runs while at least one component is subscribed.
const listeners = new Set<() => void>()
let timer: ReturnType<typeof setInterval> | undefined
let snapshot = paddedClock(new Date())

/**
 * How long after a tick a write to stdout counts as the clock's own frame, in milliseconds
 * (Ink renders the changed clock within a few frames of the tick).
 */
const CLOCK_WRITE_WINDOW_MS = 100

let lastTickAt = Number.NEGATIVE_INFINITY

/**
 * @returns whether a write to stdout now is probably the clock's frame (a tick came less
 *     than [[CLOCK_WRITE_WINDOW_MS]] ago). The screen refresh asks it so that the clock's
 *     one write a second does not restart its idle timer (it would never fire).
 */
export function clockWriting(): boolean {
    return Date.now() - lastTickAt < CLOCK_WRITE_WINDOW_MS
}

/** Reads the time; skipped while a sixel picture is shown (a frame would repaint it). */
function tick(): void {
    if (sixelShown()) return
    const next = paddedClock(new Date())
    if (next === snapshot) return
    snapshot = next
    lastTickAt = Date.now()
    for (const listener of [...listeners]) listener()
}

/** Subscribes to the ticks; the first subscriber starts the interval, the last stops it. */
function subscribe(listener: () => void): () => void {
    listeners.add(listener)
    if (timer === undefined) {
        snapshot = paddedClock(new Date())
        timer = setInterval(tick, TICK_MS)
        timer.unref()
    }
    return () => {
        listeners.delete(listener)
        if (listeners.size === 0 && timer !== undefined) {
            clearInterval(timer)
            timer = undefined
        }
    }
}

/** @returns the clock text, padded to [[CLOCK_MAX_CELLS]]; re-renders each second. */
export function useClock(): string {
    return useSyncExternalStore(subscribe, () => snapshot)
}

/** @returns the number of live subscribers (for tests: no timer leaks). */
export function clockSubscribers(): number {
    return listeners.size
}
