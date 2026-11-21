// SPDX-License-Identifier: LGPL-3.0-or-later

// The statistics log of a model (`statistics-<model>.LOG`, written by the sampler)
// parsed and laid out for reading. The file is a plain text log of one or more attempts,
// each a run of `-- section --` blocks: tab separated `name value` rows, tab separated
// tables, or free text. This module turns it into aligned rows and tables, with the
// outcome of the attempts first, the long per-start lists of the MAP search summarised
// and the numbers rounded to a readable length. The file itself is never changed.
//
// Contents:
//   1. Parsing: models, attempts and sections
//   2. Layout: rows, tables and the free-text sections
//   3. `formatStatistics`: the whole text

/** One `-- name --` block: the name and its lines (blank ones dropped). */
interface Section {
    name: string
    lines: string[]
}

/** A `--- attempt n: label ---` block, with the sections it holds. */
interface Attempt {
    title: string
    sections: Section[]
}

/** A `=== model ===` block: the sections before its first attempt and the attempts. */
interface Model {
    name: string
    sections: Section[]
    attempts: Attempt[]
}

// ========================================================================================
// 1. Parsing
// ========================================================================================

const MODEL_LINE = /^=== (.*) ===$/
const ATTEMPT_LINE = /^--- (.*) ---$/
const SECTION_LINE = /^-- (.*) --$/

/**
 * Splits the text of a statistics file into models, attempts and sections.
 *
 * @param text - the file's text.
 * @returns the time written (the `datetime` row, if any) and the models; text outside a
 *     model goes into one unnamed model.
 */
function parseStatistics(text: string): { written?: string; models: Model[] } {
    const models: Model[] = []
    let written: string | undefined
    let model: Model | undefined
    let attempt: Attempt | undefined
    let section: Section | undefined
    const startModel = (name: string): Model => {
        const made: Model = { name, sections: [], attempts: [] }
        models.push(made)
        attempt = undefined
        section = undefined
        return made
    }
    for (const raw of text.split(/\r?\n/)) {
        // a trailing tab is an empty last cell: only spaces and the carriage return go
        const line = raw.replace(/[ \r]+$/, "")
        const isModel = MODEL_LINE.exec(line)
        const isAttempt = ATTEMPT_LINE.exec(line)
        const isSection = SECTION_LINE.exec(line)
        if (isModel) {
            model = startModel(isModel[1] ?? "")
        } else if (isAttempt) {
            model ??= startModel("")
            attempt = { title: isAttempt[1] ?? "", sections: [] }
            model.attempts.push(attempt)
            section = undefined
        } else if (isSection) {
            model ??= startModel("")
            section = { name: isSection[1] ?? "", lines: [] }
            ;(attempt?.sections ?? model.sections).push(section)
        } else if (line.trim() === "") {
            // blank lines only separate blocks
        } else if (section) {
            section.lines.push(line)
        } else if (line.startsWith("datetime\t")) {
            written = line.slice("datetime\t".length).trim()
        }
    }
    return { written, models }
}

// ========================================================================================
// 2. Layout
// ========================================================================================

const INDENT = "  "
const GAP = "  "

/** The most significant digits a number keeps. */
const DIGITS = 5

/**
 * A number for reading: `DIGITS` significant digits, no trailing zeros, an exponent for the
 * very small and very large. Anything that is not a plain number stays as written.
 *
 * @param cell - a cell of the file.
 * @returns the shortened number, or the cell.
 */
export function shorten(cell: string): string {
    if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(cell)) return cell
    // integers are counts: keep every digit
    if (/^[+-]?\d+$/.test(cell)) return cell
    const value = Number(cell)
    if (value === 0) return "0"
    const size = Math.abs(value)
    if (size < 1e-4 || size >= 1e7) return value.toExponential(DIGITS - 2)
    return String(Number(value.toPrecision(DIGITS)))
}

/** What the file writes for a value it could not compute. */
const UNAVAILABLE = "unavailable"

/** The width above which a table of few rows is turned over, and the limits of that. */
const MAX_TABLE = 100
const WIDE_COLUMNS = 8
const TURN_ROWS = 12

