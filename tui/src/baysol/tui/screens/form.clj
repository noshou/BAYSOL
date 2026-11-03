;; SPDX-License-Identifier: LGPL-3.0-or-later

;; A form page drawn from its art (resources/custom-nonbio/pages/page.txt, custom-polymer):
;; a box of 24 lines whose labels and meaning texts are IN THE ART, and of which only the
;; value cells, the note on the bottom border and the preview lines are written here.
;; Nothing about the geometry is typed into the code; it is read from the glyphs of the
;; art, so the owner may restyle the page and the forms follow. Both glyph families are
;; read, the double-line one of the live pages (`╔═ title ═╗ ║ ╠ ╬ ╣ ╚ ╝`) and the
;; single-line rounded one (`╭─ title ─╮ │ ├ ┼ ┤ ╰ ╯`):
;;
;;   - the title is the text in the top border (`╔═ title ══╗` or `╭─ title ──╮`);
;;   - a line that starts (after its margin) with `╠` or `├` is a rule, `╚` or `╰` is the
;;     bottom of the box, and what follows the bottom is the footer, static art;
;;   - the lines between two rules (or the top and a rule) are a BLOCK; the cells of a
;;     line are the spans between its `║` (or `│`);
;;   - the last block is the preview: its first line is the heading (`BAYSOL will use`),
;;     the others are the lines the preview is written on;
;;   - the margin is the blank columns left of the box; the cursor `>` goes there.
;;
;; A cell is named `[line span]`: the index of its line in the art and of its span. The
;; screens decide which cells are their fields (`blocks`, `labelled`, `spans` help them
;; read the structure) and give `frame` the text of each.
;;
;; `frame` is a pure function of the art and the text, `show-form!` the loop that draws it
;; and hands the keys to a step function.

