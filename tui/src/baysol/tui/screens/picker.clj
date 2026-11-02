;; SPDX-License-Identifier: LGPL-3.0-or-later

;; A list of names to pick one from, as a dropdown laid over a page: type to narrow the
;; list (names that start with the text, else those that have it inside; case does not
;; matter), up and down move and wrap, Tab takes the highlighted name into the text, Enter
;; picks it, Escape cancels. The colour and font settings pick the same way
;; (`baysol.tui.screens.sheets`); the main menu picks a project with it.
;;
;; The state is a map (`initial`), `step` is a pure function of a state and a key, and
;; `overlay` writes the dropdown onto the lines of a page, so none of it needs a terminal.

(ns baysol.tui.screens.picker
 (:require [baysol.tui.screens.page-load :as pgld]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private max-text
 "The longest text typed to narrow the list."
 40)

(defn narrow
 "The names of `names` that a text `typed` narrows the list to: all of them for no text,
 else those that start with it (case does not matter), and if there are none, those that
 have it inside."
 [names typed]
 (let [t (str/lower-case typed)
   lower (fn [n] (str/lower-case n))]
  (if (str/blank? t)
   names
   (let [prefix (filterv #(str/starts-with? (lower %) t) names)]
    (if (seq prefix) prefix (filterv #(str/includes? (lower %) t) names))))))

(defn index-of-name
 "The position of the name equal to `n` (case does not matter) in `names`, or 0."
 [names n]
 (let [t (str/lower-case n)]
  (or (first (keep-indexed #(when (= t (str/lower-case %2)) %1) names)) 0)))

(defn initial
 "The state of a picker over `names` with nothing typed and `current` (a name, or nil)
 highlighted."
 [names current]
 {:names (vec names),
  :matches (vec names),
  :buffer "",
  :index (if current (index-of-name names current) 0),
  :error nil})

(defn ^:private refilter
 "`state` with the text `buffer` typed: the names it narrows to, the first highlighted."
 [state buffer]
 (assoc state
  :buffer buffer
  :matches (narrow (:names state) buffer)
  :index 0
  :error nil))

(defn step
 "What `input` does in the picker `state`: `{:state new-state}`, `{:chosen name}` for
 Enter on a highlighted name, or `:cancel` for Escape (or the terminal going away). Enter
 with no name to pick leaves the picker open with an error."
 [{:keys [buffer matches index], :as state} input]
 (cond
  (or (= input KeyType/Escape) (= input KeyType/EOF)) :cancel

  (= input KeyType/Enter)
  (if (seq matches)
   {:chosen (nth matches index)}
   {:state (assoc state :error "not in the list")})

  (and (#{KeyType/ArrowDown KeyType/ArrowUp} input) (seq matches))
  {:state (assoc state
    :error nil
    :index (mod ((if (= input KeyType/ArrowDown) inc dec) index)
     (count matches)))}

  (and (= input KeyType/Tab) (seq matches)) {:state (refilter state
    (nth matches index))}

  (= input KeyType/Backspace)
  {:state (refilter state (subs buffer 0 (max 0 (dec (count buffer)))))}

  (and (char? input)
   (>= (int input) 32)
   (not= (int input) 127)
   (< (count buffer) max-text))
  {:state (refilter state (str buffer input))}

  :else {:state state}))

(def ^:private exit-hint
 "The reminder at the right of the status row of a dropdown."
 "exit: esc")

(defn status-line
 "The status row of a dropdown `width` characters wide: a space, the `status`, and the
 reminder of the key that leaves the dropdown at the right edge when there is room for
 both (a space between them at least)."
 [status width]
 (let [left (str " " status)
   room (- width (count left) 1 (count exit-hint))]
  (if (pos? room)
   (str left (apply str (repeat room \space)) " " exit-hint)
   (subs left 0 (min (count left) width)))))

(defn count-status
 "What the status row says of the matches: \"no match\", or `index` + 1 of `n` with the
 word \"matches\", which is left out when the row is too narrow (`width`) to keep the
 reminder of the key that leaves the dropdown beside it."
 [index n width]
 (let [full (str (inc index) " of " n " matches")]
  (cond (zero? n) "no match"
   (>= (- width (count full) 1 1 (count exit-hint)) 0) full
   :else (str (inc index) " of " n))))

(defn layout
 "Where and what the dropdown of the picker `state` shows, for `rows` rows at most
 (the names and a status row): `{:from first name shown :items how many :texts [cell ...]}`
 where each cell is the text of one row, `width` characters wide at most."
 [{:keys [matches index error]} rows width]
 (let [n (count matches)
   items (min (dec rows) n)
   from (max 0 (min (- index (quot items 2)) (- n items)))
   status (or error (count-status index n width))
   cut (fn [s] (subs s 0 (min (count s) width)))]
  {:from from,
   :items items,
   :texts (concat (for [k (range items)
      :let [at (+ from k)]]
     (cut (str " " (if (= at index) "> " "  ") (nth matches at))))
    [(status-line status width)])}))

(defn overlay
 "The lines `lines` of a page with the dropdown of the picker `state` written over them
 from row `row`, in the columns `col` to `col` + `width`, with room for `rows` rows."
 [lines state {:keys [row col width rows]}]
 (let [{:keys [texts]} (layout state rows width)]
  (reduce (fn [ls [k text]] (update ls (+ row k) pgld/put-text col width text))
   lines
   (map-indexed vector texts))))

(defn typed-text
 "What the picker shows of what was typed: the end of the text, with a cursor, in at most
 `width` characters."
 [{:keys [buffer]} width]
 (str (if (>= (count buffer) width)
   (str "…" (subs buffer (- (count buffer) (- width 2))))
   buffer)
  "_"))
