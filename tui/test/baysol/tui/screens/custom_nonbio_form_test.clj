;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The non-biological form page: its pure state and step, and the page run on a virtual
;; terminal.

(ns baysol.tui.screens.custom-nonbio-form-test
 (:require [baysol.tui.custom :as custom]
  [baysol.tui.screens.custom-nonbio-form :as form]
  [baysol.tui.screens.form :as page]
  [baysol.tui.solute-index :as solute-index]
  [baysol.tui.support :as support :refer
   [background enter down up keys-of]]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private bs KeyType/Backspace)


(defn ^:private run
 "The state after `inputs` from a blank form (or from `entry`)."
 ([inputs] (run custom/blank-nonbiological inputs))
 ([entry inputs]
  (reduce form/step
   (form/initial entry
    {:fallback 3.044643,
     :others ["taken"],
     :builtin?
     solute-index/builtin-name?})
   (keys-of inputs))))

(defn ^:private typed-all
 [& {:keys [sigma]}]
 (concat [enter "NACE" enter down enter "C7H13NO3S" enter down down enter "118.4"
   enter
   down enter]
  (when sigma [sigma])
  [enter]))

(deftest z-follows-the-formula
 (let [st (run [enter "NACE" enter down enter "C7H13NO3S" enter])]
  (is (= 102 (get-in st [:entry :z])) "computed as soon as the formula is taken")
  (is (nil? (:note st)))
  (testing "shown in the Z cell, ready to keep"
   (is (= "102"
     (get (:cells (form/view st)) (nth (form/field-cells form/art) 2))))))
 (testing "a hand-typed Z stays while the formula does not change"
  (let [st (run [down enter "NaCl" enter down enter bs bs "99" enter up enter bs bs
      bs bs
      "NaCl" enter])]
   (is (= 99 (get-in st [:entry :z])))))
 (testing "a changed formula gets the computed one"
  (let [st (run [down enter "NaCl" enter down enter bs bs "99" enter up enter bs bs
      bs bs
      "H2O" enter])]
   (is (= 10 (get-in st [:entry :z])))))
 (testing "a formula not understood says why and leaves Z to be typed"
  (let [st (run [down enter "Xx" enter])]
   (is (= "unknown element Xx" (:note st)))
   (is (nil? (get-in st [:entry :z])))
   (is (= 77
     (get-in (run [down enter "Xx" enter down enter "77" enter])
      [:entry :z]))))))

(deftest cells-and-fallback
 (let [st (run [])
   shown #(get (:cells (form/view %)) (nth (form/field-cells form/art) 4))]
  (is (= "(3.04)" (shown st)) "a blank ± shows the setting")
  (is (= "4" (shown (run [down down down down enter "4" enter]))))
  (is (= "" (get (:cells (form/view st)) (first (form/field-cells form/art)))))
  (is (= [] (:preview (form/view st))) "nothing known: nothing previewed")))

(deftest preview-text
 (let [st (run [enter "NACE" enter down enter "C7H13NO3S" enter down down enter
     "118.4"
     enter])]
  (is (= ["7 C + 13 H + 1 N + 3 O + 1 S = 102 electrons, charge 0"
     "Z = 102   PMV = 118.4 cm³/mol   σ = 3.04 cm³/mol (fallback)"]
    (:preview (form/view st)))))
 (let [st (run [down down down down enter "4" enter])]
  (is (= ["σ = 4 cm³/mol"] (:preview (form/view st)))))
 (let [st (run [down down down enter "-5" enter])]
  (is (= ["PMV = -5 cm³/mol   σ = 3.04 cm³/mol (fallback)"]
    (:preview (form/view st))))))

(deftest keys-and-edits
 (let [st (run [down down])]
  (is (= 2 (:cursor st)))
  (is (= 4 (:cursor (run [down down down down down down]))) "no wrapping")
  (is (= 0 (:cursor (run [up])))))
 (testing "Esc stops the edit of the cell, then cancels the form"
  (let [st (run [enter "abc" KeyType/Escape])]
   (is (nil? (:edit st)))
   (is (= "" (get-in st [:entry :name])))
   (is (nil? (:done st)))
   (is (= :cancelled (:done (form/step st KeyType/Escape))))))
 (testing "an error keeps the cell open"
  (let [st (run [down down enter "x" enter])]
   (is (= "a whole number, please" (:note st)))
   (is (some? (:edit st)))))
 (testing "Backspace; a blank cell clears"
  (is (= "ab" (get-in (run [enter "abc" KeyType/Backspace enter]) [:entry :name])))
  (is (nil? (get-in (run [down down down enter "3" enter enter KeyType/Backspace
       enter])
     [:entry :pmv])))))

(deftest undo-goes-back-to-the-form-as-opened
 (let [entry {:kind :nonbiological,
    :name "NACE",
    :formula "NaCl",
    :z 28,
    :pmv 1.5,
    :sigma 2.0}
   st (run entry
    [enter KeyType/Backspace "X" enter down enter "H2O" enter :ctrl-u])]
  (is (= "NaCl" (get-in st [:entry :formula])))
  (is (= 28 (get-in st [:entry :z])) "the formula's Z goes back with it")
  (is (= "NACX" (get-in st [:entry :name])) "only the cell under the cursor")
  (is (= "NACE" (get-in (run entry [enter "X" enter up :ctrl-u]) [:entry :name])))
  (is (= 2.0
    (get-in (run entry [down down down down enter "9" enter :ctrl-u])
     [:entry :sigma])))))

(deftest accepting
 (let [ok (run (typed-all))]
  (is (= nil (:done ok)))
  (let [done (form/step ok :ctrl-w)]
   (is (= :accepted (:done done)))
   (is (= {:kind :nonbiological,
      :name "NACE",
      :formula "C7H13NO3S",
      :z 102,
      :pmv 118.4,
      :sigma nil}
     (:entry done)))))
 (testing "a problem is the note and the cursor goes to its field"
  (let [st (form/step (run [enter "x" enter]) :ctrl-w)]
   (is (nil? (:done st)))
   (is (= "Z must be > 0" (:note st)))
   (is (= 2 (:cursor st))))
  (is (= ["formula unknown" 1]
    (let [st (form/step (run [enter "x" enter down enter "Xx" enter]) :ctrl-w)]
     [(:note st) (:cursor st)])))
  (is (= "PMV needed"
    (:note (form/step (run [enter "x" enter down enter "NaCl" enter])
      :ctrl-w))))
  (is (= "name needed" (:note (form/step (run []) :ctrl-w))))
  (is (= 0 (:cursor (form/step (run [down down down]) :ctrl-w)))))
 (testing "name in use, built-in"
  (let [with-name (fn [n]
     (form/step (run [enter n enter down enter "NaCl" enter down down
        enter "1" enter])
      :ctrl-w))]
   (is (= "name in use" (:note (with-name "Taken"))) "case-insensitive")
   (is (= "name is built-in" (:note (with-name "peg"))))
   (is (= :accepted (:done (with-name "fresh")))))))

(deftest long-values-in-the-page
 (let [st (run [enter (apply str (repeat 40 "N")) enter down enter
     "C100H100N100O100S100P100Cl100Br100" enter])
   lines (page/frame form/art (form/view st))]
  (is (every? #(<= (count %) 79) lines))
  (is (str/includes? (nth lines 3) "…") "the name is cut with …")))


(defn ^:private show!-keys
 [entry & inputs]
 (let [vs (support/virtual-screen)]
  (apply support/feed! vs inputs)
  (let [r (form/show! (:screen vs)
     background
     entry
     {:fallback 3.044643, :others [], :builtin? nil})]
   [r (support/screen-text vs)])))

(deftest the-page-on-a-terminal
 (testing "Esc cancels"
  (is (nil? (first (show!-keys custom/blank-nonbiological KeyType/Escape)))))
 (testing "the terminal going away is :quit"
  (is (= :quit (first (show!-keys custom/blank-nonbiological KeyType/EOF)))))
 (testing "typing, a frame mid-flow and accepting"
  (let [[r text] (show!-keys custom/blank-nonbiological
     enter
     "NACE"
     enter
     down
     enter
     "C7H13NO3S"
     enter
     down
     down
     enter
     "118.4"
     enter
     down
     enter
     KeyType/EOF)]
   (is (= :quit r))
   (is (str/includes? text "NACE"))
   (is (str/includes? text
     "7 C + 13 H + 1 N + 3 O + 1 S = 102 electrons, charge 0"))
   (is (str/includes? text "σ = 3.04 cm³/mol (fallback)"))
   (is (re-find #"> ║ ±" text) "the cursor in the margin"))
  (let [[r _] (show!-keys custom/blank-nonbiological
     enter
     "NACE"
     enter
     down
     enter
     "C7H13NO3S"
     enter
     down
     down
     enter
     "118.4"
     enter
     :ctrl-w)]
   (is (= "NACE" (:name r)))
   (is (= 102 (:z r)))))
 (testing "a problem is told on the bottom border"
  (let [[_ text] (show!-keys custom/blank-nonbiological :ctrl-w KeyType/EOF)]
   (is (str/includes? text "╚═ name needed")))))

(deftest the-footer-shows-ctrl-x-and-it-goes-back
 (let [[r text] (show!-keys custom/blank-nonbiological :ctrl-x)]
  (is (= :back r) "^x returns to the table")
  (is (str/includes? text "menu: ^x") "the legend is in the footer")
  (is (str/includes? text "cancel: esc"))))
