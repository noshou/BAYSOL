// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The electrons of a chemical formula, for the custom solutes: pure functions of text,
 * so none of it needs a terminal.
 *
 *     NaCl            28
 *     Ca(OH)2         Nested ( ) and [ ] with multipliers: 20 + 2 * 9 = 38
 *     CuSO4·5H2O      Parts apart with `·`, `.`, `*` or `•` (a hydrate or an adduct),
 *                     each with an optional leading multiplier
 *     NH4+  SO4 2-    A charge: a trailing `+` or `-`, with the number in front of it
 *                     after a space or `^` (`SO4 2-`, `SO4^2-`), or attached when the
 *                     formula is one element (`Al3+`, `O2-`: up to 4) or ends in a
 *                     bracket (`[Fe(CN)6]3-`). Elsewhere a number attached to the sign
 *                     is a count (`NH4+` is NH4 with one positive charge), so write
 *                     `SO4 2-`.
 *
 * Heavy hydrogen `D` counts as hydrogen (Z = 1). Spaces are ignored. A formula comes to
 * `{z, charge}` (the electrons of the atoms less the charge) or `{error}`, the message
 * short enough for the note on the border of a screen (22 characters).
 */

/** The element symbols in the order of their atomic numbers 1..118. */
const symbols: readonly string[] = (
    "H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni " +
    "Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe " +
    "Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg " +
    "Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg " +
    "Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og"
).split(" ")

/** The symbol of heavy hydrogen, which counts as hydrogen. */
const deuterium = "D"

/**
 * `symbol -> Z` for the 118 elements, and `D` (heavy hydrogen) as 1.
 */
export const atomicNumber: ReadonlyMap<string, number> = new Map([
    ...symbols.map((s, i) => [s, i + 1] as [string, number]),
    [deuterium, 1],
])

/** The characters that part a formula into a main part and its hydrate or adduct. */
const partSeparators = "·.*•"

/** The most a number attached to the sign of a single element is read as a charge. */
const maxAttachedCharge = 4

/** The largest count the parser keeps exact (a larger one is refused). */
const maxCount = Number.MAX_SAFE_INTEGER

/** The element counts of a formula: `symbol -> number of atoms`. */
type Counts = Map<string, number>

/** A formula the parser refused, with the short message for the screen. */
class FormulaError extends Error {}

/**
 * Fails the parse.
 *
 * @param message - the short message.
 * @throws FormulaError always.
 */
function fail(message: string): never {
    throw new FormulaError(message)
}

/**
 * Reads the digits of a text.
 *
 * @param s - the text.
 * @param i - where to start.
 * @returns the number (`undefined` when there are no digits) and the index after them.
 */
function readInt(s: string, i: number): [number | undefined, number] {
    let end = i
    while (end < s.length && /[0-9]/.test(s[end] as string)) end++
    if (end === i) return [undefined, end]
    const n = Number(s.slice(i, end))
    if (n > maxCount) fail("number too big")
    return [n, end]
}

/**
 * Reads a count, which must not be 0.
 *
 * @param s - the text.
 * @param i - where to start.
 * @returns the number (1 when there is none) and the index after it.
 */
function readCount(s: string, i: number): [number, number] {
    const [n, end] = readInt(s, i)
    if (n === 0) fail("count must be > 0")
    return [n ?? 1, end]
}

/**
 * Reads the element that starts at an index: an upper-case letter and, if it makes a
 * symbol, the lower-case one after it.
 *
 * @param s - the text.
 * @param i - where the element starts.
 * @returns the symbol and the index after it.
 */
function readElement(s: string, i: number): [string, number] {
    const c = s[i] as string
    const next = s[i + 1]
    const two = next !== undefined && /\p{Ll}/u.test(next) ? s.slice(i, i + 2) : undefined
    if (two !== undefined && atomicNumber.has(two)) return [two, i + 2]
    if (atomicNumber.has(c)) return [c, i + 1]
    return fail(`unknown element ${two ?? c}`)
}

/** Adds the counts of `from`, each times `k`, to `into`. */
function addScaled(into: Counts, from: Counts, k: number): void {
    for (const [sym, n] of from) into.set(sym, (into.get(sym) ?? 0) + n * k)
}

/**
 * Reads the atoms of a text from an index up to the end or a closing bracket that is
 * not this call's (a recursive descent over the characters).
 *
 * @param s - the text.
 * @param start - where to start.
 * @param close - the bracket that ends this level, `undefined` at the top.
 * @returns the counts and the index after the level.
 */