const NUMBER = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/

/** Pads a cell to a width, numbers on the right edge. */
function pad(cell: string, width: number, right: boolean): string {
    const gap = " ".repeat(Math.max(0, width - [...cell].length))
    return right ? gap + cell : cell + gap
}

/**
 * A table: a header, a rule and the rows, the columns as wide as their longest cell, the
 * numbers aligned right. A column without any text is left out.
 *
 * @param header - the column titles.
 * @param rows - the rows (cells as text).
 * @returns the lines.
 */
function table(header: string[], rows: string[][], turned = false): string[] {
    const keep = header.map((_, c) =>
        rows.some((r) => (r[c] ?? "") !== "" && r[c] !== UNAVAILABLE),
    )
    const head = header.filter((_, c) => keep[c])
    const body = rows.map((r) =>
        header.map((_, c) => shorten(r[c] ?? "")).filter((_, c) => keep[c]),
    )
    const widths = head.map((title, c) =>
        Math.max(...[title, ...body.map((r) => r[c] ?? "")].map((s) => [...s].length)),
    )
    const across = widths.reduce((sum, w) => sum + w + GAP.length, INDENT.length)
    // a wide table of few rows reads better turned over: one column per row, so a line
    // does not run off the screen (the chains: one column per chain)
    if (across > MAX_TABLE && head.length >= WIDE_COLUMNS && body.length <= TURN_ROWS) {
        const over = head
            .slice(1)
            .map((title, c) => [title, ...body.map((r) => r[c + 1] ?? "")])
        return table([head[0] ?? "", ...body.map((r) => r[0] ?? "")], over, true)
    }
    const numeric = head.map(
        (_, c) => (turned ? c > 0 : body.every((r) => NUMBER.test(r[c] ?? ""))),
    )
    const line = (cells: string[], right: boolean): string =>
        INDENT +
        cells
            .map((cell, c) => pad(cell, widths[c] ?? 0, right && numeric[c] === true))
            .join(GAP)
            .trimEnd()
    return [
        line(head, true),
        INDENT + widths.map((w) => "─".repeat(w)).join(GAP),
        ...body.map((r) => line(r, true)),
    ]
}

/** `name  value` rows with the names padded to the longest one. */
function pairs(rows: [string, string][]): string[] {
    const width = Math.max(...rows.map(([name]) => [...name].length))
    return rows.map(([name, value]) => `${INDENT}${pad(name, width, false)}${GAP}${value}`)
}

/** The cells of a tab separated line, trimmed. */
function cells(line: string): string[] {
    return line.split("\t").map((c) => c.trim())
}

/** The `start N:` lines of the MAP search, summarised in one line. */
function summariseStarts(starts: string[]): string[] {
    const fs: number[] = []
    const evals: number[] = []
    let converged = 0
    let limited = 0
    for (const s of starts) {
        const f = /\bf=(-?[\d.]+(?:e[+-]?\d+)?)/.exec(s)?.[1]
        const e = /\bevals=(\d+)/.exec(s)?.[1]
        if (f !== undefined) fs.push(Number(f))
        if (e !== undefined) evals.push(Number(e))
        if (s.includes("g_conv=true")) converged++
        if (s.includes("iter_limit=true")) limited++
    }
    if (fs.length === 0) return [`${starts.length} starts`]
    const sorted = [...evals].sort((a, b) => a - b)
    const median = sorted[Math.floor(sorted.length / 2)] ?? 0
    return [
        `${starts.length} starts: best f ${shorten(String(Math.min(...fs)))}, ` +
            `worst ${shorten(String(Math.max(...fs)))}`,
        `${converged} reached the gradient tolerance, ${limited} the iteration limit`,
        `evaluations ${sorted[0] ?? 0} to ${sorted.at(-1) ?? 0}, median ${median}`,
    ]
}

const MODE_LINE = /^\s*mode (\d+): f=(\S+) ξ=(\[.*?\])\s+H-eig=(\[.*?\])\s+(.*)$/

