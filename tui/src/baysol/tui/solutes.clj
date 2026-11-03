;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The solutes being edited, with what has not been saved: pure functions of a state, so
;; none of it needs a terminal. The state is `{:rows [row ...]}` and a row
;; `{:saved solute-or-nil, :draft solute-or-nil, :removed? bool}`:
;;
;;   saved     what `buffer.edn` has (nil for a row added since the last save)
;;   draft     what the row was edited to (nil when it stands at what was saved)
;;   removed?  the row is to go at the next save (shown with `-`); until then `undo` brings
;;             it back
;;
;; A row shows `*` while it is new or has a draft, `-` while it is to be removed. A
;; solute is a map of one of the kinds of `baysol.tui.buffer` (`{:kind :name :arg :mM
;; :sigma-mM}` and the keys its kind needs); the screen builds them (`baysol.tui.add-flow`)
;; and this namespace only keeps them.

(ns baysol.tui.solutes
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.draft :as draft]
  [clojure.string :as str]))

(def blank-solute
 "A solute with nothing filled in, the draft of a row just added: a non-biological one
 until the name is picked."
 {:kind :nonbiological, :name "", :arg "", :mM nil, :sigma-mM nil})

(defn initial
 "The state of the saved solutes `solutes`, nothing edited."
 [solutes]
 (draft/initial solutes))

(defn value
 "The solute of `row` as it stands now: its draft, else what was saved."
 [row]
 (draft/value row))

(defn mark
 "The mark of `row`: `\\-` if it is to be removed, `\\*` if it is new or edited, else nil."
 [row]
 (draft/mark row))

(defn dirty?
 "Whether anything of `state` is not saved."
 [state]
 (draft/dirty? state))

(defn add-row
 "`state` with a new blank row at the end."
 [state]
 (draft/add-draft state blank-solute))

(defn set-solute
 "`state` with the solute of row `i` set to `solute` as a whole. A row set back to what
 was saved has no draft."
 [state i solute]
 (draft/set-draft state i solute))

(defn set-field
 "`state` with the field `field` (`:name`, `:mM` or `:sigma-mM`, or any other key of the
 solute) of row `i` set to `v`. The name is a label: the row's `:arg` is not touched. A
 row set back to what was saved has no draft."
 [state i field v]
 (set-solute state i (assoc (value (get-in state [:rows i])) field v)))

(defn append-solutes
 "`state` with a new row, a draft, for each of `solutes` added at the end."
 [state solutes]
 (draft/add-drafts state solutes))

(defn drop-new-rows
 "`state` without the rows of `indices` that were never saved (the cancelled rows of an
 add); a row that was saved is left alone."
 [state indices]
 (let [gone (set (filter #(nil? (get-in state [:rows % :saved])) indices))]
  (update state
   :rows
   #(vec (keep-indexed (fn [i row] (when-not (contains? gone i) row)) %)))))

(defn remove-row
 "`state` with row `i` marked to be removed at the next save; a row that was never saved
 has nothing to confirm and goes at once."
 [state i]
 (draft/remove-row state i))

(defn undo
 "`state` with the last change of row `i` undone: a removal first, then the draft; a row
 that was never saved goes."
 [state i]
 (draft/undo state i))

(defn problem
 "What is missing in the solute `s`, as a short message, or nil: a name, a concentration
 above 0, an uncertainty of 0 or more and the keys of its kind (`buffer/row-problem`)."
 [s]
 (cond (str/blank? (:name s)) "name needed"
  (not (and (:mM s) (pos? (:mM s)))) "mM must be > 0"
  (not (and (:sigma-mM s) (>= (:sigma-mM s) 0))) "±mM needed"
  (buffer/row-problem s) "row incomplete"))

(defn problems
 "The first problem of the rows that stay at the next save: `[i message]`, or nil."
 [state]
 (first (for [[i row] (map-indexed vector (:rows state))
    :when (not (:removed? row))
    :let [p (problem (value row))]
    :when p]
   [i p])))

(defn to-save
 "The solutes `buffer.edn` gets at the next save, a vector: the rows not marked to go."
 [state]
 (draft/to-save state))

(defn commit
 "`state` after a save: the removed rows gone, every other row standing at what it is."
 [state]
 (draft/commit state))
