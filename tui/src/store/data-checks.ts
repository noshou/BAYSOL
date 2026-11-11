// SPDX-License-Identifier: LGPL-3.0-or-later

// Checks of a curve the import is about to take: a file that is most likely the wrong
// one (or the wrong columns). They only WARN, one short line each; nothing is refused.
//
//  - A measured curve whose sigma column is really a fitted curve: a SASBDB `.fit` file
//    has q, the measured I, the model I and the error, so a read of columns 1-3 gives a
//    "sigma" that is the model's intensity, which correlates ~1 with I and is about I.
//  - A reference fit that does not lie on the measured curve: the data's own column
//    taken for the model, the sigma column taken for I, or another file altogether.

import { readFileSync } from "node:fs"
import { dataTsvFile, parseDataText } from "./data.js"
import type { DataPoints } from "./data-table.js"

/** The fewest points a check needs to say anything. */
const MIN_CHECK_POINTS = 5

/** sigma / I within these bounds all through the curve says "sigma is the curve". */
const SIGMA_IS_CURVE: readonly [number, number] = [0.9, 1.1]

/** sigma / I within these bounds is of the size of I (and with a correlation of 1, the
 * curve itself). */
const SAME_SIZE: readonly [number, number] = [0.5, 2]

/** The correlation of I and sigma above which sigma follows I. */
const CORRELATION_LIMIT = 0.9999

/** A reference this many times off the data (median, either way) is a warning. */
const FAR_FACTOR = 2

/** A reference that agrees with the data this closely (relative) is the data. */
const SAME_AS_DATA = 1e-9

/** @returns the median of a list (the middle, or the mean of the two middle ones). */
function median(values: readonly number[]): number {
    const sorted = [...values].sort((a, b) => a - b)
    const mid = Math.floor(sorted.length / 2)
    const low = sorted[mid - 1] as number
    const high = sorted[mid] as number
    return sorted.length % 2 === 0 ? (low + high) / 2 : high
}

/** @returns the Pearson correlation of two lists of the same length (0 for a flat one). */
function correlation(a: readonly number[], b: readonly number[]): number {
    const n = a.length
    const meanA = a.reduce((s, x) => s + x, 0) / n
    const meanB = b.reduce((s, x) => s + x, 0) / n
    let cross = 0
    let varA = 0
    let varB = 0
    for (let k = 0; k < n; k++) {
        const da = (a[k] as number) - meanA
        const db = (b[k] as number) - meanB
        cross += da * db
        varA += da * da
        varB += db * db
    }
    return varA > 0 && varB > 0 ? cross / Math.sqrt(varA * varB) : 0
}

/**
 * Whether the sigma column of a measured curve is really a fitted curve (a `.fit` file's
 * model column), which a depositor's curve file would show as sigma of about I(q), or
 * moving with I with a correlation of 1.
 *
 * @param data - the curve as it would be imported.
 * @returns a short warning, or `undefined` when nothing looks wrong (or the curve has no
 *     sigma, or too few points to tell).
 */
export function sigmaWarning(data: DataPoints): string | undefined {
    const pairs = data.i
        .map((i, k) => [i, data.sigma[k] ?? Number.NaN] as const)
        .filter(([i, s]) => Number.isFinite(i) && Number.isFinite(s) && i > 0 && s > 0)
    if (pairs.length < MIN_CHECK_POINTS) return undefined
    const ratio = median(pairs.map(([i, s]) => s / i))
    const r = correlation(
        pairs.map(([i]) => i),
        pairs.map(([, s]) => s),
    )
    const near = ratio >= SIGMA_IS_CURVE[0] && ratio <= SIGMA_IS_CURVE[1]
    // errors that are a fixed share of I also correlate ~1, so a correlation counts only
    // when sigma is of the size of I too
    const follows = r > CORRELATION_LIMIT && ratio >= SAME_SIZE[0] && ratio <= SAME_SIZE[1]
    if (near || follows)
        return "sigma is about I: a fit file? wrong file?"
    return undefined
}

/**
 * The measured curve of a project as points, or `undefined` when it cannot be read.
 *
 * @param projectDir - the project.
 */
export function measuredPoints(projectDir: string): DataPoints | undefined {
    try {
        return parseDataText(readFileSync(dataTsvFile(projectDir), "utf-8"))
    } catch {
        return undefined
    }
}

/**
 * The value of the curve `(q, i)` at `x`, linear between its points; `undefined` outside
 * its q range. `q` is increasing (the import checks that).
 */
function interpolate(
    q: readonly number[],
    i: readonly number[],
    x: number,
): number | undefined {
    const first = q[0]
    const last = q[q.length - 1]
    if (first === undefined || last === undefined || x < first || x > last) return undefined
    let lo = 0
    let hi = q.length - 1
    while (hi - lo > 1) {
        const mid = (lo + hi) >> 1
        if ((q[mid] as number) <= x) lo = mid
        else hi = mid
    }
    const x0 = q[lo] as number
    const x1 = q[hi] as number
    const y0 = i[lo] as number
    const y1 = i[hi] as number
    return x1 > x0 ? y0 + ((y1 - y0) * (x - x0)) / (x1 - x0) : y0
}

/**
 * Whether a reference curve lies on the measured one: the factor of the median distance
 * between them on the measured q, and whether the two are the same numbers (the data's own
 * column taken as the model).
 *
 * @param reference - the curve as it would be imported (units of the data).
 * @param measured - the project's measured curve.
 * @returns a short warning, or `undefined` when it looks right (or cannot be told).
 */
export function referenceWarning(
    reference: DataPoints,
    measured: DataPoints | undefined,
): string | undefined {
    if (measured === undefined) return undefined
    const logs: number[] = []
    let same = true
    for (const [k, x] of measured.q.entries()) {
        const mine = interpolate(reference.q, reference.i, x)
        const theirs = measured.i[k] as number
        if (mine === undefined || !(mine > 0) || !(theirs > 0)) continue
        logs.push(Math.abs(Math.log10(mine / theirs)))
        if (Math.abs(mine - theirs) > SAME_AS_DATA * theirs) same = false
    }
    if (logs.length < MIN_CHECK_POINTS)
        return reference.q.length >= MIN_CHECK_POINTS
            ? "q range does not meet the data: units?"
            : undefined
    if (same) return "same numbers as the data: the model column?"
    const factor = 10 ** median(logs)
    if (factor > FAR_FACTOR) return `${factor.toPrecision(2)}x off the data: wrong column?`
    return undefined
}
