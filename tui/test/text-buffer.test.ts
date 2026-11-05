// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { TextBuffer } from "../src/ui/text-buffer.js"

test("typing inserts at the cursor and moves it", () => {
    const b = new TextBuffer("ac").left().insert("b")
    assert.equal(b.text, "abc")
    assert.equal(b.cursor, 2)
})

test("backspace and delete remove whole characters", () => {
    assert.equal(new TextBuffer("a👍").backspace().text, "a")
    assert.equal(new TextBuffer("ab", 0).delete().text, "b")
    assert.equal(new TextBuffer("", 0).backspace().text, "")
})

test("the length limit cuts what is typed and says it is full", () => {
    const b = new TextBuffer("", undefined, 3).insert("abcdef")
    assert.equal(b.text, "abc")
    assert.ok(b.full)
})

test("a paste loses its newlines", () => {
    assert.equal(new TextBuffer().insert("a\nb\r\n").text, "ab")
})
