;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The custom solutes state (drafts, marks, problems) and their global file.

(ns baysol.tui.custom-test
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.custom :as custom]
  [baysol.tui.custom-store :as store]
  [baysol.tui.solute-index :as solute-index]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(def ^:private nonbio
 {:kind :nonbiological,
  :name "NACE",
  :formula "C7H13NO3S",
  :z 100,
  :pmv 118.4,
  :sigma 4.0})

(def ^:private polymer
 {:kind :polymer,
  :name "chain",
  :z-ends 10,
  :pmv-ends 19.24,
  :sigma-ends nil,
  :units [{:label "A", :formula "C2H4O", :z 24, :slope 36.73, :sigma 0.37}]})

(def ^:private unit-b
 {:label "B", :formula "C3H6O", :z 32, :slope 53.1, :sigma nil})

(def ^:private fixture-file
 "The frozen schema, written by the Julia side's owner: test/fixtures/buffer."
 (io/file ".." "test" "fixtures" "buffer" "custom-solutes.edn"))

(def ^:private buffer-fixture
 (io/file ".." "test" "fixtures" "buffer" "buffer.edn"))

(defn ^:private read-edn [f] (edn/read-string (slurp f)))

(deftest rows-and-marks
 (let [s (custom/initial [nonbio])]
  (is (nil? (custom/mark (first (:rows s)))))
  (is (not (custom/dirty? s)))
  (testing "a new row is a draft with the blank of its kind"
   (let [s (custom/add-row s :polymer)]
    (is (= :polymer (:kind (custom/value (second (:rows s))))))
    (is (= \* (custom/mark (second (:rows s)))))
    (is (custom/dirty? s))
    (is (= 1 (count (:rows (custom/undo s 1))))
     "undo of a never-saved row drops it")
    (is (= 1 (count (:rows (custom/remove-row s 1)))) "so does remove")))
  (testing "an edit is a draft and setting it back removes the draft"
   (let [e (custom/set-field s 0 :pmv 120.0)]
    (is (= \* (custom/mark (first (:rows e)))))
    (is (= 120.0 (:pmv (custom/value (first (:rows e))))))
    (is (nil? (:draft (first (:rows (custom/set-field e 0 :pmv 118.4))))))
    (is (nil? (:draft (first (:rows (custom/undo e 0))))))))
  (testing "remove marks a saved row, undo brings it back, commit drops it"
   (let [r (custom/remove-row s 0)]
    (is (= \- (custom/mark (first (:rows r)))))
    (is (= [] (custom/to-save r)))
    (is (nil? (custom/mark (first (:rows (custom/undo r 0))))))
    (is (= [] (:rows (custom/commit r))))))))

(deftest problems-at-save
 (let [p (fn [e] (custom/problems (custom/initial [e])))]
  (is (nil? (p nonbio)))
  (is (nil? (p polymer)))
  (is (nil? (p (assoc nonbio :pmv -5.0 :sigma nil)))
   "negative PMV and blank ± are fine")
  (is (= [0 "name needed"] (p (assoc nonbio :name " "))))
  (is (= [0 "formula unknown"] (p (assoc nonbio :formula "Xx" :z nil))))
  (is (nil? (p (assoc nonbio :formula "Xx")))
   "a formula not understood is fine with a Z")
  (is (= [0 "Z must be > 0"] (p (assoc nonbio :z 0))))
  (is (= [0 "Z must be > 0"] (p (assoc nonbio :formula "" :z nil))))
  (is (= [0 "PMV needed"] (p (assoc nonbio :pmv nil))))
  (is (= [0 "± not below 0"] (p (assoc nonbio :sigma -1.0))))
  (testing "names are unique, case-insensitively, among the rows that stay"
   (let [s (custom/initial [nonbio (assoc polymer :name "nace")])]
    (is (= [1 "name in use"] (custom/problems s)))
    (is (nil? (custom/problems (custom/remove-row s 1))))))
  (testing "a built-in name is refused only when a predicate is given"
   (let [s (custom/initial [(assoc nonbio :name "NaCl")])
     builtin? (fn [n] (= "nacl" (str/lower-case n)))]
    (is (nil? (custom/problems s)))
    (is (nil? (custom/problems s nil)))
    (is (= [0 "name is built-in"] (custom/problems s builtin?)))
    (is (<= (count "name is built-in") 22))
    (is (nil? (custom/problems (custom/initial [nonbio]) builtin?)))
    (is (= [0 "name is built-in"]
      (custom/problems (custom/initial [(assoc nonbio :name "peg")])
       solute-index/builtin-name?)))))))

