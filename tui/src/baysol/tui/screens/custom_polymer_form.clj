;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The form page of a custom POLYMER (art resources/custom-polymer/pages/page.txt, drawn by
;; `baysol.tui.screens.form`): a generic additive chain, PMV = pmv-ends + Σ slope·n, Z =
;; z-ends + Σ Z per unit·n, of one to four kinds of repeat unit. The page has the name, a
;; table of four unit rows (unit | formula | Z per unit | PMV per unit | ± per unit), the
;; end groups on the same columns (formula | Z | PMV | ±) and the preview. Opened from the
;; custom solutes table by `^p` (a new entry) and by Enter on a row (the same page, filled
;; in, all the units editable).
;;
;;   up, down       the cell above and below: name, the four unit rows, the end groups
;;   left, right    the cell before and after, inside the table
;;   enter          edit the cell under the cursor: type in it, Enter takes it, Esc drops
;;                  what was typed in it; a text longer than the cell shows its end after
;;                  a `…`
;;   ^u             the cell under the cursor back to what it was when the form opened
;;   ^w             accept the form (the entry goes back to the table as a draft). A form
;;                  with a problem is not accepted: the first problem is told on the bottom
;;                  border and the cursor goes to its cell.
;;   escape         cancel the form, nothing changes
;;
;; A unit row is USED when it has anything in it; row 1 is always used, rows 2 to 4 are
;; optional and an all-blank row is ignored (`custom/used-rows`), a half-filled one is a
;; problem. So adding, removing (clearing a row) and re-ordering units is editing rows. The
;; label is one word (8 characters at most, unique, case-insensitively); a used row with no
;; label shows the one offered for its place, `(A)` to `(D)`, which is taken when the
;; form is accepted (and as soon as its formula is typed). The Z per unit is computed from
;; the formula, to keep or type over, as in `custom-nonbio-form` (`custom/take-formula`); a
;; unit's PMV is a number (required); its ± is absolute and blank shows `(2%)`.
;;
;; The END GROUPS have no default: Z (a whole number, or computed from the end groups'
;; formula when one is typed, e.g. `H2O`) and PMV are required (`end groups needed`), a
;; blank ± is none. The formula of the end groups is not part of the entry (the stored
;; shape is frozen): it only gives the Z, and is not kept when the form is opened again.
;;
;; The preview: the chain in words with the user's labels, `PMV = 9 + 36.7·nA + 53.1·nB`
;; and `Z = 10 + 24·nA + 32·nB`, then, once everything is given, Z, PMV and σ of 10 and of
;; 100 of each unit, by `custom/chain-values`, the rule of the Julia type.
;;
;; The state and the step are pure functions (`initial`, `view`, `step`). The cells are
;; found in the art: the name is the second cell of the first block, the unit rows are the
;; block whose lines have no label, the end groups the line after it.

