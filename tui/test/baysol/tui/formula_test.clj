;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The formula parser: electrons of atoms, groups, hydrates, charges and the polymer unit.

(ns baysol.tui.formula-test
 (:require [baysol.tui.formula :as formula]
  [clojure.test :refer [deftest is testing]]))

(deftest atoms-and-groups
 (is (= {:z 28, :charge 0} (formula/parse-formula "NaCl")))
 (is (= {:z 10, :charge 0} (formula/parse-formula "H2O")))
 (is (= {:z 10, :charge 0} (formula/parse-formula "D2O")) "D counts as hydrogen")
 (is (= {:z 38, :charge 0} (formula/parse-formula "Ca(OH)2")))
 (is (= {:z 196, :charge 0} (formula/parse-formula "Fe2(SO4)3")))
 (is (= {:z 196, :charge 0} (formula/parse-formula " Fe2 ( SO4 ) 3 "))
  "spaces ignored")
 (is (= (formula/parse-formula "Ca(OH)2") (formula/parse-formula "Ca[OH]2")))
 (testing "nested groups multiply"
  (is (= {:z (+ 6 (* 2 (+ 8 (* 3 1)))), :charge 0}
    (formula/parse-formula "C(O(H)3)2")))))

(deftest hydrates-and-adducts
 (is (= {:z 127, :charge 0} (formula/parse-formula "CuSO4·5H2O")))
 (is (= (formula/parse-formula "CuSO4·5H2O") (formula/parse-formula "CuSO4.5H2O")))
 (is (= (formula/parse-formula "CuSO4·5H2O") (formula/parse-formula "CuSO4*5H2O")))
 (is (= {:z 20, :charge 0} (formula/parse-formula "2H2O"))))

(deftest charges
 (is (= {:z 10, :charge 1} (formula/parse-formula "NH4+")))
 (is (= {:z 50, :charge -2} (formula/parse-formula "SO4 2-")))
 (is (= {:z 50, :charge -2} (formula/parse-formula "SO4^2-")))
 (is (= {:z 10, :charge 3} (formula/parse-formula "Al3+")))
 (is (= {:z 18, :charge -1} (formula/parse-formula "Cl-")))
 (is (= {:z 18, :charge -1} (formula/parse-formula "Cl -")))
 (is (= {:z 10, :charge -2} (formula/parse-formula "O2-")))
 (is (= {:z (+ 26 (* 6 13) 3), :charge -3} (formula/parse-formula "[Fe(CN)6]3-"))))

(deftest errors
 (is (= {:error "unknown element Xx"} (formula/parse-formula "Xx")))
 (is (= {:error "unknown element Q"} (formula/parse-formula "NaQ")))
 (is (:error (formula/parse-formula "")))
 (is (:error (formula/parse-formula "   ")))
 (is (:error (formula/parse-formula "Ca(OH")))
 (is (:error (formula/parse-formula "CaOH)2")))
 (is (:error (formula/parse-formula "Na0")))
 (is (:error (formula/parse-formula "na")))
 (is (:error (formula/parse-formula "NaCl·")))
 (is (every? #(<= (count (:error (formula/parse-formula %))) 22)
   ["Xx" "" "Ca(OH" "CaOH)2" "Na0" "na" "NaCl·" "N%" "Zzz"])))

(deftest all-elements
 (is (= 118 (formula/atomic-number "Og")))
 (is (= 1 (formula/atomic-number "H")))
 (is (= 118 (count (distinct (vals (dissoc formula/atomic-number "D")))))))

(deftest polymer-units
 (is (= {:unit "C2H4O", :z 24} (formula/parse-unit "C2H4O")))
 (is (= {:unit "C2H4O", :z 24} (formula/parse-unit "(C2H4O)n")))
 (is (= {:unit "C2H4O", :z 24} (formula/parse-unit " ( C2H4O ) n ")))
 (is (= "C2H4O" (formula/strip-unit "(C2H4O)n")))
 (is (= "Ca(OH)2" (formula/strip-unit "Ca(OH)2"))
  "only a wrapper with n is stripped")
 (is (= {:error "no charge allowed"} (formula/parse-unit "C2H4O+")))
 (is (:error (formula/parse-unit "(Xx)n"))))

(deftest element-counts-and-breakdown
 (testing "Hill order, counts summed over parts and groups"
  (is (= {:counts [["C" 7] ["H" 13] ["N" 1] ["O" 3] ["S" 1]], :charge 0, :z 102}
    (formula/element-counts "C7H13NO3S")))
  (is (= [["C" 1] ["H" 1] ["Br" 1] ["Cl" 1]]
    (:counts (formula/element-counts "HCClBr")))
   "C and H first, then alphabetical")
  (is (= [["Ca" 1] ["H" 2] ["O" 2]] (:counts (formula/element-counts "Ca(OH)2")))
   "no carbon: all alphabetical")
  (is (= [["Cu" 1] ["H" 10] ["O" 9] ["S" 1]]
    (:counts (formula/element-counts "CuSO4·5H2O"))))
  (is (= [["H" 4] ["O" 2]] (:counts (formula/element-counts "2H2O")))))
 (testing "the counts add up to the electrons, whatever the charge"
  (doseq [f ["NaCl" "Ca(OH)2" "Fe2(SO4)3" "NH4+" "SO4 2-" "CuSO4·5H2O" "D2O"]
    :let [r (formula/element-counts f)]]
   (is (= (:z (formula/parse-formula f)) (:z r)) f)
   (is
    (= (+ (:charge r) (:z r))
     (reduce + (map (fn [[s n]] (* n (formula/atomic-number s))) (:counts r)))))))
 (testing "errors are the parser's"
  (is (= (formula/parse-formula "Xx") (formula/element-counts "Xx")))
  (is (nil? (formula/breakdown "Xx")))
  (is (nil? (formula/breakdown ""))))
 (testing "the text of the sum"
  (is (= "7 C + 13 H + 1 N + 3 O + 1 S = 102 electrons, charge 0"
    (formula/breakdown "C7H13NO3S")))
  (is (= "4 O + 1 S = 50 electrons, charge -2" (formula/breakdown "SO4 2-")))
  (is (= "4 H + 1 N = 10 electrons, charge +1" (formula/breakdown "NH4+")))))
