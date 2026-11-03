;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The solute index: the real index file (names, aliases, targets, bases), the ranking of
;; `search`, custom solutes, the family forms and their templates.

(ns baysol.tui.solute-index-test
 (:require [baysol.tui.solute-index :as si]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]]))

(def ^:private chain
 {:kind :polymer,
  :name "chain-2",
  :units [{:label "A", :formula "C2H4O", :z 24, :slope 36.7, :sigma nil}],
  :z-ends 10,
  :pmv-ends 19.2,
  :sigma-ends nil})

(def ^:private cnb
 {:kind :nonbiological, :name "Tris-like", :formula "C4H11NO3", :z 66, :pmv 90.0})

(defn ^:private names [results] (mapv :name results))

(deftest the-index-file-is-small-and-loads-fast
 (let [f (io/resource "solute_index.edn")]
  (is (< (.length (io/file f)) 1500000)))
 (let [t0 (System/nanoTime)
   _ (si/resolve-builtin "nacl")
   ms (/ (- (System/nanoTime) t0) 1e6)]
  (is (< ms 5000) "first use loads the index; a generous bound, it is far below")))

(deftest aliases-resolve-to-their-target
 (testing "a non-biological alias gives the IUPAC name, in lower case"
  (is (= {:name "nacl",
     :kind :nonbiological,
     :target "sodium chloride",
     :tag "solute",
     :basis nil}
    (si/resolve-builtin "nacl")))
  (is (= "2-amino-2-(hydroxymethyl)propane-1,3-diol"
    (:target (si/resolve-builtin "  TRIS ")))
   "case and outer spaces do not matter")
  (is (= "(2r,3s,4r,5r)-2,3,4,5,6-pentahydroxyhexanal"
    (:target (si/resolve-builtin "Glucose")))))
 (testing "a polymer grade is its own target, with its basis"
  (is (= {:kind :polymer, :tag "polymer", :basis "per 1000 Da", :target "ficoll"}
    (select-keys (si/resolve-builtin "ficoll 400")
     [:kind :tag :basis :target])))
  (is (nil? (:basis (si/resolve-builtin "peg 1450"))))
  (is (= "per monomer unit" (:basis (si/resolve-builtin "pvp"))))
  (is (= "per monomer unit" (:basis (si/resolve-builtin "a8-35")))))
 (testing "a family name is the family, which wins over a grade of the same name"
  (is (= {:kind :polymer-family, :target "peg", :family "peg", :tag "polymer"}
    (select-keys (si/resolve-builtin "PEG") [:kind :target :family :tag])))
  (is (= :polymer-family (:kind (si/resolve-builtin "dextran")))))
 (testing "unknown names"
  (is (nil? (si/resolve-builtin "no such solute")))
  (is (nil? (si/resolve-builtin "")))
  (is (si/builtin-name? "NaCl"))
  (is (not (si/builtin-name? "my own thing")))))

