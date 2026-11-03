;; SPDX-License-Identifier: LGPL-3.0-or-later

;; A table drawn from its art, for a list that can be longer than the page (the solutes).
;; The art file (resources/<screen>/pages/page.txt) has the lines that never change: the
;; header block (an optional top border, the header line, the separator rule), ONE blank
;; body row (the template), the bottom border and the footer (3 to 5 lines). Everything
;; else is generated from it, so the art stays the one source of where the columns are.
;; Two glyph families are read, the double-line one of the live tables (`║ ╠ ╬ ╣ ╚ ╩ ╦ ╝`)
;; and the single-line rounded one (`│ ├ ┼ ┤ ╰ ┴ ┬ ╯`):
;;
;;   - the header block is every line up to and including the first separator rule (a
;;     line that starts, after the margin, with `├` or `╠`); the header line is the one
;;     right before the rule, and the columns are the spans between its `│` (or `║`);
;;   - a row is the template with the cells written between the column glyphs, in the
;;     cursor's `>` margin and a one-character mark (`*` unsaved, `-` to be removed) in the
;;     leading space of the first column;
;;   - the body is as tall as the page leaves room for (the page's rows less the header
;;     block, the bottom border and the footer), blank rows filling up what the rows do
;;     not: the footer stays at the bottom of the page and the table is the same size
;;     whatever it holds (16 rows for the buffer art with a 5-line footer, 18 for the
;;     custom solutes and recipes with a 3-line footer). More rows than that scroll one
;;     row at a time (`viewport`);
;;   - the `[   /   ]` of any art line (the footer's box, a top border) is filled with the
;;     place of the cursor and the number of rows; the arrows of `move:` are written in
;;     the two cells that start 6 characters after the `move:` text of the footer (or, for
;;     an art with no room there, in the two cells above the `^u` of the footer's second
;;     line): `↓` if
;;     there is a row below the cursor and `↑` if there is one above, none for a table of
;;     one row or none;
;;   - a legend of the footer (`label: key`, any number on a line) is written over with
;;     spaces when its key has nothing to do.
;;
;; Everything here is a pure function of the art and the rows, so no terminal is needed.

(ns baysol.tui.screens.table
 (:require [baysol.tui.text :as txt]
  [baysol.tui.draft :as draft]
  [baysol.tui.limits :refer [max-rows]]
  [baysol.tui.screens.state :as state]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna.input KeyType)))

;; --- text in cells, by display width (a wide character takes two cells)

(defn fit-cell
 "The text of a cell exactly `width` cells wide. `align` is `:left` (one leading space, or
 `mark` in its place), `:right` (one trailing space) or `:center`. Text that does not fit
 loses its end and gets a `…`; a wide character is never split, its cell is padded with a
 space instead. Right and centred text may use the spaces at the edges too (up to the
 whole width) before it is cut; left text keeps its space, where the mark goes."
 ([text width align] (fit-cell text width align nil))
 ([text width align mark]
  (let [s (str text)
    room (if (= align :left) (- width 2) width)
    s (if (> (txt/display-width s) room)
     (str (txt/take-width s (dec room)) "…")
     s)
    pad (- width (txt/display-width s))]
   (case align
    :right
    (if (>= pad 2) (str (txt/spaces (dec pad)) s " ") (str (txt/spaces pad) s))
    :center (let [left (quot pad 2)]
     (str (txt/spaces left) s (txt/spaces (- pad left))))
    (str (or mark \space) s (txt/spaces (dec pad)))))))

(defn tail-text
 "The end of `s` that fits `room` cells, with a `…` in front when it is cut: what a cell
 shows of text typed into it."
 [s room]
 (let [s (str s)]
  (if (> (txt/display-width s) room)
   (str "…" (txt/take-last-width s (dec room)))
   s)))

(defn ^:private width-chunks
 "`s` cut into pieces of at most `n` cells, the last one shorter (a character wider than
 `n` goes alone)."
 [^String s n]
 (loop [left s
   out []]
  (if (empty? left)
   out
   (let [piece (txt/take-width left (max 1 n))
     piece (if (empty? piece)
      (subs left 0 (Character/charCount (.codePointAt left 0)))
      piece)]
    (recur (subs left (count piece)) (conj out piece))))))

