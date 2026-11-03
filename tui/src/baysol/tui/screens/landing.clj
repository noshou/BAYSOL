;; SPDX-License-Identifier: LGPL-3.0-or-later

;; A landing page drawn from its art: a title box, a box of options (one to a line, the
;; cursor `>` before the highlighted one), a status box, and static boxes (what the options
;; do, the footer). The art (resources/<screen>/pages/page.txt) says where everything is,
;; read by its glyphs, so the owner's art stays the one source of the geometry:
;;
;;   - the boxes are the rounded boxes (`╭`) above the footer: the first is the title, the
;;     second holds the options, the third the status; any others stay as they are;
;;   - the lines of a box that are blank between its `│` are its slots: the option slots
;;     of the second box, the status rows of the third;
;;   - the last three lines are the footer, never touched.
;;
;; Everything here is a pure function of the art and the text, so no terminal is needed. The
;; same namespace draws the small rounded boxes the landings and the recipes table open
;; over a page: a prompt for a name, a question and a list to pick from.

(ns baysol.tui.screens.landing
 (:require [baysol.tui.text :as txt]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.state :as kb]
  [baysol.tui.screens.table :as table]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private footer-lines 3)

(defn ^:private box-top?
 [line]
 (str/starts-with? (str/triml line) "╭"))

