;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The polymer form page: its pure state and step, and the page run on a virtual terminal.

(ns baysol.tui.screens.custom-polymer-form-test
 (:require [baysol.tui.custom :as custom]
  [baysol.tui.screens.custom-polymer-form :as form]
  [baysol.tui.screens.form :as page]
  [baysol.tui.support :as support :refer
   [background enter down up keys-of]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private right KeyType/ArrowRight)
(def ^:private left KeyType/ArrowLeft)
(def ^:private bs KeyType/Backspace)


(def ^:private opts {:others ["taken"], :builtin? nil})

(defn ^:private run
 ([inputs] (run custom/blank-polymer inputs))
 ([entry inputs] (reduce form/step (form/initial entry opts) (keys-of inputs))))

(defn ^:private to
 "The keys that go to the cell at table `row` (0 = unit A, 4 = end groups) and column `col`
 from wherever the cursor is: up to the name, back to its column, then down and right."
 [row col]
 (concat (repeat 6 up)
  [left down]
  (repeat row down)
  (repeat (if (= row 4) (max 0 (dec col)) col) right)))

(defn ^:private cell
 "What the page shows in the cell at grid `row` (0 name, 1 unit A, ..., 5 ends) and `col`."
 [st row col]
 (get (:cells (form/view st)) (form/cell-at row col)))

(def ^:private two-units
 "name, unit A and B (formulas, slopes), the ends: H2O for Z, PMV 9."
 (concat [enter "chain" enter]
  (to 0 1)
  [enter "(C2H4O)n" enter right right enter "36.92" enter]
  [down left left enter "C3H6O" enter right right enter "53.13" enter]
  [down down down left left enter "H2O" enter right right enter "9" enter]))

(deftest navigation
 (let [st (run [])]
  (is (= [0 0] [(:row st) (:col st)]))
  (is (= [1 0] (let [s (run [down])] [(:row s) (:col s)])))
  (is (= [1 3] (let [s (run [down right right right])] [(:row s) (:col s)])))
  (testing "the ends have no label cell, the name has one cell"
   (is (= [5 1]
     (let [s (run (concat (repeat 6 down) [left left left]))]
      [(:row s) (:col s)])))
   (is (= [0 0] (let [s (run [right right])] [(:row s) (:col s)]))))
  (testing "no wrapping, and a moved column is remembered across the name"
   (is (= 5 (:row (run (repeat 9 down)))))
   (is (= 0 (:row (run [up]))))
   (let [s (run [down right right down up up down])]
    (is (= [1 2] [(:row s) (:col s)])))
   (let [s (run [down right right right down down down down down])]
    (is (= [5 3] [(:row s) (:col s)])))
   (is (= [:ends-formula]
     (let [s (run (concat (repeat 5 down) [left left]))]
      [(form/field-at (:row s) (:col s))]))))
  (is (= :z-ends (form/field-at 5 2)))
  (is (= [:unit 2 :slope] (form/field-at 3 3)))))

(deftest what-a-blank-form-shows
 (let [st (run [])]
  (is (= "(A)" (cell st 1 0)) "row 1 is always used: its offered label")
  (is (= "(2%)" (cell st 1 4)))
  (is (= "" (cell st 2 0)))
  (is (= "" (cell st 2 4)) "an unused row shows no fallback")
  (is (= "" (cell st 5 4)) "a blank ± of the ends is none")
  (is (= [] (:preview (form/view st))))))

(deftest unit-rows
 (let [st (run (concat (to 1 1) [enter "CH2" enter]))]
  (is (= "B" (cell st 2 0)) "the label offered is taken as soon as the formula is")
  (is (= "B" (get-in st [:entry :units 1 :label])))
  (is (= 8 (get-in st [:entry :units 1 :z])))
  (is (= "(2%)" (cell st 2 4))))
 (is (= "(B)" (cell (run (concat (to 1 3) [enter "5" enter])) 2 0))
  "a used row with no label shows the one offered for its place")
 (testing "a label of the user's own is kept"
  (let [st (run (concat (to 1 0) [enter bs "PO" enter right enter "CH2" enter]))]
   (is (= "PO" (get-in st [:entry :units 1 :label])))))
 (testing "the label offered is a placeholder: editing starts empty"
  (let [st (run (concat (to 0 0) [enter]))]
   (is (= "" (get-in st [:edit :text])))
   (is (= "(A)" (cell (run (to 0 0)) 1 0)) "shown as the placeholder before"))
  (is (= "unitA"
    (get-in (run (concat (to 0 0) [enter "unitA" enter]))
     [:entry :units 0 :label]))))
 (testing "a label typed already is what editing starts from"
  (let [st (run (concat (to 0 0) [enter "PO" enter enter]))]
   (is (= "PO" (get-in st [:edit :text])))))
 (testing "label checks"
  (is (= "one word, please" (:note (run (concat (to 0 0) [enter bs "a b" enter])))))
  (is (= "at most 8 characters"
    (:note (run (concat (to 0 0) [enter "abcdefghi" enter]))))))
 (testing "a formula the parser does not know says why; Z is typed"
  (let [st (run (concat (to 0 1) [enter "Xx" enter]))]
   (is (= "unknown element Xx" (:note st)))
   (is (nil? (get-in st [:entry :units 0 :z])))
   (is (= 5
     (get-in (run (concat (to 0 1) [enter "Xx" enter right enter "5" enter]))
      [:entry :units 0 :z]))))
  (is (= "no charge allowed" (:note (run (concat (to 0 1) [enter "NH4+" enter]))))))
 (testing "a hand-typed Z stays on an unchanged formula, a changed one resets it"
  (let [typed (concat (to 0 1) [enter "C2H4O" enter right enter bs bs "30" enter])
    st (run typed)]
   (is (= 30 (get-in st [:entry :units 0 :z])))
   (is (= 30
     (get-in (run (concat typed [left enter bs bs bs bs bs "C2H4O" enter]))
      [:entry :units 0 :z])))
   (is (= 8
     (get-in (run (concat typed [left enter bs bs bs bs bs "CH2" enter]))
      [:entry :units 0 :z]))))))

(deftest ends
 (let [st (run (concat (to 4 1) [enter "H2O" enter]))]
  (is (= 10 (get-in st [:entry :z-ends])) "computed from the end groups' formula")
  (is (= "10" (cell st 5 2)))
  (is (= "H2O" (cell st 5 1))))
 (is (= 3 (get-in (run (concat (to 4 2) [enter "3" enter])) [:entry :z-ends])))
 (is (= "a whole number, please"
   (:note (run (concat (to 4 2) [enter "1.5" enter])))))
 (is (= "Z must be >= 0" (:note (run (concat (to 4 1) [enter "He 3+" enter])))))
 (is (= "unknown element Xx" (:note (run (concat (to 4 1) [enter "Xx" enter])))))
 (is (= -5.0
   (get-in (run (concat (to 4 3) [enter "-5" enter])) [:entry :pmv-ends])))
 (is (nil? (get-in (run (concat (to 4 4) [enter "0.5" enter enter bs bs bs enter]))
    [:entry :sigma-ends]))))

(deftest preview-text
 (let [st (run two-units)]
  (is (= ["PMV = 9 + 36.92·nA + 53.13·nB" "Z = 10 + 24·nA + 32·nB"
     "n = 10 of each: Z = 570, PMV = 909.5 cm³/mol, σ = 18.19 cm³/mol"
     "n = 100 of each: Z = 5610, PMV = 9014 cm³/mol, σ = 180.28 cm³/mol"]
    (:preview (form/view st)))))
 (testing "what is missing is a ?, and no values are shown"
  (let [st (run (concat (to 0 1) [enter "(C2H4O)n" enter]))]
   (is (= ["PMV = ? + ?·nA" "Z = ? + 24·nA"] (:preview (form/view st))))))
 (testing "a negative slope is a minus"
  (let [st (run (concat (to 0 3) [enter "-5.2" enter]))]
   (is (= "PMV = ? - 5.2·nA" (first (:preview (form/view st))))))))

(deftest accepting
 (let [st (form/step (run two-units) :ctrl-w)]
  (is (= :accepted (:done st)))
  (is (= {:kind :polymer,
     :name "chain",
     :z-ends 10,
     :pmv-ends 9.0,
     :sigma-ends nil,
     :units [{:label "A", :formula "C2H4O", :z 24, :slope 36.92, :sigma nil}
      {:label "B", :formula "C3H6O", :z 32, :slope 53.13, :sigma nil}]}
    (:entry st))))
 (testing "all-blank rows are ignored, wherever they are"
  (let [st (form/step (run (concat [enter "c" enter]
       (to 0 1)
       [enter "CH2" enter right right enter "1" enter]
       (to 2 1)
       [enter "C2H4O" enter right right enter "2" enter]
       (to 4 2)
       [enter "0" enter right enter "0" enter]))
     :ctrl-w)]
   (is (= :accepted (:done st)) (:note st))
   (is (= ["A" "C"] (map :label (get-in st [:entry :units]))) "row 2 is skipped")))
 (testing "a problem is told and the cursor goes to its cell"
  (let [pos (fn [inputs]
     (let [s (form/step (run inputs) :ctrl-w)]
      [(:note s) (:row s) (:col s)]))]
   (is (= ["name needed" 0 0] (pos [])))
   (is (= ["Z must be > 0" 1 2] (pos [enter "x" enter])) "unit A with nothing")
   (is (= ["slope needed" 1 3]
     (pos (concat [enter "x" enter] (to 0 1) [enter "CH2" enter]))))
   (is (= ["end groups needed" 5 2]
     (pos (concat [enter "x" enter]
       (to 0 1)
       [enter "CH2" enter right right enter "1"
        enter]))))
   (is (= ["end groups needed" 5 3]
     (pos (concat [enter "x" enter]
       (to 0 1)
       [enter "CH2" enter right right enter "1"
        enter]
       (to 4 2)
       [enter "0" enter]))))
   (testing "a half-filled row 3 is a problem at ITS row"
    (is (= ["Z must be > 0" 3 2]
      (pos (concat [enter "x" enter]
        (to 0 1)
        [enter "CH2" enter right right enter "1"
         enter]
        (to 4 2)
        [enter "0" enter right enter "0" enter]
        (to 2 3)
        [enter "5" enter])))))
   (testing "a duplicate label"
    (is (= ["unit label used" 2 0]
      (pos (concat [enter "x" enter]
        (to 0 1)
        [enter "CH2" enter right right enter "1"
         enter]
        (to 1 0)
        [enter bs "A" enter right enter "CH2" enter right right
         enter "1"
         enter]
        (to 4 2)
        [enter "0" enter right enter "0" enter])))))
   (is (= "name in use"
     (first (pos (concat [enter "taken" enter] (drop 3 two-units))))))))
 (testing "± below 0 and a typed ± are kept"
  (let [st (form/step (run (concat (to 0 1)
       [enter "CH2" enter right right enter "1"
        enter right enter "0.25" enter]))
     :ctrl-w)]
   (is (= 0.25 (get-in st [:entry :units 0 :sigma]))))))

(deftest undo
 (let [entry (run two-units)
   base (:entry (form/step entry :ctrl-w))
   st (run base (concat (to 0 3) [enter bs bs bs "7" enter :ctrl-u]))]
  (is (= 36.92 (get-in st [:entry :units 0 :slope]))
   "back to what it was when opened")
  (let [s2 (run base (concat (to 0 1) [enter bs bs bs bs bs "CH2" enter :ctrl-u]))]
   (is (= "C2H4O" (get-in s2 [:entry :units 0 :formula])))
   (is (= 24 (get-in s2 [:entry :units 0 :z])) "with its Z"))
  (let [s3 (run base (concat (to 4 1) [enter "H2O" enter :ctrl-u]))]
   (is (= "" (:ends-formula s3))))
  (is (= "chain" (get-in (run base [enter "x" enter :ctrl-u]) [:entry :name])))))

(def ^:private chain-4
 (nth (:solutes (edn/read-string
    (slurp
     (io/file ".." "test" "fixtures" "buffer" "custom-solutes.edn"))))
  3))

(deftest an-existing-four-unit-polymer
 (let [st (run chain-4 [])]
  (is (= 4 (count (get-in st [:entry :units]))))
  (is (= :accepted (:done (form/step st :ctrl-w))))
  (is (= chain-4 (:entry (form/step st :ctrl-w)))
   "untouched, it comes back as it was")
  (testing "unit D is editable, and clearing a row removes it"
   (let [edited (run chain-4
      (concat (to 3 3) [enter bs bs bs bs bs bs bs bs "99" enter]))]
    (is (= 99.0 (get-in (form/step edited :ctrl-w) [:entry :units 3 :slope]))))
   (let [clear-d (mapcat (fn [col]
       (concat (to 3 col) [enter] (repeat 20 bs) [enter]))
      (range 5))
     done (form/step (run chain-4 clear-d) :ctrl-w)]
    (is (= :accepted (:done done)) (:note done))
    (is (= (take 3 (:units chain-4)) (get-in done [:entry :units])))))
  (testing "four rows fit in the preview"
   (let [lines (page/frame form/art (form/view st))]
    (is (every? #(<= (count %) 79) lines))))))

(deftest long-values
 (let [st (run (concat [enter (apply str (repeat 60 "N")) enter]
     (to 0 0)
     [enter "ABCDEFGH" enter right enter
      "C1000H1000N1000O1000S1000P1000Cl100" enter]
     (to 1 0)
     [enter "IJKLMNOP" enter right enter "CH2" enter]
     (to 2 0)
     [enter "QRSTUVWX" enter right enter "CH2" enter]
     (to 3 0)
     [enter "YZabcdef" enter right enter "CH2" enter]
     (to 3 3)
     [enter "123456789.123456789" enter]))
   lines (page/frame form/art (form/view st))]
  (is (every? #(<= (count %) 79) lines))
  (is (str/includes? (nth lines 1) "…"))
  (is (every? #(<= (count %) 79)
    (page/frame form/art
     (assoc (form/view st)
      :note
      (apply str (repeat 90 "n"))))))
  (let [paragraphs (:preview (form/view st))
    shown (page/preview-lines paragraphs 72 4)]
   (is (<= (count shown) 4))
   (is (every? #(<= (count %) 72) shown)))))


(defn ^:private show!-keys
 [entry & inputs]
 (let [vs (support/virtual-screen)]
  (apply support/feed! vs inputs)
  (let [r (form/show! (:screen vs) background entry {:others [], :builtin? nil})]
   [r (support/screen-text vs)])))

(deftest the-page-on-a-terminal
 (is (nil? (first (show!-keys custom/blank-polymer KeyType/Escape))))
 (is (= :quit (first (show!-keys custom/blank-polymer KeyType/EOF))))
 (let [[r text] (apply show!-keys
    custom/blank-polymer
    (concat two-units [KeyType/EOF]))]
  (is (= :quit r))
  (is (str/includes? text "PMV = 9 + 36.92·nA + 53.13·nB"))
  (is (str/includes? text "n = 100 of each: Z = 5610"))
  (is (re-find #"> ║ end groups" text)))
 (let [[r _] (apply show!-keys custom/blank-polymer (concat two-units [:ctrl-w]))]
  (is (= "chain" (:name r)))
  (is (= 2 (count (:units r)))))
 (let [[_ text] (show!-keys custom/blank-polymer :ctrl-w KeyType/EOF)]
  (is (str/includes? text "╚═ name needed"))))

(deftest the-footer-shows-ctrl-x-and-it-goes-back
 (let [[r text] (show!-keys custom/blank-polymer :ctrl-x)]
  (is (= :back r) "^x returns to the table")
  (is (str/includes? text "menu: ^x") "the legend is in the footer")
  (is (str/includes? text "cancel: esc"))))