(deftest every-polymer-entry-has-the-right-basis
 (doseq [n ["dextran" "pvp" "pva" "a8-35" "ficoll" "ficoll 70" "polyvinyl alcohol"]
   :let [e (si/resolve-builtin n)]]
  (when (= :polymer (:kind e))
   (is (#{"per monomer unit" "per 1000 Da"} (:basis e)) n)))
 (is (every? #(nil? (:basis (si/resolve-builtin %))) ["poloxamer 407" "peg 550"])))

(deftest search-ranking
 (testing "a blank query finds nothing"
  (is (= [] (si/search "" [])))
  (is (= [] (si/search "   " []))))
 (testing "exact, then starts with, then contains; each by length then alphabet"
  (let [nms (names (si/search "tris" []))
    group (fn [n]
     (cond (= n "tris") 0
      (.startsWith ^String n "tris") 1
      :else 2))
    groups (map group nms)]
   (is (= "tris" (first nms)))
   (is (= (sort groups) groups) "the groups come in order")
   (is (some #{2} groups) "and the last group is not empty")
   (doseq [g [1 2]
     :let [in-group (filter #(= g (group %)) nms)]]
    (is (= in-group (sort-by (juxt count identity) in-group))
     "sorted by length, then alphabet"))))
 (testing "the query is case-insensitive and an alias shows as typed"
  (is (= (si/search "NACL" []) (si/search "nacl" [])))
  (is (= "nacl" (:name (first (si/search "NaCl" []))))))
 (testing "the result count is capped, by default at 200"
  (is (= 200 (count (si/search "a" []))))
  (is (= 7 (count (si/search "a" [] 7))))
  (is (= (take 7 (si/search "a" [])) (si/search "a" [] 7))))
 (testing "the kinds and tags"
  (let [r (si/search "peg" [])]
   (is (= :polymer-family (:kind (first r))))
   (is (every? #{"solute" "polymer" "custom"} (map :tag r)))))
 (testing "nothing matches gibberish"
  (is (= [] (si/search "qzxqzxqzx" [])))))

(deftest custom-solutes-are-searched-too
 (let [r (si/search "chain" [chain cnb])]
  (is (= {:name "chain-2", :kind :custom-polymer, :tag "custom", :target "chain-2"}
    (select-keys (first r) [:name :kind :tag :target])))
  (is (= chain (:entry (first r)))))
 (testing "they rank with the built-in ones by group and length"
  (let [r (si/search "tris" [cnb])
    nms (names r)]
   (is (= "tris" (first nms)))
   (is (= :custom-nonbio (:kind (some #(when (= "Tris-like" (:name %)) %) r))))
   (is (< (.indexOf ^java.util.List nms "tris-cl")
     (.indexOf ^java.util.List nms "Tris-like"))
    "tris-cl (6) before Tris-like (9), both starting with the query")))
 (testing "an exact custom name comes first of its group, any case"
  (is (= "Tris-like" (:name (first (si/search "TRIS-LIKE" [cnb])))))))

(deftest search-is-fast-enough-for-a-keystroke
 (si/search "a" [])
 (let [t0 (System/nanoTime)
   _ (dotimes [_ 20] (si/search "ethan" [chain cnb]))
   ms (/ (- (System/nanoTime) t0) 20e6)]
  (is (< ms 100) (str "one search took " ms " ms"))))

(deftest families
 (is (= "PEG" (:label (si/family "peg"))))
 (is (= 2 (count (:forms (si/family "peg")))))
 (is (nil? (si/family "nope")))
 (testing "every family of the file is found by its id and by a name of the index"
  (doseq [f (si/all-families)]
   (is (= f (si/family (:id f))))
   (doseq [n (:names f)]
    (is (= (:id f) (:family (si/resolve-builtin n))) n)))))

(deftest family-templates
 (let [peg (si/family "peg")
   dex (si/family "dextran")
   brij (si/family "alkyl-ethoxylate")]
  (testing "numbers fill the placeholders, a whole number has no .0"
   (is (= {:arg "PEG n=22"} (si/family-arg peg 0 {"n" "22"})))
   (is (= {:arg "PEG n=22"} (si/family-arg peg 0 {"n" 22.0})))
   (is (= {:arg "PEG n=22.5"} (si/family-arg peg 0 {"n" " 22.5 "})))
   (is (= {:arg "PEG 3350"} (si/family-arg peg 1 {"Mn" "3350"})))
   (is (= {:arg "PEG 1000000"} (si/family-arg peg 1 {"Mn" "1e6"})))
   (is (= {:arg "Brij nC=12 nEO=23"}
     (si/family-arg brij 0 {"nC" "12", "nEO" "23"}))))
  (testing "errors: no number, not positive, below the minimum, unknown form"
   (is (= {:error "n: not a number"} (si/family-arg peg 0 {"n" "twenty"})))
   (is (= {:error "n: not a number"} (si/family-arg peg 0 {})))
   (is (= {:error "n: not a number"} (si/family-arg peg 0 {"n" "NaN"})))
   (is (= {:error "n: must be above 0"} (si/family-arg peg 0 {"n" "0"})))
   (is (= {:error "n: must be above 0"} (si/family-arg peg 0 {"n" "-3"})))
   (is (= {:error "n: at least 2"} (si/family-arg peg 0 {"n" "1"})))
   (is (= {:arg "PEG n=2"} (si/family-arg peg 0 {"n" "2"})))
   (is (= {:error "nEO: not a number"}
     (si/family-arg brij 0 {"nC" "12", "nEO" ""})))
   (is (= {:error "no such form"} (si/family-arg peg 5 {"n" "2"}))))
  (testing "dextran and pullulan: a molar mass below 1000 counts as kDa"
   (is (= {:arg "dextran 40", :note "below 1000 counts as kDa"}
     (si/family-arg dex 1 {"Mn" "40"})))
   (is (= {:arg "dextran 40000"} (si/family-arg dex 1 {"Mn" "40000"})))
   (is (= {:arg "dextran n=250"} (si/family-arg dex 0 {"n" "250"})))
   (is (= "below 1000 counts as kDa"
     (:note (si/family-arg (si/family "glucan") 1 {"Mn" "100"}))))
   (is (nil? (:note (si/family-arg peg 1 {"Mn" "100"})))))))

(deftest polymer-basis-of-a-row
 (is (= "per 1000 Da" (si/polymer-basis "ficoll 70")))
 (is (= "per 1000 Da" (si/polymer-basis " Ficoll 70 ")) "folded like the names")
 (is (nil? (si/polymer-basis "PEG n=22")) "a family string has none")
 (is (nil? (si/polymer-basis "sodium chloride")))
 (is (nil? (si/polymer-basis nil))))
