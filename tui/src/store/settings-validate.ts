// SPDX-License-Identifier: LGPL-3.0-or-later

import { readAssetJson } from "../core/assets.js"
import { isDict } from "../core/files.js"
import type {
    PartKind,
    Relation,
    SettingDef,
    SettingsCatalog,
    SettingValue,
} from "./settings-defs.js"

/**
 * The checks on the value of a setting, which no value may escape: its type, the
 * limits and choices the harvest copied from the Params.jl files, a colour that
 * exists, the shape of a tuple, and the rules that tie settings together
 * (`setting_relations.json`). The Julia side makes the same checks on the same data
 * when it reads the settings (`BAYSOL.load_settings`), so what the terminal interface
 * keeps is what the code accepts; `test/fixtures/settings/cases.json` is read by both.
 *
 * A value to check is "raw": whatever came from a file or from the keyboard. A value
 * saved in `settings.json` is checked like one that was typed or picked: JSON has no
 * keywords and no float/integer difference, so a colour or a choice is a string, a whole
 * number is a number for an integer and for a float setting alike, and an integer setting
 * wants a whole number (`300.5` is refused).
 */

/**
 * The outcome of a check: the value in the type the setting has, or what is wrong.
 *
 * @property ok - whether the value is valid.
 * @property value - (valid) the value, e.g. a whole number given to a float setting
 *     is a number, choices come in the order of the choices.
 * @property error - (invalid) a sentence that says what is wrong, e.g.
 *     `must be at least 1`.
 */
export type Checked = { ok: true; value: SettingValue } | { ok: false; error: string }

/** The most characters (code points) a font name has, as on the Julia side. */
const maxFontName = 100

/** `#rrggbb`, the one spelling of a colour that is not a name of the list. */
const hexColour = /^#[0-9a-fA-F]{6}$/

/** A control character (ISO control, category Cc): no font name has one. */
const controlCharacter = /\p{Cc}/u

/** The names of the colours of `colours.json`, read on first use. */
let colourSet: Set<string> | undefined

/**
 * The names of the colours a figure can use.
 *
 * @returns the set of names (`crimson`, `gray20`, ...).
 */
function colourNames(): Set<string> {
    colourSet ??= new Set(
        Object.keys(readAssetJson<Record<string, string>>("data", "colours.json")),
    )
    return colourSet
}

/**
 * Whether a raw value is a colour a figure can use: a string named like a colour of the
 * list, or `#rrggbb`.
 *
 * @param raw - the value.
 * @returns the colour (name or hex) it stands for, or `undefined` if it is none.
 */
function colourOf(raw: unknown): string | undefined {
    if (typeof raw !== "string") return undefined
    return hexColour.test(raw) || colourNames().has(raw) ? raw : undefined
}

/**
 * Whether a raw value is a colour.
 *
 * @param raw - the value.
 * @returns true if a colour setting would take it.
 */
export function isColour(raw: unknown): boolean {
    return colourOf(raw) !== undefined
}

/**
 * The whole number a raw value is, if it is one (a plain JavaScript integer that keeps
 * its precision; the number editors take at most 15 digits anyway).
 *
 * @param raw - the value.
 * @returns the number, or `undefined`.
 */
function wholeOf(raw: unknown): number | undefined {
    return typeof raw === "number" && Number.isSafeInteger(raw) ? raw : undefined
}

/**
 * The finite number a raw value is, if it is one (a whole number or a float).
 *
 * @param raw - the value.
 * @returns the number, or `undefined`.
 */
function finiteOf(raw: unknown): number | undefined {
    return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined
}

/**
 * What is wrong with the number `v` under limits, if anything.
 *
 * @param v - the number.
 * @param limits - the limits of the setting.
 * @returns the first limit it breaks, as a sentence, or `undefined`.
 */
function limitError(v: number, limits: SettingDef["limits"]): string | undefined {
    const checks: [
        keyof SettingDef["limits"],
        string,
        (a: number, b: number) => boolean,
    ][] = [
        ["above", "above", (a, b) => a > b],
        ["below", "below", (a, b) => a < b],
        ["at_least", "at least", (a, b) => a >= b],
        ["at_most", "at most", (a, b) => a <= b],
    ]
    for (const [key, words, ok] of checks) {
        const bound = limits[key]
        if (bound !== undefined && !ok(v, bound)) return `must be ${words} ${bound}`
    }
    return undefined
}

/**
 * One part of a tuple, checked against the kind of that part.
 *
 * @param raw - the part.
 * @param kind - what the part must be.
 * @returns the part as a number or colour, or the error.
 */
