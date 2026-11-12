// SPDX-License-Identifier: LGPL-3.0-or-later

// A small real workbook for the tests that pack a run (a run's `.xlsx` goes into the
// archive as its XML tree, so it must be a zip), and the way to read one back.

import * as XLSX from "xlsx"

/** A workbook of two sheets with numbers, text and a formula. */
export function tinyWorkbook(): Buffer {
    const book = XLSX.utils.book_new()
    const fit = XLSX.utils.aoa_to_sheet([
        ["q", "I", "sigma"],
        [0.01, 12.5, 0.2],
        [0.02, 11.9, 0.2],
        [0.03, 10.4, 0.3],
    ])
    fit.D2 = { t: "n", f: "B2*2", v: 25 }
    XLSX.utils.book_append_sheet(book, fit, "fit")
    const run = XLSX.utils.aoa_to_sheet([
        ["name", "value"],
        ["chi2", 1.07],
        ["note", "café χ²"],
    ])
    XLSX.utils.book_append_sheet(book, run, "run")
    return XLSX.write(book, { type: "buffer", bookType: "xlsx" }) as Buffer
}

/** What a workbook holds: the rows of every sheet by sheet name (values and formulas). */
export function sheetsOf(bytes: Buffer): Record<string, unknown[][]> {
    const book = XLSX.read(bytes, { type: "buffer", cellFormula: true })
    const out: Record<string, unknown[][]> = {}
    for (const name of book.SheetNames) {
        const sheet = book.Sheets[name]
        if (sheet === undefined) continue
        out[name] = XLSX.utils.sheet_to_json(sheet, { header: 1, raw: true })
    }
    return out
}