(deftest polymer-units
 (let [s (custom/add-row (custom/initial []) :polymer)
   e (fn [s] (custom/value (first (:rows s))))]
  (testing "a blank polymer has one blank unit and no end groups"
   (is (= [custom/blank-unit] (:units (e s))))
   (is (nil? (:z-ends (e s))))
   (is (nil? (:pmv-ends (e s)))))
  (testing "unit fields are addressed as [:unit i k]"
   (let [t (custom/set-field s 0 [:unit 0 :formula] "C2H4O")]
    (is (= "C2H4O" (custom/get-field (e t) [:unit 0 :formula])))
    (is (= "C2H4O" (:formula (first (:units (e t))))))
    (is (= 5 (custom/get-field (e (custom/set-field t 0 :z-ends 5)) :z-ends)))))
  (testing "units are added up to 4 and removed down to 1"
   (let [s4 (-> s
      (custom/add-unit 0)
      (custom/add-unit 0)
      (custom/add-unit 0))]
    (is (= 4 (count (:units (e s4)))))
    (is (= 4 (count (:units (e (custom/add-unit s4 0))))))
    (is (= 1 (count (:units (e (custom/remove-unit s 0 0))))))
    (let [t (custom/set-field s4 0 [:unit 2 :label] "C")
      r (custom/remove-unit t 0 1)]
     (is (= 3 (count (:units (e r)))))
     (is (= "C" (:label (second (:units (e r))))) "the units after it move up"))))
  (testing "labels offered"
   (is (= ["A" "B" "C" "D" ""] (map custom/default-label (range 5)))))))

(deftest polymer-problems
 (let [p (fn [e] (custom/problems (custom/initial [e])))
   two (update polymer :units conj unit-b)
   unit (fn [k v] (assoc-in polymer [:units 0 k] v))]
  (is (nil? (p polymer)))
  (is (nil? (p two)))
  (is (= [0 "name needed"] (p (assoc polymer :name ""))))
  (is (= [0 "label needed"] (p (unit :label " "))))
  (is (= [0 "formula unknown"]
    (p (-> (unit :formula "Xx")
      (assoc-in [:units 0 :z] nil)))))
  (is (= [0 "Z must be > 0"] (p (unit :z 0))))
  (is (= [0 "slope needed"] (p (unit :slope nil))))
  (is (= [0 "± not below 0"] (p (unit :sigma -0.1))))
  (is (= [0 "slope needed"] (p (assoc-in two [:units 1 :slope] nil))) "any unit")
  (is (= [0 "unit label used"] (p (assoc-in two [:units 1 :label] "a")))
   "case-insensitive")
  (is (= [0 "end groups needed"] (p (assoc polymer :z-ends nil))))
  (is (= [0 "end groups needed"] (p (assoc polymer :pmv-ends nil))))
  (is (nil? (p (assoc polymer :pmv-ends -2.0))) "negative is fine")
  (is (= [0 "ends ± not below 0"] (p (assoc polymer :sigma-ends -1.0))))
  (is (= [0 "unit needed"] (p (assoc polymer :units []))))
  (is (every? #(<= (count %) 22)
    ["label needed" "formula unknown" "Z must be > 0" "slope needed"
     "± not below 0"
     "unit label used" "end groups needed" "ends ± not below 0"
     "unit needed"]))
  (testing "a blank new polymer is told first by its name, then its unit"
   (let [s (custom/set-field (custom/add-row (custom/initial []) :polymer)
      0
      :name
      "x")]
    (is (= [0 "label needed"] (custom/problems s)))))))