function checkPart(raw: unknown, kind: PartKind): Checked {
    if (kind === "int") {
        const n = wholeOf(raw)
        return n === undefined
            ? { ok: false, error: "a part must be a whole number" }
            : { ok: true, value: n }
    }
    if (kind === "float") {
        const n = finiteOf(raw)
        return n === undefined
            ? { ok: false, error: "a part must be a finite number" }
            : { ok: true, value: n }
    }
    const colour = colourOf(raw)
    return colour === undefined
        ? { ok: false, error: "a part must be a colour" }
        : { ok: true, value: colour }
}

/**
 * Checks a tuple value: an array of the number of parts of the default, or an object
 * with exactly its keys, each part of its kind.
 *
 * @param def - the tuple setting.
 * @param raw - the value.
 * @returns the tuple (array, or object with the keys in the order of the default) or
 *     the first error.
 */
function checkTuple(def: SettingDef, raw: unknown): Checked {
    const kinds = def.partKinds
    let items: unknown[]
    if (def.isRecord) {
        const names = def.partNames
        const keys = isDict(raw) ? Object.keys(raw) : []
        if (!isDict(raw) || keys.length !== names.length || !names.every((n) => n in raw))
            return { ok: false, error: `must have exactly ${names.join(", ")}` }
        items = names.map((n) => raw[n])
    } else {
        if (!Array.isArray(raw) || raw.length !== kinds.length)
            return { ok: false, error: `must have ${kinds.length} parts` }
        items = raw
    }
    const parts: (number | string)[] = []
    for (const [i, item] of items.entries()) {
        const part = checkPart(item, kinds[i] as PartKind)
        if (!part.ok) return part
        parts.push(part.value as number | string)
    }
    if (!def.isRecord) return { ok: true, value: parts }
    return {
        ok: true,
        value: Object.fromEntries(def.partNames.map((n, i) => [n, parts[i] as number])),
    }
}

/**
 * Checks a value of any kind.
 *
 * @param def - the setting.
 * @param raw - the value.
 * @returns the value in the type of the setting, or the error.
 */
function check(def: SettingDef, raw: unknown): Checked {
    const limited = (x: number): Checked => {
        const error = limitError(x, def.limits)
        return error === undefined ? { ok: true, value: x } : { ok: false, error }
    }
    switch (def.kind) {
        case "bool":
            return typeof raw === "boolean"
                ? { ok: true, value: raw }
                : { ok: false, error: "must be true or false" }
        case "int": {
            const n = wholeOf(raw)
            return n === undefined
                ? { ok: false, error: "must be a whole number" }
                : limited(n)
        }
        case "float": {
            const n = finiteOf(raw)
            return n === undefined
                ? { ok: false, error: "must be a finite number" }
                : limited(n)
        }
        case "colour": {
            const colour = colourOf(raw)
            return colour === undefined
                ? { ok: false, error: "is not a colour" }
                : { ok: true, value: colour }
        }
        case "font": {
            const ok =
                typeof raw === "string" &&
                raw.trim() !== "" &&
                [...raw].length <= maxFontName &&
                !controlCharacter.test(raw)
            return ok
                ? { ok: true, value: raw }
                : { ok: false, error: "must be a font name" }
        }
        case "set": {
            const names: unknown[] = Array.isArray(raw) ? raw : []
            const ok =
                names.length > 0 &&
                names.every((x) => typeof x === "string" && def.choices.includes(x)) &&
                new Set(names).size === names.length
            if (!ok) {
                return {
                    ok: false,
                    error: `must be some of ${def.choices.join(", ")}, at least one`,
                }
            }
            return { ok: true, value: def.choices.filter((c) => names.includes(c)) }
        }
        case "tuple":
            return checkTuple(def, raw)
    }
}

/**
 * Checks a value: one a person gave (typed on the number editor, picked from a list) or
 * one read from `settings.json`. Pass what the editor holds (a number, a boolean, a
 * string for a font, a colour or a choice, an array or an object for a tuple); text typed
 * into a number editor must be turned into a number first.
 *
 * @param def - the setting.
 * @param raw - the value.
 * @returns `{ ok: true, value }` with the value in the type the setting has, or
 *     `{ ok: false, error }` with a sentence such as `must be above 0`.
 */
export function validateValue(def: SettingDef, raw: unknown): Checked {
    return check(def, raw)
}

// --- the rules that tie settings together

/**
 * The numbers of a tuple value: the values of an object, or the array.
 *
 * @param v - a tuple value.
 * @returns its parts.
 */
function partsOf(v: SettingValue): (number | string)[] {
    return (Array.isArray(v) ? v : Object.values(v as object)) as (number | string)[]
}

/**
 * Why values break a rule.
 *
 * @param r - the rule.
 * @param values - setting name to value.
 * @returns the reason, or `undefined` if the rule holds or a setting it needs has no
 *     value.
 */
