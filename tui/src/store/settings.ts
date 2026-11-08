// SPDX-License-Identifier: LGPL-3.0-or-later

// Settings: the definitions of the settings and the rules that check them.
//
// Contents:
//   1. Definitions: the catalog of the bundled data, its types and lookups
//   2. Validation: checking a value, the relations between values, the catalog itself
//
// The files, the load/save with their locks, the scopes and the theme preference are in
// `settings-store.ts`.

import { lazy, readAssetJson } from "../core/environment.js"
import { isDict } from "../core/file-system.js"

// ========================================================================================
// 1. Definitions
// ========================================================================================

/**
 * What the settings are: their names, kinds, defaults, limits and choices (harvested
 * from the Params.jl files into `assets/data/default_settings.json`), the rules that
 * tie settings together (`setting_relations.json`) and how the settings sheets lay
 * them out (`setting_sheets.json`, only the settings a run applies). Nothing here reads
 * a user's file or checks a value: the validation section below judges values,
 * `settings-store.ts` keeps them.
 */

/** The kinds of setting; each is checked in its own way by the validation section. */
export type SettingKind =
    | "int"
    | "float"
    | "bool"
    | "colour"
    | "font"
    | "set"
    | "tuple"
    | "optional_int"
    | "optional_float"
    | "ranges"
    | "strings"
    | "colours"
    | "markers"
    | "sizes"

/** The kinds a part of a tuple can have. */
export type PartKind = "int" | "float" | "colour"

/**
 * The limits of a number setting, under the key names of the harvest: a value must be
 * `above` / `below` the bound (exclusive) or `at_least` / `at_most` it (inclusive).
 */
export type Limits = {
    above?: number
    below?: number
    at_least?: number
    at_most?: number
}

/**
 * The value of a setting, in the type its kind has: a boolean, a number, a string (a
 * font, or a colour as a name or `#rrggbb`), the chosen strings of a `set`, a tuple as
 * an array of numbers and colour strings, or a tuple with named parts as an object.
 * `null` is an optional number that is not given (no limit, automatic), a list of
 * `[lo, hi]` pairs is a `ranges` setting (a list of `[width, height]` pairs `sizes`), a
 * list of single-character strings `strings` (of colours `colours`, of marker names
 * `markers`).
 */
export type SettingValue =
    | null
    | boolean
    | number
    | string
    | string[]
    | (number | string)[]
    | number[][]
    | Record<string, number>

/** The rules that tie settings together, as `setting_relations.json` names them. */
type RuleName =
    | "inside"
    | "within_width"
    | "ordered"
    | "all_above"
    | "at_most_setting"
    | "below_setting"
    | "opacity"

/**
 * One rule that ties settings together.
 *
 * @property rule - which rule.
 * @property setting - the setting the rule is about.
 * @property of - the other setting it compares with (`inside`, `within_width`,
 *     `at_most_setting`, `below_setting`).
 * @property above - the floor of the first part of a pair (`ordered`).
 * @property bound - the bound every part must exceed (`all_above`).
 */
export type Relation = {
    rule: RuleName
    setting: string
    of?: string
    above?: number
    bound?: number
}

/** What `default_settings.json` holds for one setting. */
type RawDef = {
    default: SettingValue
    type: SettingKind
    limits: Limits
    shape?: PartKind[] | Record<string, PartKind>
    parts?: string[]
    choices?: string[]
}

/** The groups of `setting_sheets.json`, as written there. */
type RawSheets = {
    sheets: {
        id: string
        title: string
        groups: { title: string; settings: { name: string; description: string }[] }[]
    }[]
}

/**
 * One setting, with where its sheet shows it.
 *
 * @param sheet - the id of the sheet that shows it (`sampler`, `model`, ...).
 */