(ns baysol.tui.screens.custom-polymer-form
 (:require [baysol.tui.custom :as custom]
  [baysol.tui.screens.form :as form]
  [baysol.tui.screens.page-load :as pgld]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "custom-polymer")

(def art
 "The art of the page, parsed."
 (form/parse-art (pgld/load-ascii "page" screen-name)))

(def ^:private unit-keys
 "The field of a unit row in each column of the table."
 [:label :formula :z :slope :sigma])

(def ^:private ends-keys
 "The field of the end groups in each column of the table (the first is the label)."
 [nil :ends-formula :z-ends :pmv-ends :sigma-ends])

(defn layout
 "Where the cells of the page are, read from `page`: `{:name cell :units [line ...] :ends
 line}`, `cell` a `[line span]` and the lines those of the rows of the unit table and of the
 end groups (their cells are `[line column]`). The unit rows are the block with the most
 lines that have no label and several cells; the end groups are the line after it. Throws an
 exception when the art has not that, or fewer unit rows than a polymer has units."
 [page]
 (let [blocks (:blocks page)
   plain? (fn [block]
    (every? #(and (str/blank? (first (form/texts page %)))
      (>= (count (form/spans page %)) 5))
     block))
   candidates (keep-indexed (fn [i block] (when (plain? block) [i block]))
    (rest blocks))
   [unit-index unit-block] (when (seq candidates)
    (apply max-key (comp count second) candidates))
   unit-index (some-> unit-index
    inc)
   ends-block (get blocks
    (some-> unit-index
     inc))
   name-line (first (form/labelled page (first blocks)))]
  (when-not (and unit-block
    ends-block
    name-line
    (>= (count unit-block) custom/max-units))
   (throw (ex-info "custom-polymer art: no name, unit table or end groups" {})))
  {:name [name-line 1],
   :units (vec (take custom/max-units unit-block)),
   :ends (first ends-block)}))

(def ^:private places (layout art))

(def ^:private n-rows
 "The rows of the grid: the name, the unit rows, the end groups."
 (+ 2 (count (:units places))))

(defn ^:private row-kind
 [row]
 (cond (zero? row) :name
  (= row (dec n-rows)) :ends
  :else :unit))

(defn ^:private col-of
 "The column the cursor is in on row `row` when the column asked for is `col`."
 [row col]
 (case (row-kind row)
  :name 0
  :ends (max 1 col)
  col))

(defn field-at
 "The field of the cell at row `row` of the grid (0 the name, then the unit rows, last the
 end groups) and table column `col`: `:name`, `[:unit i k]`, `:ends-formula`, `:z-ends`,
 `:pmv-ends` or `:sigma-ends`."
 [row col]
 (let [col (col-of row col)]
  (case (row-kind row)
   :name :name
   :ends (nth ends-keys col)
   [:unit (dec row) (nth unit-keys col)])))

(defn cell-at
 "The cell `[line span]` of the art at row `row` and column `col` of the grid."
 [row col]
 (let [col (col-of row col)]
  (case (row-kind row)
   :name (:name places)
   :ends [(:ends places) col]
   [(nth (:units places) (dec row)) col])))

(defn ^:private position-of
 "`[row col]` of the cell of `field`."
 [field]
 (cond (= field :name) [0 0]
  (vector? field) [(inc (second field))
   (.indexOf ^java.util.List unit-keys (nth field 2))]
  :else [(dec n-rows) (.indexOf ^java.util.List ends-keys field)]))

(defn initial
 "The state of the form for `entry` (a polymer entry map; `custom/blank-polymer` for a new
 one): its units are padded with blank ones to the rows of the table. `opts`: `:others` (the
 names of the other entries, for the check of the name) and `:builtin?` (a predicate on a
 name, or nil)."
 [entry {:keys [others builtin?]}]
 (let [rows (count (:units places))
   entry (update entry
    :units
    #(vec (take rows (concat % (repeat custom/blank-unit)))))]
  {:entry entry,
   :orig entry,
   :ends-formula "",
   :row 0,
   :col 0,
   :edit nil,
   :note nil,
   :others others,
   :builtin? builtin?}))

(defn ^:private get-field
 [st field]
 (if (= field :ends-formula)
  (:ends-formula st)
  (custom/get-field (:entry st) field)))

(defn ^:private set-field
 [st field v]
 (if (= field :ends-formula)
  (assoc st :ends-formula v)
  (update st
   :entry
   (fn [e]
    (if (vector? field)
     (assoc-in e [:units (second field) (nth field 2)] v)
     (assoc e field v))))))

(defn ^:private unit-used?
 [st i]
 (contains? (set (custom/used-rows (get-in st [:entry :units]))) i))

(defn ^:private field-text
 "The text to start typing `field` from: a label that is blank starts empty (the cell only
 shows the one offered, as a placeholder), a typed one from its text."
 [st field]
 (let [v (get-field st field)]
  (cond (= (when (vector? field) (nth field 2)) :label)
   (if (str/blank? v) "" v)
   (#{:name :formula :ends-formula} (if (vector? field) (nth field 2) field))
   (str v)
   (#{:z :z-ends} (if (vector? field) (nth field 2) field)) (if v (str v) "")
   :else (custom/format-number v))))

(defn ^:private shown
 "What the cell of `field` shows: its value, a blank ± of a used unit as `(2%)` and the
 label offered to a used unit as `(A)`."
 [st field]
 (let [k (if (vector? field) (nth field 2) field)
   i (when (vector? field) (second field))
   v (get-field st field)]
  (cond (and (= k :label) (str/blank? v)) (if (unit-used? st i)
    (str "(" (custom/default-label i) ")")
    "")
   (and (= k :sigma) (nil? v) (unit-used? st i))
   (str "(" (custom/format-number (* 100 custom/polymer-unknown-rel-unc)) "%)")
   :else (field-text st field))))

;; --- the preview

(defn ^:private term-text
 "`x` with the sign of its place in a sum: ` + 36.7·nA` or ` - 5.2·nA` (`?` for a number
 not given yet)."
 [x label]
 (str (if (and (number? x) (neg? x)) " - " " + ")
  (if (number? x) (custom/format-number (abs x)) "?")
  "·n"
  label))

(defn ^:private equation
 "`lhs = head + a·nA + b·nB` for the number `head` of the ends and the `[x label]` terms."
 [lhs head terms]
 (str lhs
  " = "
  (if (number? head) (custom/format-number head) "?")
  (str/join (map (fn [[x label]] (term-text x label)) terms))))

(defn ^:private complete?
 "Whether the polymer entry `e` has every number the chain values need."
 [e]
 (and (number? (:z-ends e))
  (number? (:pmv-ends e))
  (every? #(and (number? (:z %)) (number? (:slope %))) (:units e))))

(defn ^:private chain-line
 "The line for `k` of each unit: `n = 10 of each: Z = 274, PMV = 411.5 cm³/mol, σ = 4.02
 cm³/mol`."
 [e k]
 (let [{:keys [z pmv sigma]} (custom/chain-values e (repeat (count (:units e)) k))]
  (str "n = "
   k
   " of each: Z = "
   z
   ", PMV = "
   (custom/format-rounded pmv)
   " cm³/mol, σ = "
   (custom/format-rounded sigma)
   " cm³/mol")))

(def ^:private chain-counts
 "The number of each unit the preview shows the chain's values for."
 [10 100])

(defn entry-of
 "The entry the state `st` stands for: the units that are used, with the offered labels."
 [st]
 (update (:entry st) :units custom/compact-units))

(defn preview
 "The paragraphs of the preview for the state `st`: the chain's PMV and Z in words with
 the labels of the used units and, when every number they need is given, the chain's
 values for 10 and for 100 of each unit. Nothing before anything is given."
 [st]
 (let [e (entry-of st)
   units (:units e)]
  (if (and (every? custom/unit-blank? (get-in st [:entry :units]))
    (nil? (:z-ends e))
    (nil? (:pmv-ends e)))
   []
   (into [(equation "PMV" (:pmv-ends e) (map (juxt :slope :label) units))
     (equation "Z" (:z-ends e) (map (juxt :z :label) units))]
    (when (complete? e) (map #(chain-line e %) chain-counts))))))

;; --- the page

(defn view
 "What `form/frame` draws for the state `st`: the value of each cell, the one being typed
 into with its cursor, the cursor, the note and the preview."
 [{:keys [row col edit note], :as st}]
 (let [texts (into {}
    (for [r (range n-rows)
      c (range 5)
      :let [field (field-at r c)
       cell (cell-at r c)]
      :when (and (= (col-of r c) c)
       (or (not= r (dec n-rows)) (pos? c)))]
     [cell (shown st field)]))
   cell (cell-at row col)]
  {:cells (cond-> texts edit (assoc cell (form/edit-text art cell (:text edit)))),
   :cursor cell,
   :mark-cell? true,
   :note note,
   :preview (preview st)}))

;; --- the keys

(defn ^:private take-formula
 "The state `st` with the formula text `text` of the unit field `field` taken (the label
 offered to the row if it has none, the Z computed)."
 [st field text]
 (let [i (second field)
   r (custom/take-formula (get-in st [:entry :units i])
    text
    true
    (custom/default-label i))]
  (-> st
   (assoc-in [:entry :units i] (:value r))
   (assoc :note (:note r) :edit nil))))

(defn ^:private take-ends-formula
 "The state `st` with the formula text `text` of the end groups taken: Z of the ends is
 what it comes to unless the formula is the one it had."
 [st text]
 (let [r (custom/take-formula {:formula (:ends-formula st),
     :z (get-in st [:entry :z-ends])}
    text
    false)
   z (get-in r [:value :z])
   negative? (and z (neg? z))]
  (-> st
   (assoc :ends-formula (get-in r [:value :formula]))
   (assoc-in [:entry :z-ends] (if negative? nil z))
   (assoc :note (if negative? "Z must be >= 0" (:note r)) :edit nil))))

(defn ^:private take-field
 "The state `st` after the text `text` typed for `field` was taken (an error is the note
 and the cell stays open)."
 [st field text]
 (let [k (if (vector? field) (nth field 2) field)
   {:keys [value error]} (custom/parse-cell (if (= k :ends-formula) :formula k)
    text)]
  (cond error (assoc st :note error)
   (= k :formula) (take-formula st field text)
   (= k :ends-formula) (take-ends-formula st text)
   :else (-> st
    (set-field field value)
    (assoc :edit nil)))))

(defn ^:private undo-field
 "The state `st` with the cell of `field` back to what it was when the form opened (a
 unit's formula with its Z, which comes from it; the end groups' formula to none)."
 [st field]
 (let [orig-unit (fn [i] (get-in (:orig st) [:units i]))]
  (cond (= field :ends-formula) (assoc st :ends-formula "")
   (and (vector? field) (= (nth field 2) :formula))
   (-> st
    (set-field field (:formula (orig-unit (second field))))
    (set-field (assoc field 2 :z) (:z (orig-unit (second field)))))
   (vector? field) (set-field st field (custom/get-field (:orig st) field))
   :else (set-field st field (get (:orig st) field)))))

(defn ^:private accept
 "The state `st` accepted, or with the first problem as the note and the cursor on its
 cell."
 [{:keys [builtin? others], :as st}]
 (let [e (entry-of st)
   rows (custom/used-rows (get-in st [:entry :units]))]
  (if-let [[field message] (custom/entry-problem e builtin? others)]
   (let [field (if (vector? field) (assoc field 1 (nth rows (second field))) field)
     [row col] (position-of field)]
    (assoc st :note message :row (or row 0) :col (or col 0)))
   (assoc st :entry e :done :accepted))))

(defn ^:private cols-in
 "How many columns row `row` of the grid has, counted from column 0."
 [row]
 (case (row-kind row)
  :name 1
  5))

(defn ^:private move
 "The state `st` with the cursor moved by `dr` rows and `dc` columns, kept in the grid. A
 move up or down keeps the column that was asked for, so that a short row (the name) does
 not forget it."
 [{:keys [row col], :as st} dr dc]
 (let [row (max 0 (min (dec n-rows) (+ row dr)))
   low (if (= (row-kind row) :ends) 1 0)
   col (if (zero? dc)
    col
    (max low (min (dec (cols-in row)) (+ (col-of row col) dc))))]
  (assoc st :row row :col col)))

(defn step
 "The state `st` after the raw input `input` (see `state/key->raw`)."
 [{:keys [row col edit], :as st} input]
 (let [field (field-at row col)]
  (if edit
   (cond (= input KeyType/Escape) (assoc st :edit nil)
    (= input KeyType/Enter) (take-field st field (:text edit))
    :else (form/type-edit st input))
   (cond (= input KeyType/Escape) (assoc st :done :cancelled)
    (= input KeyType/ArrowDown) (move st 1 0)
    (= input KeyType/ArrowUp) (move st -1 0)
    (= input KeyType/ArrowRight) (move st 0 1)
    (= input KeyType/ArrowLeft) (move st 0 -1)
    (= input KeyType/Enter) (assoc st :edit {:text (field-text st field)})
    (= input :ctrl-u) (undo-field st field)
    (= input :ctrl-w) (accept st)
    :else st))))

(defn show!
 "Shows the form of the polymer entry `entry` on `screen` (solid colour `background`),
 `opts` as for `initial`. Returns the accepted entry, nil when it was cancelled, :back for
 Ctrl-X, or :quit when the terminal went away."
 [^TerminalScreen screen ^TextColor background entry opts]
 (form/show-form! screen background art (initial entry opts) view step))
