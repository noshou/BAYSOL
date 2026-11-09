// SPDX-License-Identifier: LGPL-3.0-or-later

// The settings screens: the sheet and its editors, the menu, and what the landings share.
//
// Contents:
//   1. The editors: one text line, or a colour or font picked from a list
//   2. `SettingsSheet`: one group of settings
//   3. `SettingsMenu`: the groups
//   4. Shared
//   5. `CustomLanding`: the recipes and the custom solutes

import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useReducer, useState } from "react"
import { appDir, cacheDir, readSystem } from "../core/environment.js"
import { quarantine } from "../core/file-system.js"
import { listFonts } from "../core/fonts.js"
import { truncateStart, wrapText } from "../core/terminal.js"
import { readRecipes, recipesFile } from "../store/buffer.js"
import { customFile, readCustomSolutes } from "../store/custom.js"
import {
    colourHex,
    type FontLists,
    modelSheets,
    type SettingDef,
    type SettingValue,
    settingNames,
} from "../store/settings.js"
import {
    loadScope,
    type Scope,
    sameValue,
    scopeTitle,
} from "../store/settings-store.js"
import { Frame, footerExtraLines } from "../ui/frame.js"
import {
    GridMenu,
    type LegendItem,
    legendBack,
    legendEnter,
    legendFor,
    legendOf,
    MenuHeader,
    MenuSpec,
    moveLegend,
} from "../ui/grid.js"
import {
    type Confirm,
    Entry,
    Prompt,
    questionLegend,
    type Suggestion,
    useConfirm,
    useDiscardGuard,
} from "../ui/input.js"
import {
    CursorList,
    type KeyInput,
    keys,
    ListText,
    Swatch,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useListCursor,
    useNav,
} from "../ui/interaction.js"
import { DataTable, useTheme } from "../ui/theme.js"
import { CustomSolutesTable, RecipesTable } from "./custom-solutes.js"
import {
    customLandingOptions,
    type EditEnd,
    indexOfPick,
    type ListKind,
    maxNameText,
    maxSettingText,
    narrow,
    parseSetting,
    pickValue,
    swatchColour,
    valueText,
    withDraft,
    withModelDraft,
} from "./screen-rules.js"

// ========================================================================================
// 1. The editors
// ========================================================================================

/** The most colours or fonts the picker shows at once. */
const pickerLines = 5

/** Whether a setting is picked from a list (a colour or a font). */
const isPicked = (def: SettingDef): boolean => def.kind === "colour" || def.kind === "font"

/** The rows an editor takes under the table: its label, an error, and the list. */
const editorRows = (def: SettingDef): number => (isPicked(def) ? pickerLines + 3 : 3)

/** The kinds typed as a list, which need a longer line (the default colours are 70). */
const listKinds: ReadonlySet<string> = new Set(["colours", "markers", "sizes"])

/** The most characters a list line takes. */
const maxListText = 200

/** The most characters a path line takes. */
const maxPathText = 1000

/** What an editor is told: the setting, its value now and what to call when it is over. */
type EditorProps = {
    def: SettingDef
    current: SettingValue
    /** The installed fonts, for a font setting (listed when its editor is opened). */
    fonts?: FontLists
    onEnd: (end: EditEnd<SettingValue>) => void
    onLegend: (keys: LegendItem[]) => void
}

/** What a setting's text line asks for, by its kind. */
function textHint(def: SettingDef): { label: string; placeholder?: string } {
    switch (def.kind) {
        case "set":
            return { label: "some of:", placeholder: def.choices.join(" ") }
        case "tuple":
            return { label: `${def.partNames.join(", ")}:` }
        case "ranges":
            return { label: "q ranges:", placeholder: "0.1-0.2, 0.5-0.6 (empty: none)" }
        case "strings":
            return { label: "chains:", placeholder: "A B (empty: all chains)" }
        case "colours":
            return { label: "colours:", placeholder: "#D55E00, #0072B2, red" }
        case "markers":
            return { label: "markers:", placeholder: "o, square, triangle" }
        case "sizes":
            return { label: "sizes:", placeholder: "76x5, 100x9 (growing)" }
        case "path":
            return { label: "path:", placeholder: "empty: the default" }
        case "optional_int":
        case "optional_float":
            return { label: "number:", placeholder: `empty: ${valueText(def, null)}` }
        default:
            return { label: "number:" }
    }
}

