// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

/**
 * The fixtures the Julia side and this program are both tested against: the files of
 * `test/fixtures/` at the root of the repository (JSON, each with a `_comment` that
 * says what it holds).
 */

/**
 * The text of a shared fixture file.
 *
 * @param path - the path below `test/fixtures/` of the repository, `buffer/buffer.json`.
 * @returns the file's text.
 * @throws if there is no such file.
 */
export function fixtureText(path: string): string {
    return readFileSync(
        fileURLToPath(new URL(`../../../test/fixtures/${path}`, import.meta.url)),
        "utf-8",
    )
}

/**
 * The object of a shared fixture file, without its `_comment`.
 *
 * @param path - as for [[fixtureText]].
 * @returns the object; its keys are those of the file.
 * @throws if there is no such file or it is not a JSON object.
 */
export function fixture(path: string): Record<string, unknown> {
    const { _comment, ...rest } = JSON.parse(fixtureText(path)) as Record<string, unknown>
    return rest
}