function relationReason(
    r: Relation,
    values: Record<string, SettingValue | undefined>,
): string | undefined {
    const v = values[r.setting]
    const other = r.of === undefined ? undefined : values[r.of]
    if (v === undefined || (r.of !== undefined && other === undefined)) return undefined
    switch (r.rule) {
        case "inside": {
            const [lo, hi] = other as number[]
            return (lo as number) < (v as number) && (v as number) < (hi as number)
                ? undefined
                : `must lie strictly inside ${r.of}`
        }
        case "within_width": {
            const [lo, hi] = other as number[]
            return (v as number) > 0 && (v as number) <= (hi as number) - (lo as number)
                ? undefined
                : `must be above 0 and at most the width of ${r.of}`
        }
        case "ordered": {
            const [first, second] = v as number[]
            if (!((first as number) < (second as number)))
                return "must have its first part below its second"
            if (r.above !== undefined && !((first as number) > r.above))
                return `must have its first part above ${r.above}`
            return undefined
        }
        case "all_above":
            return partsOf(v).every((p) => (p as number) > (r.bound as number))
                ? undefined
                : `must have every part above ${r.bound}`
        case "at_most_setting":
            return (v as number) <= (other as number)
                ? undefined
                : `must be at most ${r.of}`
        case "opacity": {
            const opacity = (v as number[])[1] as number
            return opacity >= 0 && opacity <= 1
                ? undefined
                : "must have an opacity between 0 and 1"
        }
        default:
            return `has an unknown rule ${String((r as Relation).rule)}`
    }
}

/**
 * A rule that the values break.
 *
 * @property setting - the setting the rule is about.
 * @property reason - what is wrong, e.g. `must lie strictly inside BOUNDS_δρ₁₂`.
 * @property relation - the rule.
 */
export type BrokenRelation = { setting: string; reason: string; relation: Relation }

/**
 * The rules that values break. A rule whose settings have no value is skipped.
 *
 * @param relations - the rules.
 * @param values - setting name to (valid) value.
 * @returns the rules broken, in the order of `relations`.
 */
export function checkRelations(
    relations: readonly Relation[],
    values: Record<string, SettingValue | undefined>,
): BrokenRelation[] {
    const broken: BrokenRelation[] = []
    for (const relation of relations) {
        const reason = relationReason(relation, values)
        if (reason !== undefined)
            broken.push({ setting: relation.setting, reason, relation })
    }
    return broken
}

/** The most characters a short reason has for a rule about a number: a value cell. */
export const shortReasonCells = 18

/** The most characters a short reason has for a rule about a tuple: the width of the
 * form it is edited in. */
export const shortReasonCellsTuple = 29

/**
 * What a broken rule says to the user who has just given `setting` a value: at most
 * 18 characters for a rule about a number (the width of a value cell), at most 29 for
 * one about a tuple (the width of the form it is edited in).
 *
 * @param relation - the broken rule.
 * @param setting - the setting that was just given a value (the rule's `setting` or
 *     `of`).
 * @returns the short sentence.
 */
export function shortReason(relation: Relation, setting: string): string {
    const own = setting === relation.setting
    switch (relation.rule) {
        case "at_most_setting":
            return own ? `above ${relation.of}` : `below ${relation.setting}`
        case "inside":
            return own ? "outside the bounds" : "mode out of range"
        case "within_width":
            return own ? "wider than bounds" : "bounds too narrow"
        case "ordered":
            return relation.above === undefined
                ? "first must be below second"
                : `first below second, above ${relation.above}`
        case "all_above":
            return `every part above ${relation.bound}`
        case "opacity":
            return "opacity from 0 to 1"
        default:
            return "breaks a rule"
    }
}

/**
 * What is wrong with the bundled settings data beyond its form: a default that does not
 * keep its own type and limits, or defaults that break a rule. The program's own files
 * must have none; the store checks once and refuses to run otherwise.
 *
 * @param catalog - the settings catalog.
 * @returns one sentence per problem; empty when the data is sound.
 */
export function catalogProblems(catalog: SettingsCatalog): string[] {
    const problems: string[] = []
    const values: Record<string, SettingValue> = {}
    for (const def of catalog.defs()) {
        const r = validateValue(def, def.default)
        if (r.ok) values[def.name] = r.value
        else
            problems.push(
                `${def.name}: its default ${JSON.stringify(def.default)} ${r.error}`,
            )
    }
    if (problems.length > 0) return problems
    return checkRelations(catalog.relations, values).map(
        (b) => `the defaults break a rule: ${b.setting} ${b.reason}`,
    )
}