/**
 * A number, some choices, a font or a tuple, typed as one line into the shared [[Prompt]]
 * and read by `parseSetting`. A wrong text stays as an error under the line until the
 * next key.
 */
function TextEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
    const [error, setError] = useState<string>()
    const clearError = useCallback(() => setError(undefined), [])
    const { label, placeholder } = textHint(def)
    return (
        <Prompt
            label={label}
            initial={def.kind === "path" ? (current as string) : valueText(def, current)}
            maxLength={
                def.kind === "path"
                    ? maxPathText
                    : listKinds.has(def.kind)
                        ? maxListText
                        : maxSettingText
            }
            placeholder={placeholder}
            error={error}
            onChange={clearError}
            onSubmit={(text) => {
                const parsed = parseSetting(def, text)
                if ("error" in parsed) setError(parsed.error)
                else onEnd({ kind: "done", value: parsed.value })
            }}
            onCancel={() => onEnd({ kind: "cancel" })}
            onBack={() => onEnd({ kind: "back" })}
            onLegend={onLegend}
        />
    )
}

/**
 * A colour or a font picked from the list of names, narrowing as one types; `#rrggbb`
 * is typed. The math font setting lists the fonts with a MATH table, the text font
 * setting the other fonts; a name not in the list is refused (on a machine with no
 * fonts found the text is taken as typed).
 */
function PickerEditor({ def, current, fonts, onEnd, onLegend }: EditorProps): ReactNode {
    const kind: ListKind = def.kind === "font" ? "font" : "colour"
    const names = useMemo(
        () => settingNames(def.name, kind, fonts),
        [def.name, kind, fonts],
    )
    const [error, setError] = useState<string>()
    const suggest = useCallback(
        (text: string): Suggestion[] =>
            narrow(names, text).map((label) => ({
                label,
                swatch: kind === "colour" ? colourHex(label) : undefined,
            })),
        [names, kind],
    )
    const clearError = useCallback(() => setError(undefined), [])
    return (
        <Entry
            label={`${kind}:`}
            maxLength={maxNameText}
            placeholder="type to narrow"
            suggest={suggest}
            initialIndex={indexOfPick(names, current as string)}
            wrap
            counter
            noMatch="no match"
            lines={pickerLines}
            error={error}
            onChange={clearError}
            onSubmit={(text, chosen) => {
                const picked = pickValue(kind, names, text, chosen?.label)
                if ("error" in picked) setError(picked.error)
                else onEnd({ kind: "done", value: picked.value })
            }}
            onCancel={() => onEnd({ kind: "cancel" })}
            onBack={() => onEnd({ kind: "back" })}
            onLegend={onLegend}
        />
    )
}

// ========================================================================================
// 2. The settings sheet
// ========================================================================================

/** What the sheet is told: whose settings, and which sheet (`output`, `model`, ...). */
type SettingsSheetProps = { scope: Scope; sheetId: string }

/** The lines the description of the highlighted setting may take (always reserved). */
const descriptionLines = 3

/** The rows the table spends besides its settings: header, rule and the position line. */
const tableRows = 3

/** The lines of keys the frame's row count holds without growing. */
const SHEET_LEGEND_LINES = 3

/** What `^r` is called: a model's settings go back to the project's. */
const resetLabel = (scope: Scope): string =>
    scope.kind === "model" ? "inherit group" : "reset group"

/** The keys the sheet can show at most, for the footer to reserve their height. */
const sheetFullFor = (scope: Scope): LegendItem[] => [
    legendBack,
    legendFor("save", keys.save),
    legendFor("edit", keys.enter),
    legendFor("next group", keys.right),
    legendFor("prev group", keys.left),
    moveLegend({ up: true, down: true }) as LegendItem,
    legendFor("undo", keys.undo),
    legendFor(resetLabel(scope), keys.remove),
]

/** What the source column of a model's sheet says of a setting. */
const OVERRIDDEN = "overridden"
const INHERITED = "inherited"

/** `1 setting`, `3 settings`. */
function plural(n: number): string {
    return `${n} setting${n === 1 ? "" : "s"}`
}