function readAtoms(s: string, start: number, close: string | undefined): [Counts, number] {
    const total: Counts = new Map()
    let i = start
    while (i < s.length) {
        const c = s[i] as string
        if (/\p{Lu}/u.test(c)) {
            const [sym, j] = readElement(s, i)
            const [n, k] = readCount(s, j)
            total.set(sym, (total.get(sym) ?? 0) + n)
            i = k
        } else if (c === "(" || c === "[") {
            const [inner, j] = readAtoms(s, i + 1, c === "(" ? ")" : "]")
            const [n, k] = readCount(s, j)
            addScaled(total, inner, n)
            i = k
        } else if (c === ")" || c === "]") {
            if (c === close) return [total, i + 1]
            fail("unbalanced bracket")
        } else fail(`unexpected character ${c}`)
    }
    if (close !== undefined) fail("unbalanced bracket")
    return [total, i]
}

/**
 * The element counts of one part (`5H2O`, `Ca(OH)2`): its leading multiplier times its
 * atoms.
 *
 * @param part - the text of the part.
 * @returns the counts.
 */
function partCounts(part: string): Counts {
    if (part.trim() === "") fail("empty part")
    const [mult, i] = readInt(part, 0)
    if (mult === 0) fail("count must be > 0")
    const [total] = readAtoms(part, i, undefined)
    if (i === part.length) fail("no atoms")
    const scaled: Counts = new Map()
    addScaled(scaled, total, mult ?? 1)
    return scaled
}

/** The electrons the atoms have. */
function electrons(counts: Counts): number {
    let z = 0
    for (const [sym, n] of counts) z += n * (atomicNumber.get(sym) as number)
    return z
}

// --- the charge

/** The signs of a charge and their direction (the last is the Unicode minus). */
const signs: Readonly<Record<string, number>> = { "+": 1, "-": -1, "−": -1 }

/** A number after `^` or a space: `SO4 2-`, `SO4^2-`. */
const explicitCharge = /^(?:([\s\S]*?)\s*\^\s*([0-9]+)|([\s\S]*?\S)\s+([0-9]+))$/

/** A number right after a bracket or one element: `[Fe(CN)6]3-`, `Al3+`. */
const attachedCharge = /^(?:([\s\S]*[)\]])([0-9]+)|([A-Z][a-z]?)([0-9]+))$/

/**
 * Splits the charge off a trimmed formula. See the top of this file for where digits
 * count as the charge.
 *
 * @param s - the formula, trimmed.
 * @returns the formula without its charge, and the charge (0 for none).
 */
function splitCharge(s: string): [string, number] {
    const sign = s === "" ? undefined : signs[s[s.length - 1] as string]
    if (sign === undefined) return [s, 0]
    const body = s.slice(0, -1).trimEnd()
    const explicit = explicitCharge.exec(body)
    if (explicit)
        return [
            explicit[1] ?? (explicit[3] as string),
            sign * Number(explicit[2] ?? explicit[4]),
        ]
    const attached = attachedCharge.exec(body)
    if (attached?.[1] !== undefined) return [attached[1], sign * Number(attached[2])]
    const [, , , element, digits] = attached ?? []
    if (
        element !== undefined &&
        atomicNumber.has(element) &&
        Number(digits) <= maxAttachedCharge
    )
        return [element, sign * Number(digits)]
    return [body, sign]
}

// --- the formula

/** What is wrong with a formula: the short message. */
export type FormulaProblem = { error: string }

/**
 * The electrons of a formula.
 *
 * @property z - the electrons of the atoms less the charge (not checked to be above 0).
 * @property charge - the charge.
 */
export type Electrons = { z: number; charge: number }

/** The atoms of a formula, for showing how its electrons add up. */
export type ElementCounts = {
    counts: [symbol: string, n: number][]
    charge: number
    z: number
}

/**
 * Whether a result is a problem.
 *
 * @param result - what a parser gave.
 * @returns `true` for `{error}`.
 */
export function isProblem(result: object): result is FormulaProblem {
    return "error" in result
}

/**
 * Analyses a formula text.
 *
 * @param text - the formula.
 * @returns the counts, the charge and the electrons, or the problem.
 */
function analyse(
    text: string,
): { counts: Counts; charge: number; z: number } | FormulaProblem {
    try {
        const s = text.trim()
        if (s === "") fail("formula needed")
        const [split, charge] = splitCharge(s)
        const body = split.replace(/\s+/g, "")
        const counts: Counts = new Map()
        for (const part of body.split(new RegExp(`[${partSeparators}]`)))
            addScaled(counts, partCounts(part), 1)
        return { counts, charge, z: electrons(counts) - charge }
    } catch (error) {
        if (error instanceof FormulaError) return { error: error.message }
        throw error
    }
}

