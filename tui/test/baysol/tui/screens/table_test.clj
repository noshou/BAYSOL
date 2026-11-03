;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The table generator: on a synthetic single-line rounded art (a top border with the
;; counter, a 5-line footer), on a synthetic double-line art with no `move:` text, and on
;; the three live double-line arts (buffer: 5-line footer, window 16; custom solutes and
;; recipes: 3-line footer, window 18): that the columns come from the art, how cells are
;; fitted, how the window moves, and what the header and the footer say.

(ns baysol.tui.screens.table-test
 (:require [baysol.tui.draft :as draft]
  [baysol.tui.text :as txt]
  [baysol.tui.screens.custom-solutes-menu :as custom-menu]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.screens.table :as table]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private art
 "The single-line rounded family, as a synthetic art (a top border with the counter, a
 5-line footer with `move:` on its second line)."
 (table/parse-art
  ["   ╭─ solutes [   /   ] ──────┬──────────┬───────────┬────────────────────────╮"
   "   │          solute          │   [mM]   │   ±[mM]   │         params         │"
   "   ├──────────────────────────┼──────────┼───────────┼────────────────────────┤"
   "   │                          │          │           │                        │"
   "   ╰──────────────────────────┴──────────┴───────────┴────────────────────────╯"
   "   ╭╮ ╭╮╷ ╷╭╮╭╮╷  ╭──────────╮╭───────────────────────────────────────────────╮"
   "   ├┴╮├┤╰┬╯╰╮│││  │ quit: esc││ edit: ⏎  move:     save: ^w  undo: ^u  rmv: ^r│"
   "   ╰─╯╵╵ ╵ ╰╯╰╯╰╴ │ menu: ^x ││ add nonbio: ^n  add polymer: ^p               │"
   "                  │          ││ add protein: ^f  add nucleotide: ^e           │"
   "                  ╰──────────╯╰───────────────────────────────────────────────╯"]))

(def ^:private old-art
 "An art in the old double-line family: no top border, a 3-line footer, the counter in
 the footer's first line, the arrows over the `^u` of its second (there is no `move:`)."
 (table/parse-art
  ["   ║  name  ║  n  ║"
   "   ╠════════╬═════╣"
   "   ║        ║     ║"
   "   ╚════════╩═════╝"
   "   quit: esc  [   /   ]                add: ^p  rmv: ^r"
   "   menu: ^x              undo: ^u"
   "   save: ^w"]))

(defn ^:private rows
 [n]
 (vec (for [i (range n)]
   {:cells [(str "solute " (inc i)) "10" "0.5" "n/a"],
    :aligns [:left :right :right :center]})))

(defn ^:private lines-of
 [n cursor offset]
 (table/frame art (rows n) cursor offset))

(deftest cells
 (is (= " tris     " (table/fit-cell "tris" 10 :left)))
 (is (= "*tris     " (table/fit-cell "tris" 10 :left \*)))
 (is (= "      200 " (table/fit-cell "200" 10 :right)))
 (is (= "   n/a    " (table/fit-cell "n/a" 10 :center)))
 (testing "text that does not fit loses its end and gets an ellipsis, by characters"
  (is (= " abcdef… " (table/fit-cell "abcdefghij" 9 :left)))
  (is (= " δρ₁δρ₂…" (subs (table/fit-cell "δρ₁δρ₂δρ₃δρ₄" 9 :left) 0 8)))
  (is (every? #(= 10 (txt/display-width %))
    [(table/fit-cell "N-(2-hydroxyethyl)piperazine" 10 :left)
     (table/fit-cell "ϕ′…" 10 :center)
     (table/fit-cell "" 10 :right)])))
 (is (= "…ghij" (table/tail-text "abcdefghij" 5)))
 (is (= "abc" (table/tail-text "abc" 5))))