/** Copy of a map without some keys. */
function without<V>(map: ReadonlyMap<string, V>, ...gone: string[]): Map<string, V> {
    const next = new Map(map)
    for (const name of gone) next.delete(name)
    return next
}

/**
 * A settings sheet: one group of settings at a time as a list of names and values, the
 * description of the highlighted one under it. Up and down move, left and right switch
 * group, Enter edits. An edit becomes a draft, marked `*`, kept until saved (^w) or
 * undone (^u one setting, ^r the group). Saving checks all the drafts together; if
 * anything is wrong nothing is saved and each setting at fault is marked `!`. Leaving
 * with drafts asks first.
 */
function SettingsSheet({ scope, sheetId }: SettingsSheetProps): ReactNode {
    // the settings are read once per opening of the sheet, wiped values noticed
    const [loaded] = useState(() => loadScope(scope))
    const { settings } = loaded
    const model = scope.kind === "model"
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    // a model's sheets leave out the settings of the whole run (see `modelSheets`)
    const sheet = (model ? modelSheets(settings.catalog) : settings.catalog.sheets).find(
        (s) => s.id === sheetId,
    )
    if (sheet === undefined) throw new Error(`there is no settings sheet ${sheetId}`)
    const groups = sheet.groups

    const [group, setGroup] = useState(0)
    const [drafts, setDrafts] = useState<ReadonlyMap<string, SettingValue>>(new Map())
    const [errors, setErrors] = useState<ReadonlyMap<string, string>>(new Map())
    // notices of wiped settings that an edit has dealt with
    const [dismissed, setDismissed] = useState<ReadonlySet<string>>(new Set())
    const [editing, setEditing] = useState<string>()
    // the installed fonts, listed (and cached on disk) the first time a font is edited
    const [fonts, setFonts] = useState<FontLists>()
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    const [status, setStatus] = useState<{ text: string; error: boolean } | undefined>(
        () =>
            model && loaded.reset
                ? { text: "unusable file: kept .corrupt", error: true }
                : undefined,
    )
    const [, redraw] = useReducer((n: number) => n + 1, 0)
    const guard = useDiscardGuard(drafts.size)

    const defs = groups[group]?.settings ?? []
    const editedDef = editing === undefined ? undefined : settings.catalog.get(editing)
    // the footer's box (blocky) and any key lines beyond the three the frame holds
    const sheetFull = sheetFullFor(scope)
    const footerExtra = footerExtraLines(sheetFull, columns, SHEET_LEGEND_LINES, "blocky")
    const pageSize = useBodyRows(
        tableRows + footerExtra + (editedDef ? editorRows(editedDef) : descriptionLines),
    )
    const cursor = useListCursor(defs.length, pageSize)
    const here = defs[cursor.index] as SettingDef

    const noticeOf = (name: string): string | undefined =>
        dismissed.has(name) ? undefined : settings.notices.get(name)
    const valueFor = (d: SettingDef): SettingValue =>
        drafts.has(d.name) ? (drafts.get(d.name) as SettingValue) : settings.get(d.name)
    // a model's value is its own (overridden) when it differs from the project's: a draft
    // is judged by its value, a saved one by its being saved
    const overridden = (d: SettingDef): boolean =>
        drafts.has(d.name)
            ? !sameValue(valueFor(d), settings.resetValue(d.name))
            : settings.isSaved(d.name)
    const resettable = defs.some((d) =>
        model ? overridden(d) : !sameValue(valueFor(d), settings.resetValue(d.name)),
    )
    const hasPrev = group > 0
    const hasNext = group < groups.length - 1

    // --- what the keys do
    const draft = (d: SettingDef, value: SettingValue): void => {
        setDrafts((was) =>
            model
                ? withModelDraft(was, d.name, settings, value)
                : withDraft(was, d.name, settings.get(d.name), value),
        )
        setErrors((was) => without(was, d.name))
    }
    const undo = (d: SettingDef): void => {
        setDrafts((was) => without(was, d.name))
        setErrors((was) => without(was, d.name))
    }
    const resetGroup = (): void => {
        setDrafts((was) => {
            let next = was
            for (const d of defs) {
                if (model && !overridden(d)) continue
                const reset = settings.resetValue(d.name)
                next = model
                    ? withModelDraft(next, d.name, settings, reset)
                    : withDraft(next, d.name, settings.get(d.name), reset)
            }
            return next
        })
        setErrors((was) => without(was, ...defs.map((d) => d.name)))
        setDismissed((was) => new Set([...was, ...defs.map((d) => d.name)]))
    }
    const save = (): void => {
        const changes = Object.fromEntries(drafts)
        const ev = settings.evaluate(changes)
        if (!ev.ok) {
            setErrors(ev.errors)
            setStatus({
                text: `${plural(ev.errors.size)} cannot be saved: see the rows marked !`,
                error: true,
            })
            return
        }
        try {
            settings.set(changes)
            settings.save()
        } catch (e) {
            setStatus({ text: `could not save: ${(e as Error).message}`, error: true })
            return
        }
        setStatus({ text: `saved ${plural(drafts.size)}`, error: false })
        setDrafts(new Map())
        setErrors(new Map())
        redraw()
    }
    const edit = (d: SettingDef): void => {
        if (d.kind === "bool") draft(d, !(valueFor(d) as boolean))
        else {
            if (d.kind === "font")
                setFonts((was) => was ?? listFonts(readSystem(), cacheDir()))
            setEditing(d.name)
        }
    }
    const endEdit = (end: EditEnd<SettingValue>): void => {
        setEditing(undefined)
        if (end.kind === "back") guard.leave(nav.pop)
        else if (end.kind === "done" && editedDef !== undefined) {
            draft(editedDef, end.value)
            setDismissed((was) => new Set([...was, editedDef.name]))
        }
    }
    const goto = (g: number): void => {
        setGroup(g)
        cursor.set(0)
    }

    useKeys((press) => {
        if (guard.handleKey(press)) return
        setStatus(undefined)
        if (press.is(keys.back)) guard.leave(nav.pop)
        else if (press.is(keys.save) && drafts.size > 0) save()
        else if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.left) && hasPrev) goto(group - 1)
        else if (press.is(keys.right) && hasNext) goto(group + 1)
        else if (press.is(keys.enter)) edit(here)
        else if (press.is(keys.undo)) undo(here)
        else if (press.is(keys.remove) && resettable) resetGroup()
    }, editing === undefined)

    // --- drawing
    const fault = errors.get(here.name)
    const notice = noticeOf(here.name)
    const note =
        guard.note ??
        status?.text ??
        (fault && `${here.name} ${fault}`) ??
        (notice && `${here.name}: ${notice}`)
    const noteIsError = guard.question === undefined && (status?.error === true || !status)
    const legend =
        editedDef !== undefined
            ? promptKeys
            : legendOf([
                legendBack,
                drafts.size > 0 && legendFor("save", keys.save),
                legendFor("edit", keys.enter),
                hasNext && legendFor("next group", keys.right),
                hasPrev && legendFor("prev group", keys.left),
                moveLegend({ up: cursor.index > 0, down: cursor.index < defs.length - 1 }),
                drafts.has(here.name) && legendFor("undo", keys.undo),
                resettable && legendFor(resetLabel(scope), keys.remove),
            ])
    const longest = Math.max(1, ...defs.map((d) => d.name.length))
    const shade = swatchColour(here, valueFor(here))
    const description = wrapText(here.description, columns).slice(0, descriptionLines)

    return (
        <Frame
            design="blocky"
            title={`${sheet.title} settings`}
            subtitle={
                scope.kind === "model"
                    ? `model: ${scope.model} · ${scope.project.id}`
                    : scope.kind === "project"
                        ? `${scopeTitle(scope)} · ${scope.project.id}`
                        : scopeTitle(scope)
            }
            counter={`${groups[group]?.title ?? ""} [${group + 1} / ${groups.length}]`}
            legend={legend}
            legendFull={sheetFull}
            note={note || undefined}
            noteIsError={noteIsError}
        >
            <DataTable
                border="double"
                columns={[
                    { title: "name", width: longest, text: (d: SettingDef) => d.name },
                    {
                        title: "value",
                        text: (d: SettingDef) => valueText(d, valueFor(d)),
                    },
                    ...(model
                        ? [
                            {
                                title: "here",
                                width: OVERRIDDEN.length,
                                text: (d: SettingDef) =>
                                    overridden(d) ? OVERRIDDEN : INHERITED,
                            },
                        ]
                        : []),
                ]}
                emphasis={model ? overridden : undefined}
                rows={defs}
                cursor={cursor.index}
                offset={cursor.offset}
                pageSize={pageSize}
                mark={(d) =>
                    errors.has(d.name) || noticeOf(d.name) !== undefined
                        ? "!"
                        : drafts.has(d.name)
                            ? "*"
                            : " "
                }
                width={columns}
            />
            <Box flexDirection="column" marginTop={1}>
                {editedDef ? (
                    <Box flexDirection="column" height={editorRows(editedDef)}>
                        {isPicked(editedDef) ? (
                            <PickerEditor
                                key={editedDef.name}
                                def={editedDef}
                                current={valueFor(editedDef)}
                                fonts={fonts}
                                onEnd={endEdit}
                                onLegend={setPromptKeys}
                            />
                        ) : (
                            <TextEditor
                                key={editedDef.name}
                                def={editedDef}
                                current={valueFor(editedDef)}
                                onEnd={endEdit}
                                onLegend={setPromptKeys}
                            />
                        )}
                    </Box>
                ) : (
                    <Box flexDirection="column" height={descriptionLines}>
                        {description.map((line, i) => (
                            <Text key={line} color={theme.mt}>
                                {i === 0 && shade !== undefined ? (
                                    <>
                                        <Swatch colour={colourHex(shade)} />{" "}
                                    </>
                                ) : null}
                                {line}
                            </Text>
                        ))}
                    </Box>
                )}
            </Box>
        </Frame>
    )
}

