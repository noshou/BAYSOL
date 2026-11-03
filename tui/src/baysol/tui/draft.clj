;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The rows of a table being edited, with what has not been saved: the state the tables of
;; the solutes (`baysol.tui.solutes`), of the custom solutes (`baysol.tui.custom`) and of
;; the recipes share, as pure functions, whatever a row holds. The state is
;; `{:rows [row ...]}` and a row `{:saved item-or-nil, :draft item-or-nil, :removed? bool}`:
;;
;;   saved     what the file has (nil for a row added since the last save)
;;   draft     what the row was edited to (nil when it stands at what was saved)
;;   removed?  the row is to go at the next save (shown with `-`); until then `undo` brings
;;             it back
;;
;; A row shows `*` while it is new or has a draft, `-` while it is to be removed.

(ns baysol.tui.draft
 (:require [baysol.tui.limits :as limits]))

(defn initial
 "The state of the saved items `items`, nothing edited.

 # Returns
 A state map.

 # Exceptions
 None."
 [items]
 {:rows (mapv (fn [s] {:saved s, :draft nil, :removed? false}) items)})

(defn value
 "The item of `row` as it stands now: its draft, else what was saved.

 # Returns
 The item, or nil.

 # Exceptions
 None."
 [row]
 (or (:draft row) (:saved row)))

(defn mark
 "The mark of `row`: `\\-` if it is to be removed, `\\*` if it is new or edited, else nil.

 # Returns
 A character or nil.

 # Exceptions
 None."
 [row]
 (cond (:removed? row) \-
  (or (nil? (:saved row)) (some? (:draft row))) \*))

(defn dirty?
 "Whether anything of `state` is not saved.

 # Returns
 A boolean.

 # Exceptions
 None."
 [state]
 (boolean (some mark (:rows state))))

(defn changes
 "How many rows of `state` are not saved: new, edited or marked to be removed.

 # Returns
 An integer.

 # Exceptions
 None."
 [state]
 (count (filter mark (:rows state))))

(defn room?
 "Whether `state` has room for another row (fewer than `limits/max-rows`).

 # Returns
 A boolean.

 # Exceptions
 None."
 [state]
 (< (count (:rows state)) limits/max-rows))

(defn drop-row
 "`state` without row `i`.

 # Returns
 A state map.

 # Exceptions
 `IndexOutOfBoundsException` for a row that is not there."
 [state i]
 (update state :rows #(into (subvec % 0 i) (subvec % (inc i)))))

(defn add-draft
 "`state` with a new row, a draft of `item`, at the end.

 # Returns
 A state map.

 # Exceptions
 None."
 [state item]
 (update state :rows conj {:saved nil, :draft item, :removed? false}))

(defn add-drafts
 "`state` with a new row, a draft, for each of `items` added at the end.

 # Returns
 A state map.

 # Exceptions
 None."
 [state items]
 (update state
  :rows
  into
  (map (fn [s] {:saved nil, :draft s, :removed? false}))
  items))

(defn set-draft
 "`state` with the item of row `i` set to `item` as a whole. A row set back to what was
 saved has no draft.

 # Returns
 A state map.

 # Exceptions
 None."
 [state i item]
 (assoc-in state
  [:rows i :draft]
  (when-not (= item (get-in state [:rows i :saved])) item)))

(defn remove-row
 "`state` with row `i` marked to be removed at the next save; a row that was never saved
 has nothing to confirm and goes at once.

 # Returns
 A state map.

 # Exceptions
 None."
 [state i]
 (if (nil? (get-in state [:rows i :saved]))
  (drop-row state i)
  (assoc-in state [:rows i :removed?] true)))

(defn undo
 "`state` with the last change of row `i` undone: a removal first, then the draft; a row
 that was never saved goes.

 # Returns
 A state map.

 # Exceptions
 None."
 [state i]
 (let [row (get-in state [:rows i])]
  (cond (:removed? row) (assoc-in state [:rows i :removed?] false)
   (nil? (:saved row)) (drop-row state i)
   :else (assoc-in state [:rows i :draft] nil))))

(defn to-save
 "The items the file gets at the next save, a vector: the rows not marked to go.

 # Returns
 A vector.

 # Exceptions
 None."
 [state]
 (vec (for [row (:rows state)
    :when (not (:removed? row))]
   (value row))))

(defn commit
 "`state` after a save: the removed rows gone, every other row standing at what it is.

 # Returns
 A state map.

 # Exceptions
 None."
 [state]
 (initial (to-save state)))