(deftest snapshots-equal-the-buffer-fixture
 (let [entries (:solutes (read-edn fixture-file))
   rows (:solutes (read-edn buffer-fixture))
   by-name (fn [n] (first (filter #(= n (:name %)) entries)))
   cut #(dissoc % :name :mM :sigma-mM)]
  (testing "non-biological"
   (doseq [r (filter #(= :custom-nonbio (:kind %)) rows)]
    (is (= (cut r) (cut (custom/snapshot (by-name (:custom r))))))))
  (testing "polymers, counts in unit order"
   (let [rs (filter #(= :custom-polymer (:kind %)) rows)]
    (is (= 2 (count rs)))
    (doseq [r rs]
     (is (= (cut r)
       (cut (custom/snapshot (by-name (:custom r)) (:counts r))))))))
  (testing "integer counts become doubles; the wrong number of counts throws"
   (is (= [3.0] (:counts (custom/snapshot polymer [3]))))
   (is (thrown? Exception (custom/snapshot polymer [1 2])))
   (is (thrown? Exception (custom/snapshot polymer nil))))))

(deftest the-fixture-round-trips
 (support/with-data-folder
  [root (support/temp-root)]
  (let [fixture (:solutes (read-edn fixture-file))]
   (io/copy fixture-file (store/custom-file root))
   (let [read1 (store/read-solutes root)]
    (is (= fixture read1))
    (is (= 4 (count read1)))
    (store/write-solutes! root read1)
    (is (= read1 (store/read-solutes root)))))))

(deftest polymers-of-the-wrong-shape-are-unusable
 (support/with-data-folder
  [root (support/temp-root)]
  (let [old {:kind :polymer,
     :name "o",
     :formula "C2H4O",
     :z 24,
     :pmv-intercept 1.0,
     :pmv-slope 2.0,
     :sigma nil}
    unit {:label "A", :formula "C2H4O", :z 1, :slope 1.0, :sigma nil}
    chain (fn [units] (assoc polymer :units units))]
   (doseq [bad [old (chain []) (chain (vec (repeat 5 unit))) (chain (list unit))
      (chain [1])]]
    (spit (store/custom-file root) (pr-str {:solutes [bad]}))
    (is (thrown? Exception (store/read-solutes root)) (pr-str bad))
    (is (thrown? Exception (store/write-solutes! root [nonbio]))))
   (io/delete-file (store/custom-file root))
   (is (thrown? Exception (store/write-solutes! root [old])))
   (is (thrown? Exception (store/write-solutes! root [(chain [])])))
   (is (not (.exists (store/custom-file root))))
   (store/write-solutes! root [(chain (vec (repeat 4 unit)))])
   (is (= 4 (count (:units (first (store/read-solutes root)))))))))

(deftest the-file-is-global-and-atomic
 (support/with-data-folder
  [root (support/temp-root)]
  (testing "no file is no entries"
   (is (= [] (store/read-solutes root)))
   (spit (store/custom-file root) "")
   (is (= [] (store/read-solutes root)))
   (spit (store/custom-file root) ";; only a comment\n")
   (is (= [] (store/read-solutes root))))
  (testing "write then read back, next to settings.edn in the app folder"
   (store/write-solutes! @app/app-dir [nonbio polymer])
   (is (= [nonbio polymer] (store/read-solutes root)))
   (is (= (io/file root "custom-solutes.edn") (store/custom-file @app/app-dir)))
   (is (not (.exists (io/file root "custom-solutes.edn.tmp")))))
  (testing "other keys are kept"
   (spit (store/custom-file root) "{:solutes [] :note \"x\"}")
   (store/write-solutes! root [nonbio])
   (is (= "x" (:note (read-string (slurp (store/custom-file root)))))))
  (testing "unusable files throw and are not written over"
   (doseq [bad ["{:solutes" "[1 2]" "{:solutes {}}" "{:solutes [1]}"]]
    (spit (store/custom-file root) bad)
    (is (thrown? Exception (store/read-solutes root)))
    (is (thrown? Exception (store/write-solutes! root [nonbio])))
    (is (= bad (slurp (store/custom-file root))))))
  (testing "999 entries are fine, 1000 unusable"
   (io/delete-file (store/custom-file root))
   (store/write-solutes! root (vec (repeat 999 nonbio)))
   (is (= 999 (count (store/read-solutes root))))
   (is (thrown? Exception (store/write-solutes! root (vec (repeat 1000 nonbio)))))
   (spit (store/custom-file root) (pr-str {:solutes (vec (repeat 1000 nonbio))}))
   (is (thrown? Exception (store/read-solutes root))))))

(deftest typed-cells
 (is (= "118.4" (custom/format-number 118.4)))
 (is (= "" (custom/format-number nil)))
 (is (= "3.04" (custom/format-rounded 3.044643)))
 (is (= "3" (custom/format-rounded 3.0001)))
 (is (nil? (custom/format-rounded nil)))
 (is (= {:value 24} (custom/parse-field :z " 24 ")))
 (is (:error (custom/parse-field :z "0")))
 (is (:error (custom/parse-field :z "2.5")))
 (is (= {:value -3.5} (custom/parse-field :pmv "-3.5")))
 (is (= {:value 19.24} (custom/parse-field :pmv-ends "19.24")))
 (is (= {:value -1.5} (custom/parse-field :slope "-1.5")))
 (is (:error (custom/parse-field :slope "x")))
 (is (= {:value 10} (custom/parse-field :z-ends "10")))
 (is (= {:value 0} (custom/parse-field :z-ends "0")))
 (is (:error (custom/parse-field :z-ends "1.5")))
 (is (= {:value "A"} (custom/parse-field :label " A ")))
 (is (:error (custom/parse-field :label "")))
 (is (:error (custom/parse-field :label "a b")))
 (is (:error (custom/parse-field :label "123456789")))
 (is (= {:value nil} (custom/parse-field :sigma-ends "")))
 (is (:error (custom/parse-field :sigma-ends "-1")))
 (is (= {:value nil} (custom/parse-field :sigma "  ")))
 (is (:error (custom/parse-field :sigma "-1")))
 (is (:error (custom/parse-field :name "")))
 (testing "a form cell may be blank: it clears the cell"
  (is (= {:value ""} (custom/parse-cell :name "")))
  (is (= {:value ""} (custom/parse-cell :label " ")))
  (is (= {:value ""} (custom/parse-cell :formula "")))
  (is (= {:value nil} (custom/parse-cell :z "")))
  (is (= {:value nil} (custom/parse-cell :slope "")))
  (is (= {:value nil} (custom/parse-cell :z-ends "")))
  (is (= {:value 5} (custom/parse-cell :z "5")))
  (is (:error (custom/parse-cell :z "x")))))

(deftest formula-taken-into-an-entry
 (let [e {:formula "NaCl", :z 28}
   u {:label "", :formula "", :z nil, :slope nil, :sigma nil}]
  (testing "a changed formula gets the computed Z"
   (is (= {:value {:formula "H2O", :z 10}, :note nil}
     (custom/take-formula e "H2O" false))))
  (testing "an unchanged formula keeps a Z typed by hand"
   (is (= {:value {:formula "NaCl", :z 99}, :note nil}
     (custom/take-formula (assoc e :z 99) " NaCl " false))))
  (testing "a formula not understood: no Z, the reason as the note"
   (is (= {:value {:formula "Xx", :z nil}, :note "unknown element Xx"}
     (custom/take-formula e "Xx" false))))
  (testing "a blank formula says nothing"
   (is (= {:value {:formula "", :z nil}, :note nil}
     (custom/take-formula e "" false))))
  (testing "a unit drops ( )n, takes no charge and gets the offered label"
   (is (= {:value (assoc u :formula "C2H4O" :z 24 :label "B"), :note nil}
     (custom/take-formula u "(C2H4O)n" true "B")))
   (is (= "mine"
     (:label (:value (custom/take-formula (assoc u :label "mine")
        "CH2"
        true
        "B")))))
   (is (= "no charge allowed" (:note (custom/take-formula u "NH4+" true "A")))))))

(deftest field-problems-tell-their-field
 (let [fp custom/field-problem
   two (update polymer :units conj unit-b)]
  (is (nil? (fp nonbio)))
  (is (= [:name "name needed"] (fp (assoc nonbio :name ""))))
  (is (= [:formula "formula unknown"] (fp (assoc nonbio :formula "Xx" :z nil))))
  (is (= [:z "Z must be > 0"] (fp (assoc nonbio :z nil))))
  (is (= [:pmv "PMV needed"] (fp (assoc nonbio :pmv nil))))
  (is (= [:sigma "± not below 0"] (fp (assoc nonbio :sigma -1.0))))
  (is (= [[:unit 0 :label] "label needed"]
    (fp (assoc-in polymer [:units 0 :label] ""))))
  (is (= [[:unit 1 :slope] "slope needed"]
    (fp (assoc-in two [:units 1 :slope] nil))))
  (is (= [[:unit 1 :label] "unit label used"]
    (fp (assoc-in two [:units 1 :label] "A"))))
  (is (= [:z-ends "end groups needed"] (fp (assoc polymer :z-ends nil))))
  (is (= [:pmv-ends "end groups needed"] (fp (assoc polymer :pmv-ends nil))))
  (is (= [:sigma-ends "ends ± not below 0"] (fp (assoc polymer :sigma-ends -1.0))))
  (testing "problem is the message of field-problem"
   (doseq [e [nonbio polymer two (assoc nonbio :pmv nil)
      (assoc polymer :z-ends nil)]]
    (is (= (second (fp e)) (custom/problem e)))))
  (testing "one entry among the others: built-in and used names, case-insensitively"
   (is (nil? (custom/entry-problem nonbio nil ["x" "y"])))
   (is (= [:name "name in use"] (custom/entry-problem nonbio nil ["x" " nace "])))
   (is (= [:name "name is built-in"]
     (custom/entry-problem (assoc nonbio :name "peg")
      solute-index/builtin-name?
      [])))
   (is (= [:pmv "PMV needed"]
     (custom/entry-problem (assoc nonbio :pmv nil :name "peg")
      solute-index/builtin-name?
      []))
    "the entry's own fields come first")
   (is (<= (count "name is built-in") 22)))))

(deftest rows-of-the-unit-table
 (let [blank custom/blank-unit
   a (assoc blank :label "A" :formula "C2H4O" :z 24 :slope 36.9)
   c (assoc blank :formula "CH2" :z 8 :slope 5.3)]
  (is (= [0] (custom/used-rows [blank blank blank blank])) "row 1 is always used")
  (is (= [0 2] (custom/used-rows [a blank c blank])) "an all-blank row is ignored")
  (is (= [0 1] (custom/used-rows [a (assoc blank :slope 1.0) blank blank]))
   "a half-filled row is used (and then a problem)")
  (is (= [0 3] (custom/used-rows [blank blank blank c])))
  (testing "compacting keeps the order and offers the label of the row's place"
   (is (= ["A" "C"] (map :label (custom/compact-units [a blank c blank]))))
   (is (= ["A"] (map :label (custom/compact-units [blank blank blank blank])))
    "even an empty first row gets its offered label")
   (is (= ["mine"]
     (map :label
      (custom/compact-units [(assoc a :label "mine") blank blank
        blank])))))))

(deftest the-chain-rule-of-the-julia-type
 (let [unit (fn [z slope sigma] {:z z, :slope slope, :sigma sigma})
   two (fn [s1 s2 s-ends]
    {:units [(unit 24 36.92 s1) (unit 32 53.13 s2)],
     :z-ends 10,
     :pmv-ends 9.0,
     :sigma-ends s-ends})
   near (fn [a b] (< (abs (- a b)) 1e-9))]
  (testing
   "the numbers of test_customsolutes.jl: counts 100 and 65, ends Z 10, PMV 9"
   (let [r (custom/chain-values (two nil nil nil) [100 65])]
    (is (= 4490 (:z r)))
    (is (near 7154.45 (:pmv r)))
    (is (near (* custom/polymer-unknown-rel-unc (abs 7154.45)) (:sigma r))
     "nothing stated: 2 % of the whole PMV")))
  (testing "σ of each unit and of the ends add in quadrature"
   (is (near (Math/sqrt (+ (Math/pow (* 0.3 100) 2) (Math/pow (* 0.5 65) 2) 64.0))
     (:sigma (custom/chain-values (two 0.3 0.5 8.0) [100 65])))))
  (testing "a unit that states none contributes 2 % of its own part"
   (let [po (* custom/polymer-unknown-rel-unc 53.13 65)]
    (is (near (Math/sqrt (+ (Math/pow (* 0.3 100) 2) (* po po)))
      (:sigma (custom/chain-values (two 0.3 nil nil) [100 65]))))))
  (testing "only the ends' σ stated: the units get 2 % of their parts"
   (let [a (* custom/polymer-unknown-rel-unc 36.92 100)
     b (* custom/polymer-unknown-rel-unc 53.13 65)]
    (is (near (Math/sqrt (+ (* a a) (* b b) 25.0))
      (:sigma (custom/chain-values (two nil nil 5.0) [100 65]))))))
  (testing "one unit, the PEG line: Z = 10 + 24 n"
   (is (= 538
     (:z (custom/chain-values
       {:units [(unit 24 36.73 nil)],
        :z-ends 10,
        :pmv-ends 19.24,
        :sigma-ends nil}
       [22])))))
  (testing "Z rounds halves to even like Julia's round"
   (is (= 2
     (:z (custom/chain-values {:units [(unit 1 1.0 nil)],
        :z-ends 0,
        :pmv-ends 0.0,
        :sigma-ends nil}
       [2.5]))))
   (is (= 4
     (:z (custom/chain-values {:units [(unit 1 1.0 nil)],
        :z-ends 0,
        :pmv-ends 0.0,
        :sigma-ends nil}
       [3.5])))))))