(ns baysol.tui.screens.form
 (:require [baysol.tui.text :as txt]
  [baysol.tui.screens.state :as state]
  [baysol.tui.screens.table :as table]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def max-typed
 "The most characters typed into a cell."
 60)

;; --- the art

(defn ^:private starts-with-glyph?
 "Whether `line`, after its margin, starts with a character of the string `glyphs`."
 [line glyphs]
 (let [t (str/triml line)]
  (and (seq t) (str/includes? glyphs (subs t 0 1)))))

(defn ^:private row-of
 "`{:spans [[from to] ...] :texts [text ...]}` of the body line `line`: the spans between
 its `║` or `│` (`from` the first column of the cell, `to` the column of the next one), and
 the text of each, trimmed."
 [^String line]
 (let [bs (table/column-indices line)
   spans (mapv vector (map inc bs) (rest bs))]
  {:spans spans,
   :texts (mapv (fn [[from to]] (str/trim (subs line from to))) spans)}))

(defn parse-art
 "The art of a form page from its lines `lines`: a map with `:lines` (trailing blanks cut
 off the lines and the file), `:title` (the text of the top border, or nil), `:margin` (the
 column of the box's left edge), `:rows` (`{line {:spans :texts}}` for each body line of
 the box, a line that is not a rule), `:blocks` (vectors of body line indices between
 rules), `:preview` (`{:heading line :rows [lines] :from :to}` of the last block, `:from`
 and `:to` the columns of its text), `:bottom` (`{:line i :from :to}`, the columns inside
 the corners) and `:footer` (the lines after the bottom of the box). Throws an exception
 (an `ex-info`) when the art has no bottom `╚` or `╰` or no block.

 # Returns
 The map above.

 # Exceptions
 `ex-info` for art that has no box bottom or no block."
 [lines]
 (let [lines (->> lines
    (mapv str/trimr)
    (reverse)
    (drop-while str/blank?)
    (reverse)
    (vec))
   bottom (first (keep-indexed #(when (starts-with-glyph? %2 "╚╰") %1) lines))
   _ (when-not bottom (throw (ex-info "form art has no box bottom" {})))
   body (range 1 bottom)
   blocks (->> body
    (partition-by #(table/rule? (lines %)))
    (remove #(table/rule? (lines (first %))))
    (mapv vec))
   _ (when (empty? blocks) (throw (ex-info "form art has no block" {})))
   rows (into {}
    (for [i body
      :when (not (table/rule? (lines i)))]
     [i (row-of (lines i))]))
   heading (first (last blocks))
   [from to] (get-in rows [heading :spans 0])
   top (first lines)
   bottom-line (lines bottom)
   corner (first (keep-indexed #(when (#{\╚ \╰} %2) %1) bottom-line))]
  {:lines lines,
   :title (second (re-find #"[╭╔][─═]+\s*(.*?)\s*[─═]+[╮╗]" top)),
   :margin (first (keep-indexed #(when (#{\╭ \╔} %2) %1) top)),
   :rows rows,
   :blocks blocks,
   :preview
   {:heading heading, :rows (vec (rest (last blocks))), :from from, :to to},
   :bottom {:line bottom,
    :from (inc corner),
    :to (or (first (keep-indexed #(when (#{\╯ \╝} %2) %1) bottom-line))
     (count bottom-line))},
   :footer (subvec lines (inc bottom))}))

(defn spans
 "The spans `[from to]` of the cells of the body line `line` of `art`."
 [art line]
 (get-in art [:rows line :spans]))

(defn texts
 "The (trimmed) text of each cell of the body line `line` of `art`."
 [art line]
 (get-in art [:rows line :texts]))

(defn labelled
 "The body lines of `block` (a vector of line indices) whose first cell has a text: the
 lines that start a field."
 [art block]
 (filterv #(not (str/blank? (first (texts art %)))) block))

(defn cell-width
 "The width in columns of the cell `[line span]` of `art`."
 [art [line span]]
 (let [[from to] (get (spans art line) span)] (- to from)))

;; --- text in the cells

(defn edit-text
 "What a cell `cell` of `art` shows of the text `text` being typed: the end of it, with a
 `…` in front when it is longer than the cell holds, and the cursor `_` after it."
 [art cell text]
 (str (table/tail-text text (- (cell-width art cell) 3)) "_"))

(defn type-step
 "The text `text` after the raw input `input` has been typed into it: a character is
 added (up to `max-typed`), Backspace removes the last one; anything else leaves it."
 [text input]
 (txt/typed text input max-typed))

(defn type-edit
 "The form state `st` (`{:edit {:text ...} :note ...}`) after the raw input `input` was
 typed into its open cell: `type-step`, and when `max-typed` characters are there already
 a refused character leaves the note `text too long (60 at most)`."
 [st input]
 (if (txt/at-cap? input (get-in st [:edit :text]) max-typed)
  (assoc st :note (txt/too-long "text" max-typed))
  (update-in st [:edit :text] type-step input)))

;; --- the lines

(defn ^:private replace-span
 "`line` with the cell between the columns `from` and `to` written as `text` (`mark` in
 the place of its leading space)."
 [^String line from to text mark]
 (txt/splice-width line from to (table/fit-cell text (- to from) :left mark)))

(defn ^:private ellipsize
 "`line` with a `…` at its end, cut so that the whole is at most `width` characters."
 [line width]
 (str (if (>= (txt/display-width line) width)
   (txt/take-width line (max 0 (dec width)))
   line)
  "…"))

(defn preview-lines
 "The preview `paragraphs` (strings; blank ones are left out) as the lines they take on a
 preview `width` characters wide, at most `room` lines: a paragraph that fits is kept as it
 is, a longer one wrapped at its spaces (`table/wrap-text`). When there are more lines than
 `room`, the last one kept ends with a `…`.

 # Returns
 A vector of strings, none longer than `width`, at most `room` of them.

 # Exceptions
 None."
 [paragraphs width room]
 (let [lines (vec (mapcat (fn [p]
      (if (<= (txt/display-width p) width)
       [p]
       (table/wrap-text p width)))
     (remove str/blank? paragraphs)))]
  (cond (<= room 0) []
   (> (count lines) room) (conj (subvec lines 0 (dec room))
    (ellipsize (nth lines (dec room)) width))
   :else lines)))

(defn frame
 "The page of a form: a vector of the lines of the art with the dynamic parts written.
 `data` has `:cells` (`{[line span] text}`: each is written into its cell, cut with a `…`
 at the end when it is longer; a cell not in the map keeps what the art has), `:cursor`
 (the cell under the cursor: its line gets the `>` in the margin, and with `:mark-cell?`
 the cell gets a `>` in front of its text as well, for a table of cells), `:note` (text
 for the bottom border of the box, cut with a `…` to fit) and `:preview` (paragraphs for
 the lines of the preview, see `preview-lines`).

 # Returns
 The lines, as many as the art has. With no data they are the art's.

 # Exceptions
 None."
 [art {:keys [cells cursor note preview mark-cell?]}]
 (let [cells (cond-> (or cells {})
    (and mark-cell? cursor) (update cursor #(or % "")))
   lines (reduce (fn [lines [[line span] text]]
     (let [[from to] (get (spans art line) span)]
      (assoc lines
       line
       (replace-span
        (lines line)
        from
        to
        text
        (when (and mark-cell? (= cursor [line span])) \>)))))
    (:lines art)
    cells)
   lines (if cursor
    (let [line (first cursor)
      margin (:margin art)
      at (max 0 (min 1 (dec margin)))]
     (update lines
      line
      (fn [^String s]
       (str (subs s 0 at) ">" (subs s (inc at))))))
    lines)
   {:keys [rows from to]} (:preview art)
   width (- to from 2)
   shown (preview-lines preview width (count rows))
   lines (reduce
    (fn [lines [line text]]
     (assoc lines line (replace-span (lines line) from to text nil)))
    lines
    (map vector rows shown))
   {bline :line, bfrom :from, bto :to} (:bottom art)
   room (- bto bfrom 4)]
  (if (and note (not (str/blank? note)) (pos? room))
   (update
    lines
    bline
    (fn [^String s]
     (let [cut (if (> (txt/display-width note) room) (ellipsize note room) note)
       text (str " " cut " ")]
      (txt/splice-width s (+ bfrom 1) (+ bfrom 1 (txt/display-width text)) text))))
   lines)))

;; --- the loop

(defn show-form!
 "Shows a form on `screen` (solid colour `background`) until it is done. `st` is the
 state, `frame-fn` makes the `data` of `frame` from it and `step-fn` the next state from
 a state and a raw input (a character, `:ctrl-w`, an arrow ... see `state/key->raw`); a
 step sets `:done` to `:accepted` (the result is the state's `:entry`) or `:cancelled`
 (the result is nil). The state's `:note` is cleared before every key. Returns the entry,
 nil, `:back` when Ctrl-X was pressed (in any mode: a cell being edited is dropped with the
 form, as Escape drops it) or `:quit` when the terminal went away (`KeyType/EOF`)."
 [^TerminalScreen screen ^TextColor background art st frame-fn step-fn]
 (loop [st st]
  (state/draw-lines! screen background (frame art (frame-fn st)))
  (let [input (state/read-raw screen)]
   (cond
    (= input KeyType/EOF) :quit
    (state/back-key? input) :back
    :else
    (let [st (step-fn (assoc st :note nil) input)]
     (case (:done st)
      :accepted (:entry st)
      :cancelled nil
      (recur st)))))))