(deftest the-art
 (testing "the columns are read off the art"
  (is (= [3 30 41 53 78] (:bounds art)))
  (is (= [[4 30] [31 41] [42 53] [54 78]] (:spans art)))
  (is (= "│" (:glyph art))))
 (testing "the header block ends at the first separator rule, the footer is 4 lines"
  (is (= 3 (count (:head art))))
  (is (= 3 (table/body-top art)))
  (is (= (:separator art) (peek (:head art))))
  (is (= 5 (count (:footer art)))))
 (testing "the window is what the page leaves"
  (is (= 15 (table/window art))))
 (testing "the counter is in the top border, the arrows after `move:`"
  (is (= 0 (:line (:counter art))))
  (is (= 6 (:line (:arrows art))) "the second footer line, under the logo's top")
  (is (str/starts-with? (subs (nth (:footer art) 1) (:at (:arrows art))) "  "))
  (is (= (+ 6 (str/index-of (nth (:footer art) 1) "move:")) (:at (:arrows art))))))

(deftest the-old-double-line-art
 (testing "the art is read the same way"
  (is (= "║" (:glyph old-art)))
  (is (= [3 12 18] (:bounds old-art)))
  (is (= [[4 12] [13 18]] (:spans old-art)))
  (is (= 2 (count (:head old-art))) "no top border: the header block is 2 lines")
  (is (= 18 (table/window old-art)))
  (is (= {:line 4, :cur 15, :tot 19} (:counter old-art)))
  (is (= {:line 4, :at (str/index-of (nth (:footer old-art) 1) "^u")}
    (:arrows old-art))
   "no `move:`: the cells over the ^u"))
 (testing "a frame draws with the old glyphs, 24 lines"
  (let [{:keys [lines]}
    (table/frame old-art [{:cells ["a" "1"]} {:cells ["b" "2"]}] 0 0)
    arrows-at (:at (:arrows old-art))]
   (is (= 24 (count lines)))
   (is (str/starts-with? (nth lines 2) " > ║ a"))
   (is (str/starts-with? (nth lines 3) "   ║ b"))
   (is (= (:bottom old-art) (nth lines 20)))
   (is (str/includes? (nth lines 21) "[  1/2  ]"))
   (is (= "↓ " (subs (nth lines 21) arrows-at (+ arrows-at 2))))))
 (testing "the frame with no rows is the art, the counter filled and rmv gone"
  (let [{:keys [lines]} (table/frame old-art [] 0 0)]
   (is (= (vec (concat (:head old-art)
       (repeat 18 (:template old-art))
       [(:bottom old-art)]))
     (subvec lines 0 21)))
   (is (str/includes? (nth lines 21) "[  0/0  ]"))
   (is (not (str/includes? (nth lines 21) "rmv:")))
   (is (str/includes? (nth lines 21) "add: ^p")))))

(deftest the-window-moves-one-row-at-a-time
 ;; the real art's window is 15 rows (24 less a 3-line header block, the bottom border and
 ;; a 5-line footer); these used to be 18 with 22 rows
 (testing "no scrolling while the cursor is in the first 15 rows"
  (is (= 0 (table/viewport 0 0 22 15)))
  (is (= 0 (table/viewport 0 14 22 15))))
 (testing "the 16th row scrolls by one, and so on to the end"
  (is (= 1 (table/viewport 0 15 22 15)))
  (is (= 2 (table/viewport 1 16 22 15)))
  (is (= 7 (table/viewport 6 21 22 15))))
 (testing "going back up scrolls one row when the cursor passes the top"
  (is (= 3 (table/viewport 4 3 22 15)))
  (is (= 4 (table/viewport 4 10 22 15))))
 (testing "never past the end, never below 0, fewer rows than the window"
  (is (= 7 (table/viewport 9 21 22 15)))
  (is (= 0 (table/viewport 5 2 10 15)))
  (is (= 0 (table/viewport 3 0 0 15)))))