export class SettingDef {
    readonly kind: SettingKind
    readonly default: SettingValue
    readonly limits: Limits
    /** The strings a `set` setting chooses from (empty for the other kinds). */
    readonly choices: readonly string[]
    /** The names of the parts of a tuple, in order (empty for the other kinds). */
    readonly partNames: readonly string[]
    /** The kind of each part of a tuple, in the order of `partNames`. */
    readonly partKinds: readonly PartKind[]
    /** Whether a tuple is an object with named parts rather than an array. */
    readonly isRecord: boolean

    constructor(
        readonly name: string,
        raw: RawDef,
        readonly sheet: string,
        readonly group: string,
        readonly description: string,
    ) {
        this.kind = raw.type
        this.default = raw.default
        this.limits = raw.limits
        this.choices = raw.choices ?? []
        this.partNames = raw.parts ?? []
        const shape = raw.shape
        this.isRecord = shape !== undefined && !Array.isArray(shape)
        this.partKinds =
            shape === undefined ? [] : Array.isArray(shape) ? shape : Object.values(shape)
    }
}

/**
 * The settings of the whole run, which a model's own settings may not name (Julia's
 * `RUN_LEVEL_SETTINGS` in `Pipeline/Settings.jl`, which refuses them with an error that
 * fails the run); every `PLOT_*` setting is one too (see [[isRunLevel]]). A test reads the
 * Julia source and compares, so the two cannot drift.
 */
export const runLevelSettings: readonly string[] = [
    "TABLE_SIGFIGS",
    "FIGURES_TEX",
    "FIGURES_COMPILE",
    "FIGURES_FORMATS",
]

/** The prefix of the settings of the figures' look: all of them are run-level. */
export const RUN_LEVEL_PREFIX = "PLOT_"

/** Whether a setting belongs to the whole run: it cannot be set for one model. */
export const isRunLevel = (name: string): boolean =>
    runLevelSettings.includes(name) || name.startsWith(RUN_LEVEL_PREFIX)

/** The screen of `settings.json` that holds the settings no sheet shows. */
const hiddenSheet = "other"

/**
 * One group of settings on a sheet.
 *
 * @property title - the group's title.
 * @property settings - its settings, in the order the sheet shows them.
 */
type GroupDef = { title: string; settings: SettingDef[] }

/**
 * One settings sheet.
 *
 * @property id - `sampler`, `model`, `output` or `plots`; also the screen key of
 *     `settings.json`.
 * @property title - the sheet's title.
 * @property groups - the groups, in order.
 */
export type SheetDef = { id: string; title: string; groups: GroupDef[] }

/**
 * Every setting, found by name or by the sheet and group that show it, with the rules
 * that tie them together. Built once from the bundled data ([[defaultCatalog]]). A
 * setting that a run ignores is on no sheet (its `sheet` is [[hiddenSheet]], the screen
 * it is written under in `settings.json`): it is still known, so a file written by hand
 * or by the CLI keeps it and it is checked like the rest.
 */
export class SettingsCatalog {
    private readonly byName = new Map<string, SettingDef>()

    /**
     * @param sheets - the sheets, each with its groups of settings.
     * @param relations - the rules that tie settings together.
     * @param hidden - the settings no sheet shows.
     */
    constructor(
        readonly sheets: readonly SheetDef[],
        readonly relations: readonly Relation[],
        private readonly hidden: readonly SettingDef[] = [],
    ) {
        for (const def of this.defs()) this.byName.set(def.name, def)
    }

    /** @returns every setting: those of the sheets in their order, then the hidden. */
    defs(): SettingDef[] {
        return [
            ...this.sheets.flatMap((sheet) => sheet.groups.flatMap((g) => g.settings)),
            ...this.hidden,
        ]
    }

    /**
     * @param name - a setting's name.
     * @returns its definition, or `undefined` if there is no such setting.
     */
    get(name: string): SettingDef | undefined {
        return this.byName.get(name)
    }

    /**
     * @param name - a setting's name.
     * @returns its definition.
     * @throws if there is no such setting.
     */
    require(name: string): SettingDef {
        const def = this.byName.get(name)
        if (def === undefined) throw new Error(`${name} is not a setting`)
        return def
    }

