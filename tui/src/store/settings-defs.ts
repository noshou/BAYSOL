// SPDX-License-Identifier: LGPL-3.0-or-later

import { readAssetJson } from "../core/assets.js"
import { truncate } from "../core/text.js"

/**
 * What the settings are: their names, kinds, defaults, limits and choices (harvested
 * from the Params.jl files into `assets/data/default_settings.json`), the rules that
 * tie settings together (`setting_relations.json`) and how the settings sheets lay
 * them out (`setting_sheets.json`). Nothing here reads a user's file or checks a
 * value: `settings-validate.ts` judges values, `settings-store.ts` keeps them.
 */

/** The kinds of setting; each is checked in its own way by `settings-validate.ts`. */
export type SettingKind = "int" | "float" | "bool" | "colour" | "font" | "set" | "tuple"

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
 */
export type SettingValue =
    | boolean
    | number
    | string
    | string[]
    | (number | string)[]
    | Record<string, number>

/** The rules that tie settings together, as `setting_relations.json` names them. */
export type RuleName =
    | "inside"
    | "within_width"
    | "ordered"
    | "all_above"
    | "at_most_setting"
    | "opacity"

/**
 * One rule that ties settings together.
 *
 * @property rule - which rule.
 * @property setting - the setting the rule is about.
 * @property of - the other setting it compares with (`inside`, `within_width`,
 *     `at_most_setting`).
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

/** The rule names a [[Relation]] may have. */
export const relationRules: readonly RuleName[] = [
    "inside",
    "within_width",
    "ordered",
    "all_above",
    "at_most_setting",
    "opacity",
]

/** The kinds a setting may have, in the order of [[SettingKind]]. */
export const settingKinds: readonly SettingKind[] = [
    "int",
    "float",
    "bool",
    "colour",
    "font",
    "set",
    "tuple",
]

/** The limit keys the harvest knows. */
const limitKeys: readonly string[] = ["above", "below", "at_least", "at_most"]

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
 * @param name - the setting's name, as in the Julia code (`N_ADAPT`).
 * @param raw - the harvested entry.
 * @param sheet - the id of the sheet that shows it (`sampler`, `model`, ...).
 * @param group - the title of the group on that sheet.
 * @param description - what the setting is, for the sheet.
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
 * One group of settings on a sheet.
 *
 * @property title - the group's title.
 * @property settings - its settings, in the order the sheet shows them.
 */
export type GroupDef = { title: string; settings: SettingDef[] }

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
 * The error of a catalog whose data is wrong (a setting in no group or in two, a
 * default that is not of its own kind). It is a fault of the program's own files, so
 * it is never caught to continue with part of the settings.
 *
 * @param problems - one sentence for each problem found.
 */
export class SettingsCatalogError extends Error {
    constructor(readonly problems: string[]) {
        super(`the settings data is not sound: ${problems.join("; ")}`)
        this.name = "SettingsCatalogError"
    }
}

/**
 * Every setting, found by name or by the sheet and group that show it, with the rules
 * that tie them together. Built once from the bundled data ([[defaultCatalog]]).
 */
export class SettingsCatalog {
    private readonly byName = new Map<string, SettingDef>()

    /**
     * @param sheets - the sheets, each with its groups of settings.
     * @param relations - the rules that tie settings together.
     * @throws [[SettingsCatalogError]] if a name is in two groups.
     */
    constructor(
        readonly sheets: readonly SheetDef[],
        readonly relations: readonly Relation[],
    ) {
        const twice: string[] = []
        for (const def of this.defs()) {
            if (this.byName.has(def.name)) twice.push(def.name)
            this.byName.set(def.name, def)
        }
        if (twice.length > 0)
            throw new SettingsCatalogError(twice.map((n) => `${n} is in two groups`))
    }

