// SPDX-License-Identifier: LGPL-3.0-or-later

// The reference curve of one model (`^f` on the models list): the curve of a depositor's
// fit that goes with this model, its label and the depositor's χ². A run draws the curve
// with the data and the model's MAP curve on the model's own figure and writes the χ² in
// the model's LOG. Every change is saved at once into `model-references.json`.

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { saveErrorNote } from "../core/file-system.js"
import { truncate } from "../core/terminal.js"
import {
    EMPTY_MODEL_REFERENCE,
    MAX_REFERENCE_TEXT,
    type ModelReference,
    modelReference,
    saveModelReference,
} from "../store/model-references.js"
import type { ProjectRef } from "../store/projects.js"
import { listReferences } from "../store/references.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendBack, legendFor, legendOf, moveLegend } from "../ui/grid.js"
import { Prompt } from "../ui/input.js"
import {
    CursorList,
    type KeyInput,
    keys,
    ListText,
    useKeys,
    useListCursor,
    useNav,
} from "../ui/interaction.js"
import { Panel, useTheme } from "../ui/theme.js"

/** A row of the screen: the model's file (read only) and what can be set. */
type Field = "pdb" | "fit" | "software" | "tag" | "refChi2" | "rescale"

/** The rows, in order. */
const fields: readonly Field[] = ["pdb", "fit", "software", "tag", "refChi2", "rescale"]

/** What each row is called (the width of the label column is [[LABEL_WIDTH]]). */
const fieldLabel: Record<Field, string> = {
    pdb: "model",
    fit: "curve",
    software: "software",
    tag: "tag",
    refChi2: "chi2",
    rescale: "rescale",
}

/** The width of the label column. */
const LABEL_WIDTH = 10

/** What the curve row says for no curve. */
const NO_CURVE = "none"

/** What a text row shows while it is unset. */
const UNSET = "-"

/** How each text row is asked for. */
const promptLabel: Partial<Record<Field, string>> = {
    software: "software:",
    tag: "tag:",
    refChi2: "chi2:",
}

/** A hint of what goes into a text row. */
const placeholder: Partial<Record<Field, string>> = {
    software: "the program, e.g. MultiFoXS 2-state",
    tag: "the label, e.g. fit3_model1",
    refChi2: "the depositor's, e.g. MultiFoXS 0.79",
}

/**
 * The reference curve of one model: the model's file, the curve of `reference-fit/` that
 * goes with it (left and right, or Enter, go through the project's curves and `none`),
 * the program's name, a tag, the depositor's χ² (Enter opens a prompt) and whether the
 * curve is scaled onto the data (Enter toggles).
 *
 * @param props.project - the project.
 * @param props.file - the model's file name (`SASDCQ2_fit3_model1.pdb`).
 * @param props.stem - the model's name in the files (`SASDCQ2_fit3_model1`).
 * @returns the screen.
 */
export function ModelReferenceScreen(props: {
    project: ProjectRef
    file: string
    stem: string
}): ReactNode {
    const { project, file, stem } = props
    const nav = useNav()
    const theme = useTheme()
    const [ref, setRef] = useState<ModelReference>(() => modelReference(project.dir, stem))
    const [edit, setEdit] = useState<Field | undefined>()
    const [note, setNote] = useState<{ text: string; error: boolean } | undefined>()
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    const cursor = useListCursor(fields.length, fields.length)
    const field = fields[cursor.index] as Field

    // the curves a model can be given: the project's usable ones, read when this opens
    const curves = useMemo(
        () => listReferences(project.dir).filter((c) => c.unusable === undefined),
        [project.dir],
    )
    const choices = useMemo(() => ["", ...curves.map((c) => c.file)], [curves])

    /** Saves a changed entry at once; a failed save leaves the screen as it was. */
    const change = useCallback(
        (next: ModelReference) => {
            try {
                saveModelReference(project.dir, stem, next)
                setRef(next)
            } catch (error) {
                setNote({ text: saveErrorNote(error), error: true })
            }
        },
        [project.dir, stem],
    )

    const stepCurve = (by: number) => {
        const at = Math.max(0, choices.indexOf(ref.fit))
        const next = choices[(at + by + choices.length) % choices.length] as string
        change({ ...ref, fit: next })
    }

    useKeys((press: KeyInput) => {
        setNote(undefined)
        if (press.is(keys.up) || press.is(keys.shiftTab)) cursor.move(-1)
        else if (press.is(keys.down) || press.is(keys.tab)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (field === "fit" && press.is(keys.left)) stepCurve(-1)
        else if (field === "fit" && press.is(keys.right)) stepCurve(1)
        else if (press.is(keys.enter)) {
            if (field === "fit") stepCurve(1)
            else if (field === "rescale") change({ ...ref, rescale: !ref.rescale })
            else if (field !== "pdb") setEdit(field)
        }
    }, edit === undefined)

    const submit = (text: string) => {
        if (edit === undefined || edit === "pdb" || edit === "rescale") return
        change({ ...ref, [edit]: text.trim() })
        setEdit(undefined)
    }

    const valueText = (f: Field): string => {
        if (f === "pdb") return file
        if (f === "fit") {
            if (ref.fit === "") return NO_CURVE
            return choices.includes(ref.fit) ? ref.fit : `${ref.fit} (missing)`
        }
        if (f === "rescale") return ref.rescale ? "on" : "off"
        return ref[f] === "" ? UNSET : ref[f]
    }

    /** The key of the highlighted row: the file is read only, the curve steps. */
    const rowKey = (): LegendItem | false => {
        if (field === "pdb") return false
        if (field === "fit") return legendFor("change", keys.enter, [keys.left, keys.right])
        return legendFor(field === "rescale" ? "toggle" : "edit", keys.enter)
    }
    const moves = moveLegend({
        up: cursor.index > 0,
        down: cursor.index < fields.length - 1,
        tab: true,
    })
    const legend: LegendItem[] =
        edit === undefined ? legendOf([rowKey(), moves, legendBack]) : promptKeys
    const empty = EMPTY_MODEL_REFERENCE

    return (
        <Frame
            title="reference fit"
            subtitle={`${project.id} · ${truncate(stem, 34)}`}
            legend={legend}
            note={
                note?.text ??
                (curves.length === 0 ? "no reference fits: add one in data" : undefined)
            }
            noteIsError={note?.error}
        >
            <Panel paddingX={1} flexDirection="column">
                <CursorList
                    items={[...fields]}
                    index={cursor.index}
                    offset={cursor.offset}
                    lines={fields.length}
                    active={edit === undefined}
                    row={(f, on) => (
                        <Box>
                            <ListText on={on}>{fieldLabel[f].padEnd(LABEL_WIDTH)}</ListText>
                            <Text
                                color={
                                    on || (f !== "pdb" && ref[f] !== empty[f])
                                        ? theme.fg
                                        : theme.mt
                                }
                                wrap="truncate-end"
                            >
                                {valueText(f)}
                            </Text>
                        </Box>
                    )}
                />
            </Panel>
            {edit !== undefined && promptLabel[edit] !== undefined ? (
                <Prompt
                    label={promptLabel[edit] as string}
                    initial={ref[edit as "software" | "tag" | "refChi2"]}
                    maxLength={MAX_REFERENCE_TEXT}
                    placeholder={placeholder[edit]}
                    onSubmit={submit}
                    onCancel={() => setEdit(undefined)}
                    onChange={() => setNote(undefined)}
                    take="set"
                    cancel="close"
                    onLegend={setPromptKeys}
                />
            ) : null}
        </Frame>
    )
}