/**
 * The electrons of a formula text.
 *
 * @param text - the formula.
 * @returns `{z, charge}` (the electrons of the atoms less the charge) or
 *     `{error}` with a short message.
 */
export function parseFormula(text: string): Electrons | FormulaProblem {
    const r = analyse(text)
    return isProblem(r) ? r : { z: r.z, charge: r.charge }
}

/** The order of an element in Hill notation: C, then H, then the rest. */
function hillRank(hill: boolean, sym: string): number {
    if (hill && sym === "C") return 0
    if (hill && sym === "H") return 1
    return 2
}

/**
 * The atoms of a formula text, for showing how its electrons add up. The elements are
 * in Hill order (C first, then H, then the others alphabetically; all alphabetical when
 * there is no carbon), the counts summed over the parts and the groups of a hydrate or
 * an adduct.
 *
 * @param text - the formula.
 * @returns the counts, the charge and the electrons, or `{error}`.
 */
export function elementCounts(text: string): ElementCounts | FormulaProblem {
    const r = analyse(text)
    if (isProblem(r)) return r
    const hill = r.counts.has("C")
    const counts = [...r.counts].sort(([a], [b]) => {
        const [x, y] = [hillRank(hill, a), hillRank(hill, b)]
        if (x !== y) return x - y
        return a < b ? -1 : a > b ? 1 : 0
    })
    return { counts, charge: r.charge, z: r.z }
}

/**
 * The electrons of a formula as a sum, `7 C + 13 H + 1 N + 3 O + 1 S = 102 electrons,
 * charge 0` (a positive charge carries its `+`).
 *
 * @param text - the formula.
 * @returns the sum, or `undefined` when the formula is not understood.
 */
export function breakdown(text: string): string | undefined {
    const r = elementCounts(text)
    if (isProblem(r)) return undefined
    const atoms = r.counts.map(([sym, n]) => `${n} ${sym}`).join(" + ")
    return `${atoms} = ${r.z} electrons, charge ${r.charge > 0 ? "+" : ""}${r.charge}`
}

/** A polymer's repeat unit written `( ... )n`. */
const wrappedUnit = /^\(([\s\S]*)\)\s*n$/

/**
 * A repeat unit's text without a surrounding `( )n`.
 *
 * @param text - the text (`(C2H4O)n` or `C2H4O`).
 * @returns the unit, trimmed (`C2H4O`); text without the wrapper is returned trimmed.
 */
export function stripUnit(text: string): string {
    const s = text.trim()
    const m = wrappedUnit.exec(s)
    return m ? (m[1] as string).trim() : s
}

/**
 * The repeat unit of a polymer.
 *
 * @param text - the text (`C2H4O` or `(C2H4O)n`).
 * @returns the unit and its electrons, or `{error}`; a charge is not allowed.
 */
export function parseUnit(text: string): { unit: string; z: number } | FormulaProblem {
    const unit = stripUnit(text)
    const parsed = parseFormula(unit)
    if (isProblem(parsed)) return parsed
    if (parsed.charge !== 0) return { error: "no charge allowed" }
    return { unit, z: parsed.z }
}

/** The things a formula can be taken into: an entry or a unit. */
export interface WithFormula {
    formula: string
    z: number | null
    label?: string
}

/**
 * The formula text taken into an entry or a unit of a polymer. The formula is set and,
 * when it is not the one the target had, Z is what it comes to, or `null` when the
 * formula is not understood (the reason is the note, unless the formula is blank); a
 * formula that did not change keeps its Z, so a Z typed by hand stays. A polymer unit
 * with no label gets `offered`, when that is given.
 *
 * @param m - the entry (non-biological) or unit.
 * @param text - the formula as typed.
 * @param unit - true for a polymer unit: a surrounding `( )n` is dropped and no charge
 *     is allowed.
 * @param offered - the label to give a unit that has none.
 * @returns the new target, and the reason the formula was not understood, if any.
 */
export function takeFormula<T extends WithFormula>(
    m: T,
    text: string,
    unit: boolean,
    offered?: string,
): { value: T; note: string | undefined } {
    const parsed = unit ? parseUnit(text) : parseFormula(text)
    const shown = unit ? stripUnit(text) : text.trim()
    const same = shown === m.formula
    const failed = isProblem(parsed)
    const z = same ? m.z : failed ? null : parsed.z
    let value: T = { ...m, formula: shown, z }
    if (unit && offered && shown !== "" && (m.label ?? "").trim() === "")
        value = { ...value, label: offered }
    return { value, note: !same && failed && shown !== "" ? parsed.error : undefined }
}