    /**
     * @param id - a sheet id.
     * @returns the sheet, or `undefined` if there is none of that id.
     */
    sheet(id: string): SheetDef | undefined {
        return this.sheets.find((s) => s.id === id)
    }
}

/**
 * The sheets as one model's settings show them: without the run-level settings, a group
 * with none left dropped and a sheet with no group left (`plots`) not offered.
 */
export function modelSheets(catalog: SettingsCatalog): SheetDef[] {
    return catalog.sheets
        .map((sheet) => ({
            ...sheet,
            groups: sheet.groups
                .map((g) => ({
                    ...g,
                    settings: g.settings.filter((d) => !isRunLevel(d.name)),
                }))
                .filter((g) => g.settings.length > 0),
        }))
        .filter((sheet) => sheet.groups.length > 0)
}

/**
 * The catalog of the bundled data (`assets/data/*.json`), made once. The data ships with
 * the program and the unit tests check that it is sound.
 *
 * @throws if a file cannot be read.
 */
export const defaultCatalog: () => SettingsCatalog = lazy(() => {
    const defaults = readAssetJson<Record<string, RawDef>>("data", "default_settings.json")
    const sheets = readAssetJson<RawSheets>("data", "setting_sheets.json").sheets.map(
        (sheet): SheetDef => ({
            id: sheet.id,
            title: sheet.title,
            groups: sheet.groups.map((group) => ({
                title: group.title,
                settings: group.settings.map(
                    (s) =>
                        new SettingDef(
                            s.name,
                            defaults[s.name],
                            sheet.id,
                            group.title,
                            s.description,
                        ),
                ),
            })),
        }),
    )
    const shown = new Set(
        sheets.flatMap((s) => s.groups.flatMap((g) => g.settings.map((d) => d.name))),
    )
    const hidden = Object.entries(defaults)
        .filter(([name]) => !shown.has(name))
        .map(([name, raw]) => new SettingDef(name, raw, hiddenSheet, "", ""))
    const relations = readAssetJson<Relation[]>("data", "setting_relations.json")
    return new SettingsCatalog(sheets, relations, hidden)
})

// ---- colours: the names a colour setting may take, and how a colour looks -------------
//
// The editor offers them as a list to pick from: `assets/data/colours.json`, harvested from
// the names `Colors.parse` knows. A font is plain text (Julia checks it, not the TUI).

/** The colours of `colours.json`, name to `#rrggbb`, in the order of the (sorted) file. */
const colours: () => Map<string, string> = lazy(() => {
    const file = readAssetJson<Record<string, string>>("data", "colours.json")
    return new Map(Object.entries(file))
})

/**
 * The colour of a name as the `#rrggbb` text a terminal colour takes, for a `Swatch`.
 *
 * @param colour - a name of the list, or a `#rrggbb` text (its own colour).
 */