// ========================================================================================
// 3. The settings menu
// ========================================================================================

/**
 * The four groups of settings, as a grid: output, model / sampler, plots. Exported so a
 * test can check the hotkeys.
 */
export const settingsMenuSpec = new MenuSpec(["output", "models", "sampler", "plots"], 2)

/**
 * The groups of settings of ONE model, as a grid: the sheets of [[modelSheets]] (the
 * `plots` sheet and the run-level groups of `output` have nothing a model can change).
 * Exported so a test can check it against the catalog.
 */
export const modelMenuSpec = new MenuSpec(["output", "models", "sampler"], 2)

/**
 * The id of the sheet each option opens. Every option is the id of its sheet except
 * the model settings, which share the art (and the `m` hotkey) of `models`.
 */
const sheetOf = {
    output:  "output",
    models:  "model",
    sampler: "sampler",
    plots:   "plots",
} as const

/**
 * The settings menu, for the global settings or those of one project. The global one
 * also opens the custom solutes and recipes with Ctrl-E.
 *
 * @param scope - whose settings.
 * @returns the screen.
 */
export function SettingsMenu({ scope }: { scope: Scope }): ReactNode {
    const nav = useNav()
    const chooseModel = useCallback(
        (name: (typeof modelMenuSpec.names)[number]) =>
            nav.push(<SettingsSheet scope={scope} sheetId={sheetOf[name]} />),
        [nav, scope],
    )

    // the names of the options are the ids of the sheets of the settings catalog
    const choose = useCallback(
        (name: (typeof settingsMenuSpec.names)[number]) =>
            nav.push(<SettingsSheet scope={scope} sheetId={sheetOf[name]} />),
        [nav, scope]
    )
    const global = scope.kind === "global"
    const onKey = useCallback(
        (press: KeyInput) => {
            if (global && press.is(keys.addNucleotide)) nav.push(<CustomLanding />)
        },
        [global, nav],
    )

    if (scope.kind === "model")
        return (
            <GridMenu
                spec={modelMenuSpec}
                header={<MenuHeader caption={`model: ${scope.model}`} />}
                onChoose={chooseModel}
            />
        )
    return (
        <GridMenu
            spec={settingsMenuSpec}
            header={<MenuHeader caption={scopeTitle(scope)} />}
            onChoose={choose}
            onKey={onKey}
            legend={global ? `custom solutes: ${keys.addNucleotide.label}` : undefined}
        />
    )
}