/** The free-text MAP search: the starts summarised, the optima as a table. */
function mapSearch(lines: string[]): string[] {
    const out: string[] = []
    const starts = lines.filter((l) => /^\s*start \d+:/.test(l))
    const modes = lines.filter((l) => MODE_LINE.test(l))
    let startsDone = false
    let modesDone = false
    for (const l of lines) {
        if (/^\s*start \d+:/.test(l)) {
            if (!startsDone) out.push(...summariseStarts(starts).map((t) => INDENT + t))
            startsDone = true
        } else if (MODE_LINE.test(l)) {
            if (!modesDone) {
                const rows = modes.map((m) => {
                    const g = MODE_LINE.exec(m) as RegExpExecArray
                    const rest = (g[5] ?? "").replace(/^log Laplace mass=/, "")
                    const parts = /^(.*?) \(Δ vs best = (.*?)(?: nats)?\)$/.exec(rest)
                    return [g[1] ?? "", g[2] ?? "", g[3] ?? "", g[4] ?? "",
                        parts?.[1] ?? rest, parts?.[2] ?? ""]
                })
                const titles = ["mode", "f", "ξ", "H eigenvalues", "log mass", "Δ vs best"]
                out.push(...table(titles, rows))
            }
            modesDone = true
        } else if (l.trim() === "L-BFGS starts (z space):") {
            // the summary line stands for the list and its title
        } else {
            out.push(INDENT + l.trim())
        }
    }
    return out
}

/**
 * One section as lines: a table, name/value rows, the MAP search, or its own text.
 *
 * @param section - the section.
 * @returns the lines, headed by its name.
 */
function layoutSection(section: Section): string[] {
    const { name, lines } = section
    const head = `── ${name} ──`
    if (name === "map search") return [head, ...mapSearch(lines)]
    const split = lines.map(cells)
    const widthOf = split[0]?.length ?? 0
    if (widthOf >= 3 && split.every((c) => c.length === widthOf)) {
        const [header, ...rows] = split
        return [head, ...table(header ?? [], rows)]
    }
    if (split.every((c) => c.length === 2)) {
        const rows = split.map((c): [string, string] => [c[0] ?? "", shorten(c[1] ?? "")])
        return [head, ...pairs(rows)]
    }
    // free text: the `====` rules only drew a box in the file
    return [head, ...lines.filter((l) => !/^=+$/.test(l.trim())).map((l) => INDENT + l)]
}

// ========================================================================================
// 3. The whole text
// ========================================================================================

/** The sections of the end of a model that say how it went: shown first. */
const SUMMARY_SECTIONS = ["attempts", "result"]

/**
 * The statistics of a run as readable text: for each model a summary (its attempts and
 * how it ended), then every attempt's sections.
 *
 * @param text - the text of a `statistics-<model>.LOG`, or several one after the other.
 * @returns the text; the input unchanged when it holds no section at all.
 */
export function formatStatistics(text: string): string {
    const { written, models } = parseStatistics(text)
    if (models.every((m) => m.sections.length === 0 && m.attempts.length === 0)) return text
    const out: string[] = []
    if (written !== undefined) out.push(`written ${written}`, "")
    for (const model of models) {
        const all = [...model.sections, ...model.attempts.flatMap((a) => a.sections)]
        const summary = SUMMARY_SECTIONS.flatMap((n) => all.filter((s) => s.name === n))
        const own = (list: Section[]): Section[] =>
            list.filter((s) => !SUMMARY_SECTIONS.includes(s.name))
        out.push(`══ ${model.name || "statistics"} ${"═".repeat(40)}`, "")
        for (const s of summary) out.push(...layoutSection(s), "")
        for (const s of own(model.sections)) out.push(...layoutSection(s), "")
        for (const attempt of model.attempts) {
            out.push(`━━ ${attempt.title} ${"━".repeat(40)}`, "")
            for (const s of own(attempt.sections)) out.push(...layoutSection(s), "")
        }
    }
    return `${out.join("\n").trimEnd()}\n`
}