    /** @returns every setting, in the order of the sheets and their groups. */
    defs(): SettingDef[] {
        return this.sheets.flatMap((sheet) => sheet.groups.flatMap((g) => g.settings))
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
 * What is wrong with one harvested entry, as sentences. Only its form is looked at
 * (known kind, limit keys, choices, parts); whether the default keeps its own limits is
 * for `catalogProblems` in `settings-validate.ts`.
 *
 * @param name - the setting.
 * @param raw - its entry (anything: the data may be corrupt).
 * @returns the problems; empty if the entry is well formed.
 */
function entryProblems(name: string, raw: unknown): string[] {
    const bad = (what: string): string[] => [`${name}: ${what}`]
    if (typeof raw !== "object" || raw === null) return bad("its entry is not a map")
    const entry = raw as Partial<RawDef>
    if (!settingKinds.includes(entry.type as SettingKind))
        return bad(`it has no known type: ${String(entry.type)}`)
    const limits = entry.limits
    if (
        typeof limits !== "object" ||
        limits === null ||
        !Object.keys(limits).every((k) => limitKeys.includes(k))
    )
        return bad("its limits are not a map of limits")
    if (!("default" in entry) || entry.default === undefined || entry.default === null)
        return bad("it has no default")
    if (entry.type === "set") {
        const choices = entry.choices
        if (
            !Array.isArray(choices) ||
            choices.length === 0 ||
            !choices.every((c) => typeof c === "string")
        )
            return bad("its choices are missing")
    }
    if (entry.type === "tuple") {
        const shape = entry.shape
        const parts = entry.parts
        if (typeof shape !== "object" || shape === null) return bad("it has no shape")
        const kinds = Array.isArray(shape) ? shape : Object.values(shape)
        const size = Array.isArray(entry.default)
            ? entry.default.length
            : Object.keys(entry.default as object).length
        if (kinds.length !== size) return bad("its shape is not the size of its default")
        if (
            !Array.isArray(parts) ||
            parts.length !== kinds.length ||
            !parts.every((p) => typeof p === "string")
        )
            return bad("it has no name for each of its parts")
    }
    return []
}

/**
 * Builds the catalog from the three data files' contents.
 *
 * @param defaults - the harvested defaults (name to entry).
 * @param sheets - the sheet layout.
 * @param relations - the rules that tie settings together.
 * @returns the catalog.
 * @throws [[SettingsCatalogError]] if an entry is malformed, a setting is in no group or
 *     in two, a group names no setting, or a rule is unknown or names no setting.
 */
export function buildCatalog(
    defaults: Record<string, unknown>,
    sheets: RawSheets,
    relations: Relation[],
): SettingsCatalog {
    const problems = Object.entries(defaults).flatMap(([name, raw]) =>
        entryProblems(name, raw),
    )
    if (problems.length > 0) throw new SettingsCatalogError(problems)
    const placed = new Map<string, number>()
    const built: SheetDef[] = sheets.sheets.map((sheet) => ({
        id: sheet.id,
        title: sheet.title,
        groups: sheet.groups.map((group) => ({
            title: group.title,
            settings: group.settings.flatMap((s) => {
                placed.set(s.name, (placed.get(s.name) ?? 0) + 1)
                const raw = defaults[s.name]
                if (raw === undefined) {
                    problems.push(`${s.name} is in a group but has no default`)
                    return []
                }
                return [
                    new SettingDef(
                        s.name,
                        raw as RawDef,
                        sheet.id,
                        group.title,
                        s.description,
                    ),
                ]
            }),
        })),
    }))
    for (const name of Object.keys(defaults)) {
        const n = placed.get(name) ?? 0
        if (n === 0) problems.push(`${name} is in no group`)
        if (n > 1) problems.push(`${name} is in ${n} groups`)
    }
    for (const r of relations) {
        if (!relationRules.includes(r.rule))
            problems.push(`an unknown rule ${String(r.rule)}`)
        for (const name of [r.setting, r.of]) {
            if (name !== undefined && !(name in defaults))
                problems.push(`a rule names ${name}, which is no setting`)
        }
    }
    if (problems.length > 0) throw new SettingsCatalogError(problems)
    return new SettingsCatalog(built, relations)
}

/** The catalog of the bundled data, made on first use. */
let bundled: SettingsCatalog | undefined

/**
 * The catalog of the bundled data (`assets/data/*.json`), made once.
 *
 * @returns the catalog.
 * @throws [[SettingsCatalogError]] if the bundled data is not sound, or an error if a
 *     file cannot be read.
 */
export function defaultCatalog(): SettingsCatalog {
    bundled ??= buildCatalog(
        readAssetJson<Record<string, unknown>>("data", "default_settings.json"),
        readAssetJson<RawSheets>("data", "setting_sheets.json"),
        readAssetJson<Relation[]>("data", "setting_relations.json"),
    )
    return bundled
}

/** The characters of a value that fit the value cell of a sheet (a space, the value, and
 * a column kept for the mark of an unsaved value make 19). */
export const valueCellWidth = 17

/**
 * The text of a value for the value cell of a sheet, at most 17 cells: a colour name as
 * it is, a tuple in parentheses with its parts separated by `, `, and a text that is too
 * long cut short with `…`.
 *
 * @param value - the value.
 * @returns the text.
 */
export function formatValue(value: SettingValue): string {
    const text = Array.isArray(value)
        ? `(${value.join(", ")})`
        : typeof value === "object"
          ? `(${Object.values(value).join(", ")})`
          : String(value)
    return truncate(text, valueCellWidth)
}