// ========================================================================================
// 4. Shared
// ========================================================================================

/** How many rows a file holds, or that it cannot be used. */
export type FileCount = number | "unusable"

/** The rows a file holds: their number, `"unusable"` if reading throws. */
export function count(read: () => readonly unknown[]): FileCount {
    try {
        return read().length
    } catch {
        return "unusable"
    }
}

/** What a landing says of a file under a plain label: `buffer: 3 solutes`, `none yet`. */
export function fileStatus(label: string, n: FileCount, word: string): string {
    if (n === "unusable") return `${label}: unusable!`
    return n === 0 ? `${label}: none yet` : `${label}: ${n} ${word}${n === 1 ? "" : "s"}`
}

/**
 * The reset of a file that cannot be used: `ask(file, reset)` asks, and on Enter runs
 * `reset` (the old file is kept as `<name>.corrupt`), then re-reads the counts.
 */
export function useResetFile(
    confirm: Confirm,
    setMessage: (text: string) => void,
    reread: () => void,
): (name: string, reset: () => void) => void {
    return (name, reset) =>
        confirm.ask(
            {
                text: `reset ${name}? the old one is kept as .corrupt`,
                yes: "reset",
                no: "keep",
            },
            () => {
                try {
                    reset()
                    reread()
                    setMessage(`${name} reset; old one kept as .corrupt`)
                } catch {
                    setMessage("could not reset!")
                }
            },
        )
}

