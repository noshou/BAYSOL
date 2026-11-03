;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The loop that the table screens (the solutes of a buffer, the custom solutes, the
;; recipes) run: draw the frame of the state, wait for a key, and handle the keys that mean
;; the same on every table (the terminal going away, Escape, Ctrl-X); the rest is a
;; function of each screen. A screen keeps its own state, frame and key handling.

(ns baysol.tui.screens.loop
 (:require [baysol.tui.draft :as draft]
  [baysol.tui.screens.state :as state])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(defn discard-title
 "The question asked before a table or sheet with `n` unsaved changes is left,
 `discard 3 changes?`."
 [n]
 (str "discard " n (if (= n 1) " change" " changes") "?"))

(def discard-keys
 "What answers the question of [[discard-title]]."
 "enter: discard  esc: keep")

(defn discard-note
 "The question and its keys as one text for the note of a table's border row (45 to 47
 characters)."
 [n]
 (str (discard-title n) "  " discard-keys))

(defn confirm-discard!
 "Asks whether the `n` unsaved changes are to be dropped: `draw!` is called with the text
 of the question ([[discard-note]]) to show it, then the answer is waited for. Returns
 true for Enter (leave), false for Escape or Ctrl-X (stay and go on editing) and `:quit`
 when the terminal goes away.

 # Returns
 true, false or `:quit`.

 # Exceptions
 None."
 [screen n draw!]
 (draw! (discard-note n))
 (let [answer (state/confirm! screen)]
  (if (= answer :back) false answer)))

(defn run-table!
 "Runs a table screen on `screen`, on the solid colour `background`, until a key leaves it;
 returns `:quit` or `:back`.

 `spec` is a map: `:init` the first state (a map with `:offset` and `:note`), `:frame` a
 function of the state that gives the page `{:lines :offset}` to draw, `:handle` a function
 of the state and a raw input that gives the next state, or `:quit` or `:back` to end,
 `:esc-quits?` (optional, a function of the state, true by default) that says whether
 Escape ends the screen, as it does with nothing open over the table, `:dirty` (optional, a
 function of the state that gives how many changes are not saved; by default the rows of
 its `:s` that `baysol.tui.draft/changes` counts) and `:close` (optional, a function of the
 state that drops what is open over the table, `identity` by default).

 Each key first sets the state's `:offset` to the frame's and clears its `:note`. The
 terminal going away, then Escape (when `:esc-quits?` says so), end the screen with
 `:quit`, and Ctrl-X with `:back`, whatever is open: only then is `:handle` asked. Escape
 and Ctrl-X with changes not saved first ask `discard N changes?` in the note (the frame
 is drawn again with it): Enter leaves, Escape (or Ctrl-X) stays, with what was open closed
 by `:close`; a screen with nothing unsaved is left at once."
 [^TerminalScreen screen
  ^TextColor background
  {:keys [init frame handle esc-quits? dirty close],
   :or {esc-quits? (constantly true),
    dirty #(draft/changes (:s %)),
    close identity}}]
 (loop [st init]
  (let [{:keys [lines offset]} (frame st)
    _ (state/draw-lines! screen background lines)
    input (state/read-raw screen)
    st (assoc st :offset offset :note nil)
    leave (cond (= input KeyType/EOF) :quit
     (and (esc-quits? st) (= input KeyType/Escape)) :quit
     (state/back-key? input) :back)
    closed (close st)
    n (if (and leave (not= input KeyType/EOF)) (dirty closed) 0)]
   (cond
    (nil? leave) (let [next-st (handle st input)]
     (if (map? next-st) (recur next-st) next-st))
    (zero? n) leave
    :else (let [answer (confirm-discard! screen
       n
       #(state/draw-lines!
        screen
        background
        (:lines (frame
          (assoc closed :note %)))))]
     (if (false? answer) (recur closed) (if (true? answer) leave answer)))))))
