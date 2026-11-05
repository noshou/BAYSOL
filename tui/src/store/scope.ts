// SPDX-License-Identifier: LGPL-3.0-or-later

import { appDir } from "../core/paths.js"
import { type LoadResult, loadGlobal, loadProject } from "./settings-store.js"

/**
 * A project the user is working in.
 *
 * @property id - the project's name (also its folder's name).
 * @property dir - the project's folder.
 */
export type ProjectRef = { id: string; dir: string }

/**
 * Whose settings a screen shows: the global ones that every new project starts from,
 * or those of one project. The same sheets serve both; only where the file is and
 * what "reset" returns to differ.
 */
export type Scope = { kind: "global" } | { kind: "project"; project: ProjectRef }

/** The global scope. */
export const globalScope: Scope = { kind: "global" }

/**
 * The scope of a project.
 *
 * @param project - the project.
 * @returns its scope.
 */
export function projectScope(project: ProjectRef): Scope {
    return { kind: "project", project }
}

/**
 * The words that name a scope on a screen's title.
 *
 * @param scope - the scope.
 * @returns `"global settings"` or `"project settings"`.
 */
export function scopeTitle(scope: Scope): string {
    return scope.kind === "global" ? "global settings" : "project settings"
}

/**
 * Loads (and checks, and if need be repairs) the settings of a scope.
 *
 * @param scope - whose settings.
 * @returns the settings and what was wiped on the way, see [[LoadResult]].
 * @throws if the bundled data is corrupt or a file cannot be written.
 */
export function loadScope(scope: Scope): LoadResult {
    return scope.kind === "global"
        ? loadGlobal(appDir())
        : loadProject(scope.project.dir, appDir())
}