(defn ^:private blank-slot?
 "Whether `line` is a box row with nothing between its borders."
 [line]
 (boolean (re-matches #" *│ +│ *" line)))

(defn ^:private slot
 "Where the text of the box row `row` of `line` goes: `{:row :from :width}`, between the
 first and the last `│` of the line (its edges excluded)."
 [row line]
 (let [left (str/index-of line "│")
   right (str/last-index-of line "│")]
  {:row row, :from (inc left), :width (- right left 1)}))

(defn ^:private slots-after
 "The slots of the blank rows that follow the line `top` of a box."
 [lines top]
 (->> (range (inc top) (count lines))
  (map (fn [i] [i (nth lines i)]))
  (take-while (fn [[_ l]] (blank-slot? l)))
  (mapv (fn [[i l]] (slot i l)))))

(defn parse-art
 "The art of a landing from its lines `lines` (24 of them): `{:lines :title :options
 :status :footer-from}`, where `:title` is the slot of the title's text row, `:options`
 the vector of the option slots and `:status` the status rows, each `{:row :from :width}`."
 [lines]
 (let [lines (vec lines)
   body (subvec lines 0 (- (count lines) footer-lines))
   tops (vec (keep-indexed #(when (box-top? %2) %1) body))
   [t1 t2 t3] tops]
  {:lines lines,
   :title (slot (inc t1) (nth lines (inc t1))),
   :options (slots-after lines t2),
   :status (slots-after lines t3),
   :footer-from (- (count lines) footer-lines)}))

(defn ^:private put
 "`lines` with `text` written in `slot` (a space, then the text cut with `…` to fit)."
 [lines {:keys [row from width]} text]
 (update lines row pgld/put-text from width (table/fit-cell text width :left)))

(defn frame
 "The 24 lines of the landing of `art` (`parse-art`) with `:title` (the text of the title
 box), `:options` (the labels, one to a slot), `:cursor` (the index of the highlighted
 option) and `:status` (the lines of the status box) written in. What is not given, or
 has no slot, stays as the art has it; an option slot with no option is blank."
 [art {:keys [title options cursor status]}]
 (let [lines (:lines art)
   lines (if title (put lines (:title art) title) lines)
   lines (if options
    (reduce (fn [ls [i s]]
      (put ls
       s
       (when-let [label (nth options i nil)]
        (str (if (= i cursor) "> " "  ") label))))
     lines
     (map-indexed vector (:options art)))
    lines)
   lines (if status
    (reduce (fn [ls [i s]] (put ls s (nth status i "")))
     lines
     (map-indexed vector (:status art)))
    lines)]
  (vec lines)))

;; --- small boxes over a page

(defn box
 "The lines of a rounded box `width` characters wide with `title` in its top border and
 `rows` (strings, cut with `…` to fit) inside, one to a line."
 [title width rows]
 (let [room (- width 6)
   t (let [s (str title)]
    (if (> (txt/display-width s) room)
     (str (txt/take-width s (dec room)) "…")
     s))
   fill (- width 5 (txt/display-width t))]
  (vec (concat [(str "╭─ " t " " (apply str (repeat fill "─")) "╮")]
    (map (fn [r] (str "│" (table/fit-cell r (- width 2) :left) "│"))
     rows)
    [(str "╰" (apply str (repeat (- width 2) "─")) "╯")]))))

(defn overlay
 "`lines` with the lines `box-lines` written over them from row `row`, column `col`."
 [lines row col box-lines]
 (reduce (fn [ls [k text]]
   (update ls (+ row k) pgld/put-text col (txt/display-width text) text))
  (vec lines)
  (map-indexed vector box-lines)))

;; --- the prompt for a name

(defn prompt-initial
 "The state of a prompt for a name with nothing typed."
 []
 {:text "", :error nil})

(defn prompt-step
 "What `input` does in the prompt `state` for a name: `{:state new-state}`,
 `{:chosen name}` for Enter on a name `problem` (a function of the trimmed text that gives
 a message or nil) accepts, `:cancel` for Escape (or the terminal going away) or `:back` for
 Ctrl-X (back from anywhere: the caller's screen returns `:back`). Typing
 stops at `max-chars`, with the error `name too long (N at most)` for a refused character."
 [{:keys [text], :as state} input problem max-chars]
 (cond
  (or (= input KeyType/Escape) (= input KeyType/EOF))
  :cancel

  (kb/back-key? input) :back

  (= input KeyType/Enter)
  (if-let [p (problem (str/trim text))]
   {:state (assoc state :error p)}
   {:chosen (str/trim text)})

  (txt/edits? input text max-chars)
  {:state (assoc state :text (txt/typed text input max-chars) :error nil)}

  ;; at the cap: the character is refused, and the prompt says so
  (txt/at-cap? input text max-chars)
  {:state (assoc state :error (txt/too-long "name" max-chars))}

  :else {:state state}))

(defn prompt-box
 "The lines of the box that asks for a name: `title` on its border, `name: <typed>_` and,
 below it, the error of `state` or the keys that answer it, `width` characters wide."
 [title width {:keys [text error]}]
 (box title
  width
  [(str "name: " (table/tail-text text (- width 11)) "_")
   (or error "enter: accept  esc: cancel")]))

(defn question-box
 "The lines of a box that asks a yes-or-no question about the recipe `n`: `replace \"n\"?`,
 `enter: replace  esc: keep`, `width` characters wide."
 [width n]
 (box "replace"
  width
  [(str "replace \"" (table/tail-text n (- width 16)) "\"?")
   "enter: replace  esc: keep"]))

(defn reset-box
 "The lines of a box that asks whether the file `file-name` that cannot be used is to be
 reset to empty, its old content kept as `<file-name>.corrupt`, `width` characters wide."
 [width file-name]
 (box "reset"
  width
  [(str "reset " file-name " to empty?")
   (str "the old file is kept as " file-name ".corrupt")
   "enter: reset  esc: cancel"]))

(defn unusable-hint
 "The line of a status box that says where the file `path` that cannot be used is and what
 to do: its end (a `…` in front when it is cut) and `r: reset`."
 [path]
 (str (table/tail-text path 56) "  r: reset"))

(defn pick-box
 "The lines of a box `width` wide and `rows` lines tall (its borders included) that shows
 the picker `st` (`baysol.tui.screens.picker`): `title`, what is typed to narrow the
 list, then the names and the status row, the rest blank."
 [title width rows st]
 (let [{:keys [texts]} (picker/layout st (- rows 2) (- width 4))
   texts (vec texts)
   padded (into texts (repeat (- (- rows 2) (count texts)) ""))]
  (box (str title "  find: " (picker/typed-text st 24)) width padded)))