(deftest every-frame-is-the-page
 (doseq [n [0 1 2 5 15 16 22 120]
   cursor [0 1 14 15 21 119]]
  (let [{:keys [lines offset]} (lines-of n cursor 0)]
   (is (= 24 (count lines)) (str n " rows, cursor " cursor))
   (is (every? #(<= (txt/display-width %) 79) lines))
   (is (<= 0 offset))
   (is (= (:header art) (second lines)))
   (is (= (:separator art) (nth lines 2)))
   (is (= (:bottom art) (nth lines 18)))))
 (testing "the frame with no rows is the art, line for line"
  (let [{:keys [lines]} (table/frame art [] 0 0 {:hide-legends ["rmv"]})
    blank (fn [line] (str/replace line #"\[  0/0  \]" "[   /   ]"))
    expected (vec (concat (:head art)
      (repeat 15 (:template art))
      [(:bottom art)]
      (map #(str/replace % #"rmv: \^r" "       ")
       (:footer art))))]
   (is (= (mapv #(str/replace % #"\s+$" "") expected)
     (mapv #(str/replace (blank %) #"\s+$" "") lines)))))
 (testing "the footer is the art's, with the counter and the arrows written in"
  (let [{:keys [lines]} (lines-of 0 0 0)]
   (is (str/includes? (nth lines 0) "solutes [  0/0  ]"))
   (is (= (:head art) (assoc (vec (take 3 lines)) 0 (first (:head art)))))
   (is (not (str/includes? (nth lines 19) "rmv:")) "nothing to remove: no rmv")
   (is (= (map txt/display-width (:footer art))
     (map txt/display-width (drop 19 lines)))))
  (let [{:keys [lines]} (lines-of 1 0 0)]
   (is (= (drop 19 lines) (:footer art)) "one row: the footer is the art's")))
 (testing
  "rmv is there for any number of rows from one, add until the table is full"
  (doseq [n [1 2 15 16 998 999]
    :let [text (str/join "\n" (drop 19 (:lines (lines-of n 0 0))))]]
   (is (str/includes? text "rmv:") (str n " rows"))
   (is (str/includes? text "undo:") (str n " rows"))
   (is (= (< n 999) (str/includes? text "add nonbio:")) (str n " rows"))
   (is (= (< n 999) (str/includes? text "add polymer:")) (str n " rows"))
   (is (= (< n 999) (str/includes? text "add protein:")) (str n " rows"))
   (is (= (< n 999) (str/includes? text "add nucleotide:")) (str n " rows")))))

(deftest arrows-and-the-counter
 (let [footer #(nth (:lines (lines-of %1 %2 0)) 20)
   counter #(nth (:lines (lines-of %1 %2 0)) 0)
   arrows (fn [line]
    (set (cond-> []
      (str/includes? line "↓") (conj :down)
      (str/includes? line "↑") (conj :up))))]
  (testing "no arrows for no row or one row"
   (is (= #{} (arrows (footer 0 0))))
   (is (= #{} (arrows (footer 1 0)))))
  (testing "two rows: down from the first, up from the second"
   (is (= #{:down} (arrows (footer 2 0))))
   (is (= #{:up} (arrows (footer 2 1)))))
  (testing "three rows: both in the middle"
   (is (= #{:down :up} (arrows (footer 3 1)))))
  (testing "many rows: ends have one arrow, the rest two"
   (is (= #{:down} (arrows (footer 22 0))))
   (is (= #{:down :up} (arrows (footer 22 18))))
   (is (= #{:up} (arrows (footer 22 21)))))
  (testing "the arrows are the two cells right after `move: `"
   (let [line (footer 3 1)
     k (+ 6 (str/index-of line "move:"))]
    (is (= "↓↑" (subs line k (+ k 2))))
    (is (= (txt/display-width (second (:footer art))) (txt/display-width line)))))
  (testing
   "the counter, in the top border, says the place of the cursor and the rows"
   (is (str/includes? (counter 22 18) "[ 19/22 ]"))
   (is (str/includes? (counter 5 0) "[  1/5  ]"))
   (is (= (txt/display-width (first (:head art)))
     (txt/display-width (counter 5 0)))))))

(deftest scrolling-shows-the-rows-around-the-cursor
 (let [body #(subvec (:lines %) 3 18)
   text #(str/join "\n" %)]
  (testing "15 rows fill the table, the cursor on the 15th shows the first"
   (let [f (lines-of 22 14 0)]
    (is (= 0 (:offset f)))
    (is (str/includes? (text (body f)) "solute 1 "))
    (is (str/includes? (text (body f)) "solute 15"))))
  (testing
   "on the 16th the first is gone and the 16th is the last row, with the cursor"
   (let [f (lines-of 22 15 0)]
    (is (= 1 (:offset f)))
    (is (not (str/includes? (text (body f)) "solute 1 ")))
    (is (str/starts-with? (last (body f)) " > │ solute 16"))))
  (testing "a table shorter than the window is filled up with blank rows"
   (let [f (lines-of 3 0 0)]
    (is (= 12 (count (filter #(= (:template art) %) (body f)))))))))

(deftest marks-and-notes
 (let [row {:cells ["tris" "10" "0.5" "n/a"], :mark \*}
   {:keys [lines]} (table/frame art
    [row (assoc row :mark \-) row]
    1
    0
    {:note "name needed"})]
  (is (str/starts-with? (nth lines 3) "   │*tris "))
  (is (str/starts-with? (nth lines 4) " > │-tris "))
  (testing "a note goes in the bottom border and keeps its joints"
   (is (str/includes? (nth lines 18) " name needed "))
   (is (= (txt/display-width (:bottom art)) (txt/display-width (nth lines 18))))
   (is (= (str/index-of (:bottom art) "┴") (str/index-of (nth lines 18) "┴")))))
 (testing "an empty table says so on its first row"
  (let [{:keys [lines]} (table/frame art [] 0 0 {:empty-hint "none yet"})]
   (is (str/includes? (nth lines 3) "none yet")))))

(deftest the-table-stops-at-999
 (let [footer #(str/join "\n" (drop 19 (:lines (lines-of %1 %2 0))))
   counter #(first (:lines (lines-of %1 %2 0)))]
  (testing "the counter has room for 999, and add is there until the table is full"
   (is (str/includes? (counter 998 997) "[998/998]"))
   (is (str/includes? (footer 998 997) "add nonbio:"))
   (is (str/includes? (counter 999 998) "[999/999]"))
   (doseq [legend ["add nonbio:" "add polymer:" "add protein:" "add nucleotide:"]]
    (is (not (str/includes? (footer 999 998) legend)) legend))
   (is (str/includes? (footer 999 998) "rmv:"))
   (is (str/includes? (footer 999 998) "undo:"))
   (is (str/includes? (footer 999 998) "save:"))
   (is (str/includes? (footer 999 998) "edit:")))
  (testing "the footer keeps its length when the add legends go"
   (is (= (map txt/display-width (drop 19 (:lines (lines-of 998 0 0))))
     (map txt/display-width (drop 19 (:lines (lines-of 999 0 0)))))))))

(deftest right-and-centred-text-may-use-the-edge-spaces
 (is (= "36.73n+19.24" (table/fit-cell "36.73n+19.24" 12 :right)))
 (is (= " 5.1n+19.24" (table/fit-cell "5.1n+19.24" 11 :right)))
 (is (= "36.73n+19.2…" (table/fit-cell "36.73n+19.245" 12 :right)))
 (is (= "abcdefghij" (table/fit-cell "abcdefghij" 10 :center)))
 (is (= " abcdefg… " (table/fit-cell "abcdefghijk" 10 :left))
  "left text keeps its space for the mark"))

(def ^:private all-arts
 [["solutes" solutes-menu/art] ["custom" custom-menu/art]
  ["recipes" (table/parse-art (pgld/load-ascii "page" "recipes"))]])

(defn ^:private bottom-at
 "The page line of the bottom border of the art `a`: the header block and the window."
 [a]
 (+ (table/body-top a) (table/window a)))

(defn ^:private footer-of
 "The footer lines of the page `lines` of the art `a`."
 [a lines]
 (vec (drop (inc (bottom-at a)) lines)))

(deftest the-live-arts
 (doseq [[page page-art] all-arts
   :let [footer (count (:footer page-art))
    window (- 24 (table/body-top page-art) 1 footer)]]
  (testing page
   (is (= "║" (:glyph page-art)) "the live tables are double-line")
   (is (= window (table/window page-art)) "derived from the art")
   (is (= (if (= page "solutes") [2 5 16] [2 3 18])
     [(table/body-top page-art) footer window]))
   (is (some? (:counter page-art)))
   (is (some? (:arrows page-art)))
   (let [{:keys [lines]} (table/frame page-art [] 0 0)]
    (is (= 24 (count lines)))
    (is (every? #(<= (txt/display-width %) 79) lines))
    (is (= (:head page-art) (vec (take (table/body-top page-art) lines))))
    (is (str/includes? (str/join lines) "[  0/0  ]"))
    (is (= (repeat window (:template page-art))
      (subvec lines (table/body-top page-art) (bottom-at page-art))))
    (is (= (:bottom page-art) (nth lines (bottom-at page-art))))
    (is (not (str/includes? (str/join (footer-of page-art lines)) "rmv:")))
    (is (= (map txt/display-width (:footer page-art))
      (map txt/display-width (footer-of page-art lines)))))
   (let [lines (:lines (table/frame page-art (vec (repeat 5 {:cells ["a"]})) 2 0))
     line (first (filter #(str/includes? % "move:") (footer-of page-art lines)))
     k (+ 6 (str/index-of line "move:"))]
    (is (= "↓↑" (subs line k (+ k 2))) "the arrows are right after `move: `"))
   (let [many (vec (repeat 120 {:cells ["a"]}))]
    (is (= 1 (:offset (table/frame page-art many window 0)))
     "scrolling starts when the cursor goes to the row after the window")
    (is (= 0 (:offset (table/frame page-art many (dec window) 0))))))))

(deftest the-buffer-art-legends
 (let [bart solutes-menu/art
   rows-of (fn [n] (vec (repeat n {:cells ["a" "1" "0.1" "n/a"]})))
   footer #(str/join "\n"
    (footer-of bart
     (:lines (table/frame bart (rows-of %) 0 0))))]
  (testing "four add legends, save, edit, undo, rmv with a row"
   (doseq [l ["add nonbio:" "add polymer:" "add protein:" "add nucleotide:" "^n"
      "^p" "^f"
      "^e"
      "save: ^w" "edit:" "undo:" "rmv:" "quit:" "menu:"]]
    (is (str/includes? (footer 3) l) l)))
  (testing "no rmv with no row, the add legends stay"
   (is (not (str/includes? (footer 0) "rmv:")))
   (is (str/includes? (footer 0) "add nucleotide:")))
  (testing "all four add legends go at 999 rows, the others stay"
   (let [f (footer 999)]
    (doseq [l ["add nonbio:" "add polymer:" "add protein:" "add nucleotide:"]]
     (is (not (str/includes? f l)) l))
    (is (every? #(str/includes? f %)
      ["rmv:" "undo:" "save:" "quit:" "menu:" "edit:"]))
    (is (str/includes? (str/join (:lines (table/frame bart (rows-of 999) 0 0)))
      "[  1/999]"))))
  (testing "the footer keeps its length when the legends go"
   (is (= (map txt/display-width
      (footer-of bart (:lines (table/frame bart (rows-of 3) 0 0))))
     (map txt/display-width
      (footer-of bart (:lines (table/frame bart (rows-of 999) 0 0)))))))))

(deftest the-custom-art-legends-and-note
 (let [cart custom-menu/art
   crows (fn [n] (vec (repeat n {:cells ["a" "NaCl" "28" "1" "(3.04)"]})))
   footer
   #(str/join "\n" (footer-of cart (:lines (table/frame cart (crows %) 0 0))))]
  (testing "all legends with a row, no rmv with none"
   (is (every? #(str/includes? (footer 3) %) ["add nonbio:" "add polymer:" "rmv:"]))
   (is (not (str/includes? (footer 0) "rmv:")))
   (is (str/includes? (footer 0) "add polymer:")))
  (testing "both add legends go at 999 rows, the other legends stay"
   (let [f (footer 999)]
    (is (not (str/includes? f "add nonbio:")))
    (is (not (str/includes? f "add polymer:")))
    (is (every? #(str/includes? f %) ["rmv:" "undo:" "save:" "quit:" "menu:"]))))
  (testing "a long note is cut on its stretch, a short one whole, no joint moves"
   (let [bottom #(nth (:lines (table/frame cart (crows 1) 0 0 {:note %}))
      (bottom-at cart))
     long-note "row 3: formula unknown"]
    (is (str/includes? (bottom long-note) "row 3: formula u…"))
    (is (str/includes? (bottom "saved") " saved "))
    (is (= (txt/display-width (:bottom cart))
      (txt/display-width (bottom long-note))))
    (doseq [j ["╦" "╩" "╣"]
      t [long-note "saved"]]
     (is (= (str/index-of (:bottom cart) j) (str/index-of (bottom t) j)))
     (is (= (count (re-seq (re-pattern j) (:bottom cart)))
       (count (re-seq (re-pattern j) (bottom t))))))))))

(defn ^:private legend-test-art
 "A synthetic single-line art with two legends on one footer line, for the blanking by
 label."
 []
 (table/parse-art
  ["   ╭─ x [   /   ] ┬────╮"
   "   │      a       │ b  │"
   "   ├──────────────┼────┤"
   "   │              │    │"
   "   ╰──────────────┴────╯"
   "   │ add: ^p   rmv: ^r  │"
   "   │ undo: ^z   save: ^w│"]))

(deftest legends-on-one-line-are-blanked-one-by-one
 (let [tiny (legend-test-art)
   page (fn [n opts]
    (:lines (table/frame tiny (vec (repeat n {:cells ["a"]})) 0 0 opts)))]
  (is (= "   │ add: ^p   rmv: ^r  │" (nth (page 2 {}) 22)))
  (is (= "   │ add: ^p            │" (nth (page 0 {}) 22)) "rmv goes, add stays")
  (is (= "   │           rmv: ^r  │" (nth (page 2 {:hide-legends ["add"]}) 22)))
  (is (= "   │ undo: ^z           │" (nth (page 2 {:hide-legends ["save"]}) 23))
   "the key before the border does not eat it")))

(deftest border-notes-are-never-cut
 ;; every message of a save (a row number in front of it) on all three pages and on the
 ;; single-line synthetic art, for one, two and three-digit row numbers: the note must be
 ;; on the border whole, the border keeps its length and its corners (and its `╦` joint
 ;; to the footer's box). A new message of a save belongs in this list.
 (let [messages ["name needed" "name in use" "formula unknown" "Z must be > 0"
    "PMV needed"
    "± not below 0" "mM must be > 0" "±mM needed"]
   fixed ["saved" "could not save!" "buffer.edn unusable!"
    "custom-solutes.edn unusable!"
    "recipes.edn unusable!"]
   arts (conj all-arts ["single-line" art])]
  (doseq [[page page-art] arts
    text (concat
     fixed
     (for [m messages n [1 9 10 99 100 999]] (str "row " n ": " m)))
    :let [line (nth (:lines
       (table/frame page-art [{:cells ["a"]}] 0 0 {:note text}))
      (bottom-at page-art))
     bottom (:bottom page-art)]]
   (is (or (str/includes? line text)
     (some #(str/includes? line (str (subs text 0 %) "…"))
      (range 1 (count text))))
    (str page ": " text " is lost: " line))
   (is (or (not (< (count text) 10)) (str/includes? line text))
    "a short note is whole")
   (is (= (txt/display-width bottom) (txt/display-width line))
    (str page ": the border changed length for " text))
   (is (and (= (first (str/trim bottom)) (first (str/trim line)))
     (= (last bottom) (last line))
     (= (str/index-of bottom "╦") (str/index-of line "╦")))
    (str page ": a corner or the joint moved for " text)))))

(deftest wrapping-text
 (let [w table/wrap-text]
  (testing "breaks at the spaces"
   (is (= ["aaa bbb" "ccc"] (w "aaa bbb ccc" 7)))
   (is (= ["aaa" "bbb" "ccc"] (w "aaa bbb ccc" 6)))
   (is (= ["aaa bbb ccc"] (w "aaa bbb ccc" 11)) "an exact fit stays on one line")
   (is (= ["aaa bbb ccc"] (w "aaa bbb ccc" 80))))
  (testing "white space collapses, the ends are trimmed"
   (is (= ["a b" "c"] (w "  a   b\t c  " 3))))
  (testing "a word longer than the width is broken hard"
   (is (= ["abcd" "efgh" "ij"] (w "abcdefghij" 4)))
   (is (= ["abcd" "efgh"] (w "abcdefgh" 4)))
   (is (= ["xx" "abcd" "efgh" "ij k"] (w "xx abcdefghij k" 4)))
   (is (= ["abc" "de" "f"] (w "abcde f" 3))))
  (testing "width 1 and below"
   (is (= ["a" "b" "c"] (w "a b c" 1)))
   (is (= ["a" "b" "c"] (w "abc" 0))))
  (testing "blank text is one empty line"
   (is (= [""] (w "" 10)))
   (is (= [""] (w "   " 10)))
   (is (= [""] (w nil 10))))
  (testing "by code points: no line longer than the width"
   (is (= ["ångström" "ünït"] (w "ångström ünït" 8)))
   (is (= ["😀😀" "😀😀" "😀"] (w "😀😀😀😀😀" 4)) "an emoji is two cells")
   (let [lines (w "α-glucosidase inhibitor 😀😀😀😀 supercalifragilistic" 9)]
    (is (every? #(<= (txt/display-width %) 9) lines))
    (is (= "α-glucosidaseinhibitor😀😀😀😀supercalifragilistic"
      (str/replace (str/join lines) " " "")))))))

(deftest the-recipes-art-legends
 (let [rart (second (last all-arts))
   rrows (fn [n] (vec (repeat n {:cells ["a" "3" "none"]})))
   footer (fn [n & [opts]]
    (str/join "\n"
     (footer-of
      rart
      (:lines (table/frame rart (rrows n) 0 0 (or opts {}))))))]
  (testing "all legends with a row, no rmv with none"
   (is (every? #(str/includes? (footer 3) %)
     ["edit:" "new recipe:" "undo:" "rmv:"]))
   (is (not (str/includes? (footer 0) "rmv:")))
   (is (str/includes? (footer 0) "new recipe:")))
  (testing
   "new recipe goes at 999 rows, the others stay, the footer keeps its length"
   (let [f (footer 999)]
    (is (not (str/includes? f "new recipe:")))
    (is (every? #(str/includes? f %) ["edit:" "rmv:" "undo:" "save:"])))
   (is (= (map txt/display-width
      (footer-of rart (:lines (table/frame rart (rrows 3) 0 0))))
     (map txt/display-width
      (footer-of rart (:lines (table/frame rart (rrows 999) 0 0)))))))
  (testing "a screen may blank any legend of the art by its label"
   (let [f (footer 3 {:hide-legends ["edit" "save"]})]
    (is (not (str/includes? f "edit:")))
    (is (not (str/includes? f "save:")))
    (is (every? #(str/includes? f %)
      ["new recipe:" "undo:" "rmv:" "quit:" "menu:"])))
   (is (= (map txt/display-width
      (footer-of rart (:lines (table/frame rart (rrows 3) 0 0))))
     (map txt/display-width
      (footer-of
       rart
       (:lines
        (table/frame rart (rrows 3) 0 0 {:hide-legends ["edit"]})))))
    "the lines keep their length")
   (is (= (footer-of rart (:lines (table/frame rart (rrows 3) 0 0)))
     (footer-of rart
      (:lines (table/frame rart (rrows 3) 0 0 {:hide-legends []}))))
    "none given, none hidden"))))

(deftest arrows-after-a-move-legend-at-the-end-of-its-line
 ;; the owner's buffer art puts `move:` last on its footer line, with nothing after it: the
 ;; arrow cells are then past the end of the art line
 (let [lines ["   ║ a  ║ b  ║"
    "   ╠════╬════╣"
    "   ║    ║    ║"
    "   ╚════╩════╝"
    "   ╔╗ quit: esc ┃ edit:  ⏎ ┃ move:"
    "   ╠╩ menu: ^x  ┃ add:   ^n ┃ undo: ^u"
    "   ╚═ save: ^w  ┃ rmv:   ^r ┃ [   /   ]"]
   art* (table/parse-art lines)
   rows* (fn [n] (vec (repeat n {:cells ["x" "y"]})))
   move-line (fn [n cursor]
    (->> (:lines (table/frame art* (rows* n) cursor 0))
     (filter #(str/includes? % "move:"))
     first))]
  (is (some? (:arrows art*)) "the cells are found past the end of the line")
  (testing "both, one or none, as the rows say"
   (is (str/includes? (move-line 3 1) "move: ↓↑"))
   (is (str/includes? (move-line 3 0) "move: ↓ "))
   (is (str/includes? (move-line 3 2) "move:  ↑"))
   (is (not (re-find #"move: *[↓↑]" (move-line 1 0))))
   (is (not (re-find #"move: *[↓↑]" (move-line 0 0)))))
  (testing "the live buffer art finds its cells and draws them"
   (let [live solutes-menu/art
     rows2 (vec (repeat 5 {:cells ["a" "1" "2" "n/a"]}))
     text (str/join "\n" (:lines (table/frame live rows2 2 0)))]
    (is (some? (:arrows live)))
    (is (str/includes? text "move: ↓↑"))))))

(deftest shared-keys-of-an-editable-table
 (let [st {:s (draft/initial [:a :b :c]), :cursor 1}]
  (testing "the arrows move the cursor, held on the rows"
   (is (= 2 (:cursor (table/step st KeyType/ArrowDown))))
   (is (= 2 (:cursor (table/step (assoc st :cursor 2) KeyType/ArrowDown))))
   (is (= 0 (:cursor (table/step st KeyType/ArrowUp))))
   (is (= 0 (:cursor (table/step (assoc st :cursor 0) KeyType/ArrowUp)))))
  (testing "^r marks the row to go, ^u brings it back"
   (let [r (table/step st :ctrl-r)]
    (is (= [nil \- nil] (mapv draft/mark (get-in r [:s :rows]))))
    (is (= [nil nil nil]
      (mapv draft/mark (get-in (table/step r :ctrl-u) [:s :rows]))))))
  (testing "no row, no removal; other keys are not handled"
   (is (nil? (table/step {:s (draft/initial []), :cursor 0} :ctrl-r)))
   (is (nil? (table/step {:s (draft/initial []), :cursor 0} :ctrl-u)))
   (is (nil? (table/step st :ctrl-w))))))

(deftest saving-the-rows
 (let [st {:s (-> (draft/initial [:a :b])
     (draft/remove-row 0)),
    :cursor 1,
    :hint "h"}
   seen (atom nil)
   ok (table/save-rows st nil #(reset! seen %))]
  (is (= [:b] @seen) "what is saved is what stays")
  (is (= "saved" (:note ok)))
  (is (= [nil] (mapv draft/mark (get-in ok [:s :rows]))))
  (is (= 0 (:cursor ok)) "the cursor is held on the rows left")
  (is (not (contains? ok :hint)))
  (let [bad (table/save-rows st nil (fn [_] (throw (Exception. "no"))))]
   (is (= "could not save!" (:note bad)))
   (is (= (:s st) (:s bad)))
   (is (= "h" (:hint bad))))
  (let [told (table/save-rows st [1 "name needed"] #(reset! seen :never))]
   (is (= "row 2: name needed" (:note told)))
   (is (= 1 (:cursor told)))
   (is (not= :never @seen)))))

(deftest border-notes-never-cover-junctions
 (let [junction? #(contains? #{\╩ \╦ \╣ \╠ \┴ \┬ \┤ \├} %)
   check (fn [page page-art text]
    (let [bottom (:bottom page-art)
      line (nth
       (:lines
        (table/frame page-art [{:cells ["a"]}] 0 0 {:note text}))
       (bottom-at page-art))]
     (is (= (txt/display-width bottom) (txt/display-width line)) page)
     (is (= (keep-indexed #(when (junction? %2) [%1 %2]) bottom)
       (keep-indexed #(when (junction? %2) [%1 %2]) line))
      (str page ": a junction was cut for " text))
     (is (= (last bottom) (last line)) page)))
   texts (concat ["saved" "could not save!" "recipes.edn unusable!"
     "custom-solutes.edn unusable!"]
    (for [m ["name needed" "formula unknown" "mM must be > 0"
       "±mM needed"]
      n [1 99 999]]
     (str "row " n ": " m)))]
  (doseq [[page page-art] (conj all-arts ["single-line" art])
    text texts]
   (check page page-art text))
  (testing "synthetic art: shifts to the longest stretch, truncates when none fits"
   (let [syn (table/parse-art ["   ║ a║  b   ║c║" "   ╠══╬══════╬═╣"
       "   ║  ║      ║ ║"
       "   ╚══╩══════╩═╝" "   x" "   x" "   x"])
     note (fn [t]
      (nth (:lines (table/frame syn [] 0 0 {:note t})) (bottom-at syn)))]
    (is (= "   ╚══╩ abcd ╩═╝" (note "abcd")) "the middle stretch, the joints stay")
    (is (= "   ╚══╩ abc… ╩═╝" (note "abcdefghijklmnop"))
     "cut when no stretch is long")))))