/** For a file that cannot be used: where it is and what can be done. */
export const unusableHint = (file: string, columns: number): string =>
    `${truncateStart(file, Math.max(10, columns - 24))}  ${keys.reset.label}: reset`

// ========================================================================================
// 5. The custom landing
// ========================================================================================

/** The two options, in order: which file each one is about. */
const LIBRARY_OPTIONS = 2

/**
 * The landing of the user's library, opened by Ctrl-E in the global settings menu: the
 * two options `recipes (N)` and `solutes (N)` open the table of the saved recipes and the
 * table of the custom solutes, and a line says what each file holds (`recipes: none yet`,
 * `custom solutes: 12 solutes`). A file that cannot be used shows `?` and `unusable!`,
 * still opens (its table says so and edits nothing), and `r` on it offers to reset it to
 * empty, the old file kept beside it as `<name>.corrupt`.
 *
 * Keys: up and down move, Enter opens, Ctrl-X goes back.
 *
 * @returns the screen.
 */
function CustomLanding(): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    const cursor = useListCursor(LIBRARY_OPTIONS, LIBRARY_OPTIONS)
    const confirm = useConfirm()
    const [message, setMessage] = useState<string>()
    // the counts are read again whenever a table closes or a file is reset
    const [resets, setResets] = useState(0)
    const reset = useResetFile(confirm, setMessage, () => setResets((n) => n + 1))
    const root = appDir()
    const files = [recipesFile(root), customFile(root)] as const

    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const counts = useMemo(
        () => [
            count(() => readRecipes(root)),
            count(() => readCustomSolutes(root)),
        ],
        [root, nav.depth, resets],
    ) as [FileCount, FileCount]
    const [recipes, solutes] = counts
    const labels = customLandingOptions(recipes, solutes)

    const on = cursor.index
    const unusable = counts[on] === "unusable"
    const file = files[on] as string

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        setMessage(undefined)
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.enter))
            nav.push(on === 0 ? <RecipesTable /> : <CustomSolutesTable />)
        else if (unusable && press.is(keys.reset))
            reset(basename(file), () => quarantine(file))
    })

    // only the keys that work now: the arrows from the cursor's row, reset for a file that
    // cannot be used; a question shows its answers
    const listLegend = legendOf([
        legendBack,
        legendEnter,
        moveLegend({ up: on > 0, down: on < LIBRARY_OPTIONS - 1 }),
        unusable && legendFor("reset file", keys.reset),
    ])
    return (
        <Frame
            title="custom solutes and recipes"
            legend={confirm.question ? questionLegend(confirm.question) : listLegend}
            note={confirm.note ?? message}
        >
            <CursorList
                items={labels}
                index={on}
                offset={cursor.offset}
                lines={labels.length}
                row={(label, isOn) => <ListText on={isOn}>{label}</ListText>}
            />
            <Box flexDirection="column" marginTop={1}>
                <Text color={theme.mt}>{fileStatus("recipes", recipes, "recipe")}</Text>
                <Text color={theme.mt}>
                    {fileStatus("custom solutes", solutes, "solute")}
                </Text>
                {unusable ? (
                    <Text color={theme.er}>{unusableHint(file, columns)}</Text>
                ) : null}
            </Box>
        </Frame>
    )
}
