// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    CLOCK_MAX_CELLS,
    clockSubscribers,
    formatClock,
    paddedClock,
} from "../src/core/clock.js"
import { displayWidth } from "../src/core/terminal.js"

const WINTER = new Date("2026-01-16T13:03:22Z")
const SUMMER = new Date("2026-07-17T12:03:22Z")

test("formatClock in fixed zones", () => {
    const f = (d: Date, z: string): string => formatClock(d, z)
    assert.equal(f(WINTER, "Europe/Berlin"), "Fri, 16 Jan 2026, 14:03:22-CET (UTC+01:00)")
    assert.equal(f(SUMMER, "Europe/Berlin"), "Fri, 17 Jul 2026, 14:03:22-CEST (UTC+02:00)")
    assert.equal(f(WINTER, "UTC"), "Fri, 16 Jan 2026, 13:03:22-UTC (UTC+00:00)")
    const wk = "Fri, 16 Jan 2026"
    assert.equal(f(WINTER, "Asia/Kolkata"), `${wk}, 18:33:22-Kolkata (UTC+05:30)`)
    assert.equal(f(WINTER, "Asia/Kathmandu"), `${wk}, 18:48:22-Kathmandu (UTC+05:45)`)
    assert.equal(f(WINTER, "America/St_Johns"), `${wk}, 09:33:22-St Johns (UTC-03:30)`)
    assert.equal(f(WINTER, "America/Sao_Paulo"), `${wk}, 10:03:22-Sao Paulo (UTC-03:00)`)
})

test("US zones keep their abbreviation, midnight is 00", () => {
    assert.equal(
        formatClock(new Date("2026-01-16T05:00:01Z"), "America/New_York"),
        "Fri, 16 Jan 2026, 00:00:01-EST (UTC-05:00)",
    )
})

test("the padded text has the fixed width", () => {
    assert.equal(displayWidth(paddedClock(WINTER, "UTC")), CLOCK_MAX_CELLS)
})

test("CLOCK_MAX_CELLS covers every zone, month and weekday", () => {
    let max = 0
    for (const zone of Intl.supportedValuesOf("timeZone")) {
        for (let month = 0; month < 12; month++) {
            // days 1..7 of the month cover every weekday
            for (let day = 1; day <= 7; day++) {
                const when = new Date(Date.UTC(2026, month, day, 12, 30, 30))
                const text = formatClock(when, zone)
                max = Math.max(max, displayWidth(text))
            }
        }
    }
    assert.equal(max <= CLOCK_MAX_CELLS, true, `measured ${max}`)
    assert.equal(max, CLOCK_MAX_CELLS, "the constant is the measured maximum")
})

test("no subscriber is left", () => {
    assert.equal(clockSubscribers(), 0)
})