(defn wrap-text
 "`text` broken into lines of at most `width` cells, at the spaces: a vector of strings,
 never empty (`[\"\"]` for blank text). Runs of white space count as one space and the ends
 are trimmed. A word longer than `width` is broken hard, into pieces of `width` cells, the
 last piece going on with the next word; a `width` below 1 is taken as 1. A `…` is never
 needed. For the form pages (long names, labels and notes), not used by the tables
 themselves.

 # Returns
 A vector of one or more strings.

 # Exceptions
 None."
 [text width]
 (let [width (max 1 width)
   words (remove str/blank? (str/split (str text) #"\s+"))
   put (fn [[done line] word]
    (cond (and (seq line)
      (<= (+ (txt/display-width line) 1 (txt/display-width word))
       width))
     [done (str line " " word)]
     (<= (txt/display-width word) width)
     [(cond-> done (seq line) (conj line)) word]
     :else (let [chunks (width-chunks word width)]
      [(into (cond-> done (seq line) (conj line)) (pop chunks))
       (peek chunks)])))
   [done line] (reduce put [[] ""] words)]
  (if (seq line) (conj done line) (if (seq done) done [""]))))

;; --- the art

(def ^:private column-glyphs
 "The characters that separate the columns of a header line, in either family."
 #{\│ \║})

(defn column-indices
 "The indices of the column glyphs in the art line `s` (the header line, or a body line of
 a form page's art)."
 [^String s]
 (vec (keep-indexed #(when (column-glyphs %2) %1) s)))

(defn rule?
 "Whether `line` is the separator rule: its first character after the margin is `├`
 or `╠`."
 [line]
 (boolean (re-find #"^\s*[├╠]" line)))

(defn parse-art
 "The art of a table from its lines `lines`: the header block (up to and including the
 first separator rule), the body template, the bottom border, then the footer lines.
 Returns the map `frame` takes: `:head` (the header block's lines, trailing blanks
 removed), `:header` (its last line before the rule), `:separator`, `:template`,
 `:bottom`, `:footer`, `:glyph` (the column glyph), `:bounds` (the columns of the glyph in
 the header), `:spans` (`[from to]` of each column's cells), `:counter` (`{:line :cur
 :tot}`, the art line and the places of the two numbers of the first `[   /   ]`, or nil)
 and `:arrows` (`{:line :at}`, the footer line and the first of the two cells of the
 arrows, or nil). Throws an exception for lines with no separator rule after a header
 line."
 [lines]
 (let [lines (mapv str/trimr lines)
   rule (first (keep-indexed #(when (rule? %2) %1) lines))
   _ (when-not (and rule (pos? rule))
    (throw (ex-info "no separator rule in the art of a table" {})))
   head (subvec lines 0 (inc rule))
   header (nth lines (dec rule))
   [template bottom & footer] (subvec lines (inc rule))
   bounds (column-indices header)
   footer-at (+ rule 3)
   counter (some (fn [[i line]]
     (let [m (re-matcher #"\[( {3})/( {3})\]" line)]
      (when (.find m)
       {:line i, :cur (.start m 1), :tot (.start m 2)})))
    (map-indexed vector lines))
   moves (some
    (fn [i]
     (let [line (nth lines i)
       k (str/index-of line "move:")]
      ;; the two cells after `move: ` may be blank in the art or past the end of
      ;; its line (the art lines are kept without trailing spaces)
      (when (and k (= "  " (subs (str line "        ") (+ k 6) (+ k 8))))
       {:line i, :at (+ k 6)})))
    (range footer-at (count lines)))
   arrows (or moves
    (when-let [u (some-> (get lines (inc footer-at))
       (str/index-of "^u"))]
     {:line footer-at, :at u}))]
  {:head head,
   :header header,
   :separator (peek head),
   :template template,
   :bottom bottom,
   :footer (vec footer),
   :glyph (str (nth header (first bounds))),
   :bounds bounds,
   :spans (mapv vector (map inc bounds) (rest bounds)),
   :counter counter,
   :arrows arrows}))

(defn window
 "How many body rows the art leaves on a page of `state/page-rows` rows: the page less
 the header block, the bottom border and the footer."
 [art]
 (- state/page-rows (count (:head art)) 1 (count (:footer art))))

(defn body-top
 "The page line (0-based) where the body of the table starts: the header block's length."
 [art]
 (count (:head art)))

(defn viewport
 "The first row shown, when the cursor is on row `cursor` of `n` rows, `offset` was the
 first row shown and `size` rows show: the table moves by one row, only when the cursor
 would leave it, and never past the last row."
 [offset cursor n size]
 (let [offset (cond (< cursor offset) cursor
    (>= cursor (+ offset size)) (inc (- cursor size))
    :else offset)]
  (max 0 (min offset (max 0 (- n size))))))

;; --- the lines

(defn ^:private put-at
 "`line` with `text` written over its characters from index `from`, the line padded with
 spaces if it is shorter."
 [^String line from ^String text]
 (txt/splice-width line from (+ from (txt/display-width text)) text))

(defn ^:private body-line
 "The line of one row: the template with `cells` (one string per column, already fitted)
 between the art's column glyphs, the cursor `>` in the margin if `cursor?`."
 [art cells cursor?]
 (let [margin (first (:bounds art))
   glyph (:glyph art)
   lead (if cursor? (str " > " (txt/spaces (- margin 3))) (txt/spaces margin))]
  (str lead glyph (str/join glyph cells) glyph)))

(defn ^:private row-cells
 "The cells of `row`, `{:cells [text ...] :aligns [...] :mark ch}`, fitted to the columns
 of the art. A column's alignment is `:left` unless `:aligns` says otherwise."
 [art {:keys [cells aligns mark]}]
 (vec (map-indexed (fn [i [from to]]
    (fit-cell (nth cells i "")
     (- to from)
     (get aligns i :left)
     (when (zero? i) mark)))
   (:spans art))))

(defn ^:private without-legend
 "`line` with the legend of a key (its label `label`, as `add`, and the key after it)
 written over with spaces, the line as long as before. Other legends of the line, and
 the box's border, are left alone."
 [line label]
 (str/replace line
  (re-pattern (str (java.util.regex.Pattern/quote label)
    ": +[^\\s│║]+"))
  #(txt/spaces (count %))))

(defn ^:private page-index
 "The page line of the line `i` of the art: the header block keeps its place, the footer
 is at the bottom of the page."
 [art i]
 (let [top (body-top art)]
  (if (< i top) i (+ (- state/page-rows (count (:footer art))) (- i top 2)))))

(defn ^:private footer-lines
 "The footer of the art with the legends of the keys that have nothing to do written over.
 A key loses its legend: every `add` (`add`, `add nonbio`, `add polymer`, `add protein`,
 `add nucleotide`, `new recipe`: an art has the ones it needs) when the table is full,
 `rmv` when it has no row, and any other label of `hidden` (the screen's own, from the
 art's legends)."
 [art n hidden]
 (let [gone (cond-> (vec hidden)
    (>= n max-rows) (conj "add"
     "add nonbio"
     "add polymer"
     "add protein"
     "add nucleotide"
     "new recipe")
    (zero? n) (conj "rmv"))]
  (mapv #(reduce without-legend % gone) (:footer art))))

(defn ^:private with-counter-and-arrows
 "The page `lines` with the counter filled in (the place of the cursor and the number of
 rows) and the arrows of the move cell written, where the art has them."
 [art lines cursor n]
 (let [{:keys [line cur tot]} (:counter art)
   {arrow-line :line, at :at} (:arrows art)
   shown (if (zero? n) 0 (inc cursor))
   total (min n max-rows)
   pad (fn [x] (txt/spaces (- 3 (count (str x)))))
   lines (if line
    (update lines
     (page-index art line)
     #(-> %
      (put-at cur (str (pad shown) shown))
      (put-at tot (str total (pad total)))))
    lines)]
  (if (and arrow-line (> n 1))
   (update lines
    (page-index art arrow-line)
    put-at
    at
    (str (if (< cursor (dec n)) "↓" " ") (if (pos? cursor) "↑" " ")))
   lines)))

(defn ^:private rule-runs
 "The stretches of plain rule (`═` or `─`) of the line `bottom` that end before index
 `limit`, as `[from to]` (the junctions `╩ ╦ ╣ ╠`, the corners and anything else break a
 stretch)."
 [^String bottom limit]
 (let [plain? #(contains? #{\═ \─} (.charAt bottom %))]
  (loop [i 0
    run nil
    out []]
   (cond (>= i (min limit (count bottom))) (cond-> out run (conj [(first run) i]))
    (plain? i) (recur (inc i) (or run [i]) out)
    :else (recur (inc i) nil (cond-> out run (conj [(first run) i])))))))

(defn ^:private note-in
 "The text of a note for a stretch of rule `r` cells wide: ` text ` padded to two spaces
 each side when that fits, else `text` between single spaces, else cut with a `…`."
 [text r]
 (let [n (txt/display-width text)]
  (cond (<= (+ n 4) r) (str " " (fit-cell text (- r 2) :left) " ")
   (<= (+ n 2) r) (str " " text " ")
   :else (str " " (txt/take-width text (max 0 (- r 3))) "…" " "))))

(defn ^:private with-note
 "The bottom border `bottom` with `text` written in the rule of it, never over a junction
 glyph (`╩ ╦ ╣ ╠`) or a corner. The note goes in the first column's stretch of rule when
 it fits there, else in the longest stretch between junctions, where the text is cut with
 a `…` if even that is too short. Never right of the joint to the footer's box (the `╦`,
 when the art has one) or at the corner at the end of the border."
 [art bottom text]
 (let [[from _] (first (:spans art))
   limit (or (str/index-of bottom "╦") (dec (count bottom)))
   runs (rule-runs bottom limit)
   need (+ 2 (txt/display-width text))
   len (fn [[f t]] (- t f))
   first-run (first (filter (fn [[f t]] (and (<= f from) (< from t))) runs))
   [f t] (if (and first-run (>= (len first-run) need))
    first-run
    (when (seq runs) (reduce #(if (> (len %2) (len %1)) %2 %1) runs)))]
  (if (and f (>= (len [f t]) 4))
   (put-at bottom f (note-in text (len [f t])))
   bottom)))

(defn frame
 "The page of a table: `{:lines [24 strings] :offset first-row-shown}`.

 `art` is `parse-art`, `rows` the rows `[{:cells [..] :aligns [..] :mark \\* or \\-} ...]`
 (a row with no `:cells` entry has blank ones), `cursor` the index of the row under the
 cursor, `offset` the first row that was shown, and `options` may have `:note` (text for
 the bottom border, 22 characters at most), `:empty-hint` (what the first row says
 when there is no row) and `:hide-legends` (labels of the footer's legends, `\"edit\"`, to
 write over with spaces, besides the ones the table hides itself)."
 ([art rows cursor offset] (frame art rows cursor offset {}))
 ([art rows cursor offset {:keys [note empty-hint hide-legends]}]
  (let [n (count rows)
    size (window art)
    cursor (if (zero? n) 0 (max 0 (min cursor (dec n))))
    offset (viewport offset cursor n size)
    shown (subvec (vec rows) offset (min n (+ offset size)))
    rows-lines (mapv
     (fn [i row]
      (body-line art (row-cells art row) (= (+ offset i) cursor)))
     (range)
     shown)
    rows-lines (if (and (zero? n) empty-hint)
     [(body-line art
       (row-cells art {:cells [empty-hint]})
       false)]
     rows-lines)
    blanks (repeat (- size (count rows-lines)) (:template art))]
   {:lines (with-counter-and-arrows
     art
     (vec (concat
       (:head art)
       rows-lines
       blanks
       [(if note (with-note art (:bottom art) note) (:bottom art))]
       (footer-lines art n hide-legends)))
     cursor
     n),
    :offset offset})))

;; --- the keys every table of editable rows has

(defn step
 "The state `st` (`{:s state :cursor i ...}`, see `baysol.tui.draft`) after the keys that
 every editable table handles the same way: the arrows move the cursor, `^r` marks the
 row under it to be removed and `^u` undoes its last change (neither with no row), the
 cursor held on the rows. Returns nil for any other input, which is for the screen.

 # Returns
 The state, or nil.

 # Exceptions
 None."
 [st input]
 (let [{:keys [s cursor]} st
   n (count (:rows s))]
  (cond
   (= input KeyType/ArrowDown) (assoc st :cursor (txt/clamp-cursor (inc cursor) s))
   (= input KeyType/ArrowUp) (assoc st :cursor (txt/clamp-cursor (dec cursor) s))

   (and (= input :ctrl-r) (pos? n))
   (let [s (draft/remove-row s cursor)]
    (assoc st :s s :cursor (txt/clamp-cursor cursor s)))

   (and (= input :ctrl-u) (pos? n))
   (let [s (draft/undo s cursor)]
    (assoc st :s s :cursor (txt/clamp-cursor cursor s))))))

(defn save-rows
 "The state `st` after `^w`: if `problem` (`[i message]`, the first row that cannot be
 saved, or nil) is given it is told and the cursor goes to the row; else `save!` is called
 with the items to save (`draft/to-save`) and, unless it throws, the state is what was
 saved (the note `saved`, the cursor held on the rows, no `:hint`), else the note is
 `could not save!`.

 # Returns
 The state.

 # Exceptions
 None."
 [st problem save!]
 (if-let [[i message] problem]
  (assoc st :note (str "row " (inc i) ": " message) :cursor i)
  (if (try (save! (draft/to-save (:s st))) true (catch Exception _ false))
   (let [s (draft/commit (:s st))]
    (-> st
     (assoc :s s :cursor (txt/clamp-cursor (:cursor st) s) :note "saved")
     (dissoc :hint)))
   (assoc st :note "could not save!"))))
