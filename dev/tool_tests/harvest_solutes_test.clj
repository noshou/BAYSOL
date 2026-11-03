;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of dev/harvest_solutes.clj on small tables: the basis rules, the pieces of a long
;; name, the names and targets of a kind (aliases kept apart from targets, capitals
;; lower-cased, an alias of a missing target dropped, reserved names left out) and the
;; rendered text read back. The real index file is not touched.

(ns harvest-solutes-test
 (:require [clojure.edn :as edn]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]
  [harvest-solutes :as h]))

(deftest basis-rules
 (is (= "per monomer unit" (h/basis-of "dextran" [])))
 (is (= "per monomer unit"
   (h/basis-of "poly(1-vinylpyrrolidin-2-one)" ["pvp" "povidone"])))
 (is (= "per monomer unit" (h/basis-of "poly(vinyl alcohol)" ["pva"])))
 (is (= "per monomer unit"
   (h/basis-of "poly(acrylic acid) amphipol a8-35 (35% coona)" ["a8-35"])))
 (is (= "per 1000 Da" (h/basis-of "ficoll 70" ["ficoll pm 70"])))
 (testing "no rule, no basis; a word that only contains pva is not PVA"
  (is (nil? (h/basis-of "poloxamer 407" ["poloxamer p407"])))
  (is (nil? (h/basis-of "xpvax" [])))))

(deftest long-names-are-pieces
 (is (= "short" (h/pieces "short")))
 (let [long-name (apply str (repeat 150 "ab"))
   p (h/pieces long-name)]
  (is (vector? p))
  (is (every? #(<= (count %) 70) p))
  (is (= long-name (apply str p)))))

(def ^:private nb-values
 {"Tris" [66 90.6 0.05], "water" [10 18.0 nil], "zinc" [28 1.0 0]})

(def ^:private nb-lookup
 {"TRIS" "Tris", "trizma" "Tris", "H2O" "water", "ghost" "nowhere", "zinc" "zinc"})

(deftest kind-table-shape
 (let [t (h/kind-table nb-lookup nb-values #{})]
  (testing
   "targets sorted and lower case, names sorted, each with its target position"
   (is (= ["tris" "water" "zinc"] (:targets t)))
   (is (= [["h2o" 1] ["tris" 0] ["trizma" 0] ["water" 1] ["zinc" 2]] (:names t))))
  (testing "an alias of a target that is not in the table is dropped and counted"
   (is (= 1 (:dropped t)))
   (is (not-any? #(= "ghost" (first %)) (:names t))))
  (testing "reserved names are left out"
   (is (= [["h2o" 1] ["tris" 0] ["trizma" 0] ["water" 1]]
     (:names (h/kind-table nb-lookup nb-values #{"zinc"})))))))

(deftest index-and-render
 (let [families [{:id "peg", :names ["PEG" "polyethylene glycol"]}]
   idx (h/index nb-lookup
    nb-values
    {"peg 3350" "peg 3350",
     "pegx" "peg 3350",
     "peg" "peg 3350",
     "dextran" "dextran"}
    {"peg 3350" [1 2 3], "dextran" [1 2 3]}
    families)]
  (testing "a name of a family is the family's, not the grade's"
   (is (= [["dextran" 0] ["peg 3350" 1] ["pegx" 1]]
     (get-in idx [:polymers :names])))
   (is (= [["peg" "peg"] ["polyethylene glycol" "peg"]] (:families idx))))
  (is (= {"dextran" "per monomer unit"} (get-in idx [:polymers :basis])))
  (testing "the text reads back as the index, once the pieces are joined"
   (let [text (h/render idx)
     back (edn/read-string text)]
    (is (str/starts-with? text ";; SPDX-License-Identifier"))
    (is (= (get-in idx [:nonbiological :names])
      (get-in back [:nonbiological :names])))
    (is (= (get-in idx [:polymers :targets]) (get-in back [:polymers :targets])))
    (is (= (:families idx) (:families back)))
    (is (= (get-in idx [:polymers :basis]) (get-in back [:polymers :basis])))))))
