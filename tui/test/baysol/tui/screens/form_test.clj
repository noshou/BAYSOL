;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The art-driven form page: its geometry is read from the glyphs of the art, no position is
;; typed into the code, and with no values the frame is the art.

(ns baysol.tui.screens.form-test
 (:require [baysol.tui.screens.custom-nonbio-form :as nonbio]
  [baysol.tui.screens.custom-polymer-form :as polymer]
  [baysol.tui.screens.form :as form]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(def ^:private small-art
 "A restyled little page: other columns, other places, the same glyphs."
 ["  ╭─ tiny ───────────╮"
  "  │ a  │ value       │"
  "  ├────┼─────────────┤"
  "  │ b  │             │"
  "  ├────┴─────────────┤"
  "  │ BAYSOL will use  │"
  "  │                  │"
  "  │                  │"
  "  ╰──────────────────╯"
  "  [ footer ]"])

(deftest geometry-from-glyphs
 (let [a (form/parse-art small-art)]
  (is (= "tiny" (:title a)))
  (is (= 2 (:margin a)))
  (is (= [[1] [3] [5 6 7]] (:blocks a)))
  (is (= [[3 7] [8 21]] (form/spans a 3)))
  (is (= 13 (form/cell-width a [3 1])))
  (is (= ["b" ""] (form/texts a 3)))
  (is (= {:heading 5, :rows [6 7], :from 3, :to 21} (:preview a)))
  (is (= [3] (form/labelled a [3])))
  (is (= ["  [ footer ]"] (:footer a)))
  (testing "values go where the glyphs say"
   (let [lines (form/frame a
      {:cells {[3 1] "xyz"},
       :cursor [3 1],
       :note "careful",
       :preview ["one" "two" "three"]})]
    (is (= " >│ b  │ xyz         │" (nth lines 3)) "the cursor in the margin")
    (is (= "  │ b  │ xyz         │"
      (nth (form/frame a {:cells {[3 1] "xyz"}}) 3))
     "no cursor, no mark")
    (is (str/includes? (last (butlast lines)) "careful") "bottom border")
    (is (= "  │ one              │" (nth lines 6)))
    (is (= "  │ two…             │" (nth lines 7)) "more than the room ends in …")))
  (is (thrown? Exception (form/parse-art ["  ╭──╮" "  │  │"])))))

(def ^:private double-art
 "The same little page in the double-line family."
 ["  ╔═ tiny ═══════════╗"
  "  ║ a  ║ value       ║"
  "  ╠════╬═════════════╣"
  "  ║ b  ║             ║"
  "  ╠════╩═════════════╣"
  "  ║ BAYSOL will use  ║"
  "  ║                  ║"
  "  ║                  ║"
  "  ╚══════════════════╝"
  "  [ footer ]"])

(deftest the-two-glyph-families-read-the-same-geometry
 (let [single (form/parse-art small-art)
   dbl (form/parse-art double-art)]
  (is (= "tiny" (:title dbl)))
  (doseq [k [:margin :blocks :preview :footer]]
   (is (= (k single) (k dbl)) k))
  (is (= (:rows single) (:rows dbl)))
  (is (= (form/spans single 3) (form/spans dbl 3)))
  (is (= (:bottom single) (:bottom dbl)))
  (testing "a frame of double-line art with values and a note"
   (let [lines (form/frame dbl
      {:cells {[3 1] "xyz"},
       :cursor [3 1],
       :note "careful",
       :preview ["one"]})]
    (is (= " >║ b  ║ xyz         ║" (nth lines 3)))
    (is (str/includes? (nth lines 8) "careful"))
    (is (= (count (nth double-art 8)) (count (nth lines 8))))
    (is (= "  ║ one              ║" (nth lines 6)))))
  (is (thrown? Exception (form/parse-art ["  ╔══╗" "  ║  ║"])))))

(deftest the-arts-are-the-frame-without-values
 (doseq [a [nonbio/art polymer/art]]
  (is (= (:lines a) (form/frame a {})))
  (is (= 24 (count (form/frame a {}))))
  (is (every? #(<= (count %) 79) (form/frame a {})))))

(deftest long-values-are-cut
 (doseq [[a cell] [[nonbio/art (first (nonbio/field-cells nonbio/art))]
    [polymer/art (polymer/cell-at 0 0)]]]
  (let [long-text (apply str (repeat 200 "W"))
    lines (form/frame a
     {:cells {cell long-text},
      :cursor cell,
      :note long-text,
      :preview [long-text long-text long-text long-text
       long-text
       long-text]})]
   (is (every? #(<= (count %) 79) lines))
   (is (= (count (first lines)) (count (nth lines (first cell))))
    "the box edge stays")
   (is (str/includes? (nth lines (first cell)) "…"))
   (is (every? #(re-find #"[║│]$" %) (map lines (keys (:rows a)))))
   (is (str/includes? (nth lines (:line (:bottom a))) "…"))
   (let [shown (form/edit-text a cell long-text)]
    (is (str/starts-with? shown "…"))
    (is (str/ends-with? shown "_"))
    (is (<= (count shown) (- (form/cell-width a cell) 2)))))))

(deftest preview-wrapping
 (is (= ["a   b"] (form/preview-lines ["a   b"] 10 3))
  "a line that fits is kept as is")
 (is (= ["aaa bbb" "ccc"] (form/preview-lines ["aaa bbb ccc"] 7 3)))
 (is (= ["x" "y…"] (form/preview-lines ["x" "y" "z"] 5 2)))
 (is (= [] (form/preview-lines ["" " "] 5 2)))
 (is (= [] (form/preview-lines ["x"] 5 0)))
 (is (every? #(<= (count %) 6)
   (form/preview-lines [(apply str (repeat 40 "Q"))] 6 4))))

(deftest typing
 (is (= "ab" (form/type-step "a" \b)))
 (is (= "a" (form/type-step "ab" com.googlecode.lanterna.input.KeyType/Backspace)))
 (is (= "" (form/type-step "" com.googlecode.lanterna.input.KeyType/Backspace)))
 (is (= "a" (form/type-step "a" com.googlecode.lanterna.input.KeyType/ArrowUp)))
 (is (= (apply str (repeat form/max-typed "x"))
   (form/type-step (apply str (repeat form/max-typed "x")) \y))))
