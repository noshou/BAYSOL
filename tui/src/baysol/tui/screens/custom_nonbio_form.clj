;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The form page of a custom NON-BIOLOGICAL solute (art resources/custom-nonbio/pages/
;; page.txt, drawn by `baysol.tui.screens.form`): five fields, name, formula, Z, PMV @ 25 °C
;; and ±, and under them what BAYSOL will use. Opened from the custom solutes table by `^n`
;; (a new entry) and by Enter on a row (the same page, filled in).
;;
;;   up, down   the field before and after (no wrapping)
;;   enter      edit the field under the cursor: type in its cell, Enter takes it, Esc drops
;;              what was typed in it; a text longer than the cell shows its end after a `…`
;;   ^u         the field under the cursor back to what it was when the form opened
;;   ^w         accept the form: the entry goes back to the table as a draft. A form with a
;;              problem is not accepted: the first problem is told on the bottom border and
;;              the cursor goes to its field.
;;   escape     cancel the form, nothing changes
;;
;; Z is computed from the formula as soon as the formula is taken, and shown in the Z cell,
;; to keep or to type over; a formula that does not change keeps the Z that was typed, a
;; changed one gets the computed Z (`custom/take-formula`); a formula that is not understood
;; says why on the border and leaves Z to be typed. A blank ± shows the setting
;; `PMV_FALLBACK_UNCERT` in parentheses, 2 decimals; the entry keeps `:sigma nil`.
;;
;; The preview: how the electrons add up (`formula/breakdown`) and the numbers BAYSOL will
;; use, Z, PMV and σ (`(fallback)` after a σ that is the setting's).
;;
;; The state and the step are pure functions (`initial`, `view`, `step`), tested without a
;; terminal. The fields' cells are found in the art: the block with the most labelled lines
;; holds them, in order.

(ns baysol.tui.screens.custom-nonbio-form
 (:require [baysol.tui.custom :as custom]
  [baysol.tui.formula :as formula]
  [baysol.tui.screens.form :as form]
  [baysol.tui.screens.page-load :as pgld]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "custom-nonbio")

(def art
 "The art of the page, parsed."
 (form/parse-art (pgld/load-ascii "page" screen-name)))

(def fields
 "The fields in the order of the page."
 [:name :formula :z :pmv :sigma])

(defn field-cells
 "The cell `[line span]` of each field of `fields` in `page`: the value cell (the second) of
 each labelled line of the block that has the most of them. Throws an exception when the
 art has not as many as there are fields."
 [page]
 (let [block (apply max-key #(count (form/labelled page %)) (:blocks page))
   lines (form/labelled page block)]
  (when-not (= (count lines) (count fields))
   (throw (ex-info "custom-nonbio art: wrong number of fields"
     {:found (count lines), :expected (count fields)})))
  (mapv (fn [line] [line 1]) lines)))

(def ^:private cells (field-cells art))

(defn initial
 "The state of the form for `entry` (a non-biological entry map; `custom/blank-
 nonbiological` for a new one). `opts`: `:fallback` (the number a blank ± stands for),
 `:others` (the names of the other entries, for the check of the name) and `:builtin?` (a
 predicate on a name, or nil)."
 [entry {:keys [fallback others builtin?]}]
 {:entry entry,
  :orig entry,
  :cursor 0,
  :edit nil,
  :note nil,
  :fallback fallback,
  :others others,
  :builtin? builtin?})

(defn ^:private field-text
 "The text to start typing `field` from."
 [e field]
 (case field
  :name (str (:name e))
  :formula (str (:formula e))
  :z (if (:z e) (str (:z e)) "")
  (custom/format-number (get e field))))

(defn ^:private shown
 "What the cell of `field` shows: its value, a blank ± as the fallback in parentheses."
 [{:keys [entry fallback]} field]
 (if (and (= field :sigma) (nil? (:sigma entry)))
  (str "(" (custom/format-rounded fallback) ")")
  (field-text entry field)))

(defn preview
 "The paragraphs of the preview for the state `st`: the breakdown of the electrons from the
 formula, then `Z = ..   PMV = .. cm³/mol   σ = .. cm³/mol` of what is known (the σ with
 `(fallback)` when it is the setting's); nothing for what is not known yet."
 [{:keys [entry fallback]}]
 (let [{:keys [formula z pmv sigma]} entry
   parts
   (cond-> []
    z (conj (str "Z = " z))
    pmv (conj (str "PMV = " (custom/format-number pmv) " cm³/mol"))
    sigma (conj (str "σ = " (custom/format-number sigma) " cm³/mol"))
    (and pmv (nil? sigma))
    (conj (str "σ = " (custom/format-rounded fallback) " cm³/mol (fallback)")))]
  (vec (remove nil?
    [(when-not (str/blank? formula) (formula/breakdown formula))
     (when (seq parts) (str/join "   " parts))]))))

(defn view
 "What `form/frame` draws for the state `st`: the value of each field, the one being typed
 into with its cursor, the cursor, the note and the preview."
 [{:keys [cursor edit note], :as st}]
 (let [texts (into {} (map (fn [f cell] [cell (shown st f)]) fields cells))
   cell (nth cells cursor)]
  {:cells (cond-> texts edit (assoc cell (form/edit-text art cell (:text edit)))),
   :cursor cell,
   :note note,
   :preview (preview st)}))

(defn ^:private take-field
 "The state `st` after the text `text` typed for `field` was taken (an error is the note
 and the cell stays open)."
 [st field text]
 (let [{:keys [value error]} (custom/parse-cell field text)]
  (cond error (assoc st :note error)
   (= field :formula) (let [r (custom/take-formula (:entry st) text false)]
    (assoc st :entry (:value r) :note (:note r) :edit nil))
   :else (assoc st :entry (assoc (:entry st) field value) :edit nil))))

(defn ^:private undo-field
 "The state `st` with `field` back to what it was when the form opened (the formula with
 its Z, which comes from it)."
 [st field]
 (let [orig (:orig st)]
  (update st
   :entry
   (fn [e]
    (if (= field :formula)
     (assoc e :formula (:formula orig) :z (:z orig))
     (assoc e field (get orig field)))))))

(defn ^:private accept
 "The state `st` accepted, or with the first problem as the note and the cursor on its
 field."
 [{:keys [entry builtin? others], :as st}]
 (if-let [[field message] (custom/entry-problem entry builtin? others)]
  (assoc st :note message :cursor (max 0 (.indexOf ^java.util.List fields field)))
  (assoc st :done :accepted)))

(defn step
 "The state `st` after the raw input `input` (see `state/key->raw`)."
 [{:keys [cursor edit], :as st} input]
 (let [field (nth fields cursor)]
  (if edit
   (cond (= input KeyType/Escape) (assoc st :edit nil)
    (= input KeyType/Enter) (take-field st field (:text edit))
    :else (form/type-edit st input))
   (cond (= input KeyType/Escape) (assoc st :done :cancelled)
    (= input KeyType/ArrowDown)
    (assoc st :cursor (min (dec (count fields)) (inc cursor)))
    (= input KeyType/ArrowUp) (assoc st :cursor (max 0 (dec cursor)))
    (= input KeyType/Enter)
    (assoc st :edit {:text (field-text (:entry st) field)})
    (= input :ctrl-u) (undo-field st field)
    (= input :ctrl-w) (accept st)
    :else st))))

(defn show!
 "Shows the form of the non-biological entry `entry` on `screen` (solid colour
 `background`), `opts` as for `initial`. Returns the accepted entry, nil when it was
 cancelled, :back for Ctrl-X or :quit when the terminal went away."
 [^TerminalScreen screen ^TextColor background entry opts]
 (form/show-form! screen background art (initial entry opts) view step))