export function colourHex(colour: string): string | undefined {
    if (/^#[0-9a-f]{6}$/.test(colour)) return colour
    return colours().get(colour)
}

/** @returns every colour name, sorted. */
export const colourNames = (): readonly string[] => [...colours().keys()]

// ========================================================================================
// 2. Validation
// ========================================================================================

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

/**
 * Whether a raw value is a colour a figure can use: a string named like a colour of the
 * list, or `#rrggbb`.
 *
 * @returns the colour (name or hex) it stands for, or `undefined` if it is none.
 */
function colourOf(raw: unknown): string | undefined {
    if (typeof raw !== "string") return undefined
    return hexColour.test(raw) || colours().has(raw) ? raw : undefined
}

/**
 * The whole number a raw value is, if it is one (a plain JavaScript integer that keeps
 * its precision; the number editors take at most 15 digits anyway).
 */
function wholeOf(raw: unknown): number | undefined {
    return typeof raw === "number" && Number.isSafeInteger(raw) ? raw : undefined
}

/** The finite number a raw value is, if it is one (a whole number or a float). */
function finiteOf(raw: unknown): number | undefined {
    return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined
}

/** What is wrong with the number `v` under limits, if anything. */
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

/** One part of a tuple, checked against the kind of that part. */
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

/** A list of `[lo, hi]` pairs of q, each `0 <= lo < hi` (as `_range_value` of Julia). */
function checkRanges(raw: unknown): Checked {
    if (!Array.isArray(raw))
        return { ok: false, error: "must be a list of (q_lo, q_hi) pairs" }
    const pairs: number[][] = []
    for (const x of raw) {
        if (!Array.isArray(x) || x.length !== 2)
            return { ok: false, error: "each range must be a pair (q_lo, q_hi)" }
        const [lo, hi] = [finiteOf(x[0]), finiteOf(x[1])]
        if (lo === undefined || hi === undefined)
            return { ok: false, error: "each range must be a pair of numbers" }
        if (!(lo >= 0 && lo < hi))
            return { ok: false, error: "each range needs 0 <= q_lo < q_hi" }
        pairs.push([lo, hi])
    }
    return { ok: true, value: pairs }
}

/** A list of unique chain ids, each one visible character (as `_chain_id` of Julia). */
function checkChains(raw: unknown): Checked {
    if (!Array.isArray(raw)) return { ok: false, error: "must be a list of chain ids" }
    for (const x of raw) {
        if (typeof x !== "string" || [...x].length !== 1 || /[\s\p{Cc}]/u.test(x))
            return { ok: false, error: "each chain must be one character" }
    }
    if (new Set(raw).size !== raw.length)
        return { ok: false, error: "must not repeat a chain" }
    return { ok: true, value: raw as string[] }
}

/** The names of a list setting must be strings, as JSON holds them. */
const isList = (raw: unknown): raw is unknown[] => Array.isArray(raw) && raw.length > 0

/** A non-empty list of colours: names of the list or `#rrggbb` (as `:colours` of Julia). */
function checkColours(raw: unknown): Checked {
    if (!isList(raw)) return { ok: false, error: "must be a non-empty list of colours" }
    if (!raw.every((x) => colourOf(x) !== undefined))
        return { ok: false, error: "must hold only colours: name or #rrggbb" }
    return { ok: true, value: raw as string[] }
}

/** A non-empty list of marker names of the choices (as `:markers` of Julia). */
function checkMarkers(def: SettingDef, raw: unknown): Checked {
    if (!isList(raw)) return { ok: false, error: "must be a non-empty list of markers" }
    if (!raw.every((x) => typeof x === "string" && def.choices.includes(x)))
        return { ok: false, error: "must hold only markers of the list" }
    return { ok: true, value: raw as string[] }
}

/** The smallest and the largest `[width, height]` of a size (`PLOT_TUI_SIZE_LIMITS`). */
const sizeLimits = { min: [24, 3], max: [400, 100] } as const

/** A non-empty list of `[width, height]` that grows in both (as `:sizes` of Julia). */
function checkSizes(raw: unknown): Checked {
    if (!isList(raw)) return { ok: false, error: "must be a non-empty list of sizes" }
    const sizes: number[][] = []
    for (const x of raw) {
        if (!Array.isArray(x) || x.length !== 2)
            return { ok: false, error: "each size must be a pair [width, height]" }
        const [w, h] = [wholeOf(x[0]), wholeOf(x[1])]
        if (w === undefined || h === undefined)
            return { ok: false, error: "each size must be whole numbers" }
        const { min, max } = sizeLimits
        if (w < min[0] || w > max[0] || h < min[1] || h > max[1])
            return {
                ok: false,
                error: `each size needs ${min[0]}-${max[0]} x ${min[1]}-${max[1]}`,
            }
        sizes.push([w, h])
    }
    for (const [i, [w, h]] of sizes.entries()) {
        const before = sizes[i - 1]
        if (before !== undefined && !(w > before[0] && h > before[1]))
            return { ok: false, error: "must grow in both width and height" }
    }
    return { ok: true, value: sizes }
}

/**
 * Checks a tuple value: an array of the number of parts of the default, or an object
 * with exactly its keys, each part of its kind.
 *
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
 * Checks a value: one a person gave (typed on the number editor, picked from a list) or
 * one read from `settings.json`. Pass what the editor holds (a number, a boolean, a
 * string for a font, a colour or a choice, an array or an object for a tuple); text typed
 * into a number editor must be turned into a number first.
 *
 * @returns `{ ok: true, value }` with the value in the type the setting has, or
 *     `{ ok: false, error }` with a sentence such as `must be above 0`.
 */
export function validateValue(def: SettingDef, raw: unknown): Checked {
    if (raw === null && (def.kind === "optional_int" || def.kind === "optional_float"))
        return { ok: true, value: null }
    const limited = (x: number): Checked => {
        const error = limitError(x, def.limits)
        return error === undefined ? { ok: true, value: x } : { ok: false, error }
    }
    switch (def.kind) {
        case "bool":
            return typeof raw === "boolean"
                ? { ok: true, value: raw }
                : { ok: false, error: "must be true or false" }
        case "int":
        case "optional_int": {
            const n = wholeOf(raw)
            const or = def.kind === "int" ? "" : " or null"
            return n === undefined
                ? { ok: false, error: `must be a whole number${or}` }
                : limited(n)
        }
        case "float":
        case "optional_float": {
            const n = finiteOf(raw)
            const or = def.kind === "float" ? "" : " or null"
            return n === undefined
                ? { ok: false, error: `must be a finite number${or}` }
                : limited(n)
        }
        case "ranges":
            return checkRanges(raw)
        case "strings":
            return checkChains(raw)
        case "colours":
            return checkColours(raw)
        case "markers":
            return checkMarkers(def, raw)
        case "sizes":
            return checkSizes(raw)
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

// --- the rules that tie settings together

/** The numbers of a tuple value: the values of an object, or the array. */
function partsOf(v: SettingValue): (number | string)[] {
    return (Array.isArray(v) ? v : Object.values(v as object)) as (number | string)[]
}

/**
 * Why values break a rule.
 *
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
    if (r.rule === "below_setting" && (v === null || other === null)) return undefined
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
        case "below_setting":
            return (v as number) < (other as number)
                ? undefined
                : `must be below ${r.of}`
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
 * @property reasonOf - the same said on the row of the other setting (`of`), e.g.
 *     `must hold MODE_δρ₁₂ strictly inside`.
 * @property relation - the rule.
 */
export type BrokenRelation = {
    setting: string
    reason: string
    reasonOf: string
    relation: Relation
}

/** The reason of a broken rule as the row of the setting `name` says it. */
export function reasonFor(b: BrokenRelation, name: string): string {
    return name === b.relation.of ? b.reasonOf : b.reason
}

/** What the row of `of` says when its rule is broken (the rule seen from the other end). */
function reasonOfOther(r: Relation): string {
    switch (r.rule) {
        case "inside":
            return `must hold ${r.setting} strictly inside`
        case "within_width":
            return `width must exceed ${r.setting}`
        case "at_most_setting":
            return `must be at least ${r.setting}`
        case "below_setting":
            return `must be above ${r.setting}`
        default:
            return ""
    }
}

/** The rules that values break. A rule whose settings have no value is skipped. */
export function checkRelations(
    relations: readonly Relation[],
    values: Record<string, SettingValue | undefined>,
): BrokenRelation[] {
    const broken: BrokenRelation[] = []
    for (const relation of relations) {
        const reason = relationReason(relation, values)
        if (reason !== undefined)
            broken.push({
                setting: relation.setting,
                reason,
                reasonOf: reasonOfOther(relation),
                relation,
            })
    }
    return broken
}
