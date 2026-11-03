;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The add flow of the buffer page as pure functions: the dropdown of names, its ranking
;; and placement, the params of a row, and the steps of the flow for every kind of solute,
;; each compared with the row of test/fixtures/buffer/buffer.edn it must equal.

(ns baysol.tui.add-flow-test
 (:require [baysol.tui.add-flow :as flow]
  [baysol.tui.text :as txt]
  [baysol.tui.buffer :as buffer]
  [baysol.tui.limits :as limits]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.solute-index :as solute-index]
  [baysol.tui.solutes :as solutes]
  [baysol.tui.support :as support :refer [enter esc down]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private fixture
 (:solutes (edn/read-string (slurp (io/file
     "../test/fixtures/buffer/buffer.edn")))))

(defn ^:private fixture-row
 "The row of the fixture with the name `row-name`."
 [row-name]
 (first (filter #(= row-name (:name %)) fixture)))

(def ^:private nacet
 {:kind :nonbiological,
  :name "N-acetylcysteine ethyl ester",
  :formula "C7H13NO3S",
  :z 102,
  :pmv 118.4,
  :sigma 4.0})

(def ^:private ammonium
 {:kind :nonbiological,
  :name "amm-nitrate-x",
  :formula "NH4+ NO3-",
  :z 32,
  :pmv 46.7,
  :sigma nil})

(def ^:private chain-1
 {:kind :polymer,
  :name "chain-1",
  :z-ends 10,
  :pmv-ends 19.24,
  :sigma-ends nil,
  :units [{:label "A", :formula "C2H4O", :z 24, :slope 36.73, :sigma nil}]})

(def ^:private chain-4
 {:kind :polymer,
  :name "chain-4",
  :z-ends 5,
  :pmv-ends 7.0,
  :sigma-ends 0.5,
  :units [{:label "A", :formula "C2H4O", :z 10, :slope 1.0, :sigma nil}
   {:label "B", :formula "C3H6O", :z 20, :slope 2.0, :sigma 0.1}
   {:label "C", :formula "C4H8O", :z 30, :slope 3.0, :sigma nil}
   {:label "D", :formula "C5H10O", :z 40, :slope 4.0, :sigma 0.2}]})

(def ^:private customs [nacet ammonium chain-1 chain-4])

(def ^:private env {:pick-file (fn [] {:files []})})

(def ^:private st0
 {:s (solutes/initial []), :cursor 0, :offset 0, :note nil, :ui nil})

(defn ^:private bs
 "`n` Backspace keys."
 [n]
 (vec (repeat n KeyType/Backspace)))

(defn ^:private feed
 "`st` after the keys `inputs` (a string is each of its characters, a vector its keys)
 went through the flow."
 [st & inputs]
 (reduce (fn [st k] (flow/step st k env))
  st
  (mapcat #(cond (string? %) (seq %)
    (sequential? %) %
    :else [%])
   inputs)))

(defn ^:private add
 "`st0` (or `st`) with the add key of `kind` pressed (`:nonbio` unless said, `^n`), the
 custom solutes being `customs`."
 ([] (add st0 :nonbio))
 ([st] (add st :nonbio))
 ([st kind] (flow/start-add st {:customs customs} kind)))

(defn ^:private addp
 "`st0` with `^p` (a polymer) pressed."
 []
 (add st0 :polymer))

(defn ^:private rows [st] (mapv solutes/value (get-in st [:s :rows])))


(deftest numbers
 (is (= "200" (flow/format-number 200.0)))
 (is (= "0.00001" (flow/format-number 1.0E-5)))
 (is (= "" (flow/format-number nil)))
 (is (= {:value 0.5} (flow/parse-field :sigma-mM " 0.5 ")))
 (is (:error (flow/parse-field :mM "0")))
 (is (= "mM must be > 0" (:error (flow/parse-field :mM "-1"))))
 (is (= "not below 0" (:error (flow/parse-field :sigma-mM "-1"))))
 (is (= "a number, please" (:error (flow/parse-field :sigma-mM "")))))

(deftest the-entries
 (testing "a blank query lists nothing, a typed one only what its add key adds"
  (is (= [] (flow/entries :nonbio "" [])))
  (is (= [] (flow/entries :polymer "" [])))
  (is (= "tris" (:name (first (flow/entries :nonbio "tris" []))))))
 (testing "^n never lists a polymer, a family, a file or a custom polymer"
  (let [kinds (set (map :kind
      (mapcat #(flow/entries :nonbio % customs)
       ["a" "e" "peg" "chain" "ficoll" "dna" "n" "co"])))]
   (is (seq kinds))
   (is (every? #{:nonbiological :custom-nonbio} kinds))))
 (testing "^p never lists a solute, a custom solute or a file"
  (let [kinds (set (map :kind
      (mapcat #(flow/entries :polymer % customs)
       ["a" "e" "peg" "chain" "ficoll" "dna" "n" "co"])))]
   (is (seq kinds))
   (is (every? #{:polymer :polymer-family :custom-polymer} kinds))))
 (testing "the same query finds a name only under the key of its kind"
  (is (= "nacl" (:name (first (flow/entries :nonbio "nacl" [])))))
  (is (= [] (flow/entries :polymer "nacl" [])))
  (is (= [] (flow/entries :nonbio "ficoll 70" [])))
  (is (= :polymer-family (:kind (first (flow/entries :polymer "peg" []))))))
 (testing "tags: solute, polymer, family, custom"
  (is (= "solute" (flow/entry-tag (first (flow/entries :nonbio "nacl" [])))))
  (is (= "family" (flow/entry-tag (first (flow/entries :polymer "peg" [])))))
  (is (= "polymer" (flow/entry-tag (first (flow/entries :polymer "ficoll 70" [])))))
  (is (= "custom"
    (flow/entry-tag (first (flow/entries :polymer "chain-4" customs)))))
  (is (= "custom"
    (flow/entry-tag (first (flow/entries :nonbio "amm-nitrate-x" customs))))))
 (testing "the custom solutes are found by name and carry their entry"
  (let [e (first (flow/entries :nonbio "n-acetylcysteine ethyl ester" customs))]
   (is (= :custom-nonbio (:kind e)))
   (is (= nacet (:entry e))))
  (is (= :custom-polymer (:kind (first (flow/entries :polymer "chain-1" customs)))))
  (is (= [] (flow/entries :nonbio "chain-1" customs)))))

(deftest name-dropdown-keys
 (let [p0 (flow/name-pick-initial :polymer customs)
   step (fn [p k] (:state (flow/name-pick-step p k)))
   typed (fn [p s] (reduce step p s))]
  (testing "typing narrows, the first entry is highlighted"
   (let [p (typed p0 "chain")]
    (is (= "chain" (:buffer p)))
    (is (= 0 (:index p)))
    (is (= "chain-1" (:name (first (:matches p)))))))
  (testing "up and down wrap over the entries"
   (let [p (typed p0 "chain")
     n (count (:matches p))]
    (is (= (dec n) (:index (step p KeyType/ArrowUp))))
    (is (= 0 (:index (reduce step p (repeat n KeyType/ArrowDown)))))))
  (testing
   "Tab completes the typed text to the highlighted name; with no entry it is idle"
   (is (= "chain-1" (:buffer (step (typed p0 "chai") KeyType/Tab))))
   (is (= "" (:buffer (step p0 KeyType/Tab)))))
  (testing "Backspace, Enter and Escape"
   (is (= "cha" (:buffer (step (typed p0 "chai") KeyType/Backspace))))
   (is (= "" (:buffer (step p0 KeyType/Backspace))))
   (is (= "chain-1"
     (:name (:chosen (flow/name-pick-step (typed p0 "chain") enter)))))
   (is (= :cancel (flow/name-pick-step p0 esc)))
   (is (= :cancel (flow/name-pick-step p0 KeyType/EOF))))
  (testing
   "a typo, or nothing typed, finds nothing: Enter takes nothing, keys are idle"
   (doseq [p [(typed p0 "qqqqzzzz") p0]
     :let [r (flow/name-pick-step p enter)]]
    (is (= "no match" (get-in r [:state :error])))
    (is (nil? (:chosen r)))
    (is (= [] (:matches (step p down))))
    (is (= 0 (:index (step p down))))))
  (testing "the text typed stops at 60 characters"
   (is (= 60 (count (:buffer (typed p0 (apply str (repeat 70 "a"))))))))))

(deftest dropdown-text
 (let [e {:name
    "a-rather-long-solute-name-that-will-not-fit-in-the-dropdown-at-all",
    :tag "solute",
    :kind :nonbiological}]
  (testing "a line is exactly as wide as asked, with the tag at the right"
   (doseq [room [20 45 60]
     entry [e {:name "ficoll 70", :kind :polymer, :tag "polymer"}
      {:name "x", :tag "custom"}
      {:name "peg", :kind :polymer-family, :tag "polymer"}]
     :let [t (flow/item-text entry room)]]
    (is (= room (txt/display-width t)) (str room " " t))))
  (is (str/ends-with? (flow/item-text e 45) "…  solute")
   "the long name ends in an ellipsis before its tag")
  (is (str/ends-with?
    (flow/item-text {:name "peg", :kind :polymer-family, :tag "polymer"} 30)
    "family"))
  (testing "the status row says what is going on"
   (let [p0 (flow/name-pick-initial :polymer [])]
    (is (= "type a solute name"
      (:error (flow/pick-display (flow/name-pick-initial :nonbio []) 40))))
    (is (= "type a polymer name" (:error (flow/pick-display p0 40))))
    (is (str/starts-with?
      (:error (flow/pick-display
        (reduce #(:state (flow/name-pick-step %1 %2)) p0 "qqqqzzzz")
        40))
      "no match"))
    (is (nil? (:error (flow/pick-display
        (reduce #(:state (flow/name-pick-step %1 %2)) p0 "peg")
        40)))))
   (is (<= (count flow/no-match) 40)))))

(deftest the-basis
 (is (= "mM per monomer unit" (flow/basis-note "per monomer unit")))
 (is (= "mM per 1000 Da" (flow/basis-note "per 1000 Da")))
 (is (nil? (flow/basis-note nil)))
 (testing "the note of the highlighted entry"
  (let [st (feed (addp) "ficoll 70")]
   (is (= "mM per 1000 Da" (flow/ui-note st))))
  (is (nil? (flow/ui-note (feed (add) "tris"))))
  (is (nil? (flow/ui-note (feed (addp) "peg"))) "a family has no basis")))

(deftest placement
 ;; the body of the real tables starts on line 3 (a top border) and is 15 rows tall
 (testing "below when 8 rows remain under the cell of a 15-row table, else above"
  (is (flow/below? 0 15))
  (is (flow/below? 6 15))
  (is (not (flow/below? 7 15)))
  (is (= 4 (flow/box-top 0 15 8 3)))
  (is (= 10 (flow/box-top 6 15 8 3)))
  (is (= 2 (flow/box-top 7 15 8 3)) "ends on the line above the cell")
  (is (= (- (+ 3 14) 3) (flow/box-top 14 15 3 3))
   "a short list sits against the cell")
  (is (= 3 (flow/box-top 0 18 8 2)) "an art with no top border starts on line 2"))
 (testing "the box blanks what it covers and never writes outside its columns"
  (let [lines (vec (repeat 24 (apply str (repeat 80 \x))))
    out (flow/overlay-box lines
     ["a" "b" "c"]
     2
     {:col 4, :width 49, :window 15, :top 3})]
   (is (= (nth lines 5) (nth out 5)))
   (is (str/starts-with? (nth out 6) "xxxxa "))
   (is (= 80 (count (nth out 6))))
   (is (= (subs (nth lines 6) 53) (subs (nth out 6) 53)))
   (is (= (nth lines 9) (nth out 9))))))

(deftest params-of-a-row
 (let [w 22
   p (fn [row-name] (flow/params-cell (fixture-row row-name) w))]
  (testing
   "n/a centred for a non-biological solute, a grade, a custom non-biological one"
   (is (= {:text "n/a", :align :center} (p "NaCl")))
   (is (= {:text "n/a", :align :center} (p "NACET")))
   (is (= {:text "n/a", :align :center}
     (flow/params-cell {:kind :polymer, :arg "ficoll 70"} w))))
  (testing "key=value, left, for a family and a custom polymer"
   (is (= {:text "Mn=3350", :align :left} (p "PEG 3350")) "PEG 3350 is the Mn form")
   (is (= {:text "n=22", :align :left} (p "PEG 22")))
   (is (= {:text "nEO=100 nPO=65", :align :left} (p "Pluronic")))
   (is (= {:text "nA=22", :align :left} (p "one-unit chain")))
   (is (= {:text "nA=3 nB=4 nC=5 nD=6", :align :left} (p "four-unit chain"))))
  (testing "the summary of a sequence, within the width"
   (is (= {:text "ACGTTGCA (8 nt)", :align :left} (p "primer-A")))
   (is (= "MKTAYIAKQR (10 aa)" (:text (p "carrier"))))
   (let [long-seq (apply str (repeat 200 "ACGT"))
     t (:text (flow/params-cell {:kind :dna, :arg long-seq} w))]
    (is (= w (count t)))
    (is (str/ends-with? t "(800 nt)"))))
  (testing "a row that is not complete yet does not break the cell"
   (is (= "n/a" (:text (flow/params-cell {:kind :polymer, :arg ""} w))))
   (is (= "" (:text (flow/params-cell {:kind :custom-polymer} w)))))))

(deftest families-of-an-arg
 (is (= {"n" "22"} (:values (flow/family-match "PEG n=22"))))
 (is (= {"Mn" "3350"} (:values (flow/family-match "peg 3350"))))
 (is (= {"nC" "12", "nEO" "9"} (:values (flow/family-match "Brij nC=12 nEO=9"))))
 (is (= 1 (:form-index (flow/family-match "PEG 3350"))))
 (is (nil? (flow/family-match "ficoll 70")))
 (is (nil? (flow/family-match "PEG 3350 extra")))
 (is (nil? (flow/family-match "")))
 (is (nil? (flow/family-match nil))))

(deftest paths
 (support/with-data-folder
  [root (support/temp-root)]
  (let [f (io/file root "a.fasta")]
   (spit f ">a\nACGT\n")
   (is (= "type a path first!" (flow/path-problem "")))
   (is (= "use a full path" (flow/path-problem "a.fasta")))
   (is (= "no such file" (flow/path-problem (str root "/none.fa"))))
   (is (= "that is a folder" (flow/path-problem (str root))))
   (is (nil? (flow/path-problem (str f))))
   (doseq [m ["type a path first!" "use a full path" "no such file"
      "that is a folder"
      "cannot read the file"]]
    (is (<= (count m) 22)))
   (testing "the hints are folders and sequence files only"
    (spit (io/file root "b.txt") "x")
    (spit (io/file root "c.FQ") "@a\nA\n+\nI\n")
    (.mkdir (io/file root "dir"))
    (is (= ["dir/" "a.fasta" "c.FQ"] (flow/path-hints (str root "/"))))
    (is (= ["a.fasta"] (flow/path-hints (str root "/a"))))))))

;; --- the steps of the flow, row by row against the fixture

(defn ^:private only-row
 [st]
 (let [r (rows st)]
  (is (= 1 (count r)))
  (first r)))

(defn ^:private same-as-fixture
 "Whether `row` is the fixture row `fx-name`, but for its `:name`; and a valid row."
 [row fx-name]
 (let [fx (fixture-row fx-name)]
  (and (= (dissoc row :name) (dissoc fx :name)) (nil? (buffer/row-problem row)))))

(deftest non-biological-and-grades
 (testing "a non-biological solute: arg is the index target, then mM, then ±"
  (let [st (feed (add) "nacl" enter)]
   (is (= :edit (get-in st [:ui :type])))
   (is (= :mM (get-in st [:ui :field])))
   (let [st (feed st "200" enter)]
    (is (= :sigma-mM (get-in st [:ui :field])))
    (let [st (feed st "10" enter)
      row (only-row st)]
     (is (nil? (:ui st)) "the flow is over")
     (is (= "nacl" (:name row)) "the picked name is the row's name")
     (is (same-as-fixture row "NaCl"))
     (is (= [\*] (mapv solutes/mark (get-in st [:s :rows])))
      "a draft, nothing saved")))))
 (testing "a built-in polymer grade"
  (let [row (only-row (feed (addp) "ficoll 70" enter "0.05" enter "0.003" enter))]
   (is (= {:kind :polymer,
      :name "ficoll 70",
      :arg (:target (solute-index/resolve-builtin "ficoll 70")),
      :mM 0.05,
      :sigma-mM 0.003}
     row))
   (is (nil? (buffer/row-problem row)))
   (is (= {:text "n/a", :align :center} (flow/params-cell row 22))))))

(deftest families
 (testing
  "PEG by n: a choice of the forms first, then the number in the params cell"
  (let [st (feed (addp) "peg" enter)]
   (is (= :form (get-in st [:ui :type])))
   (let [st (feed st enter)]
    (is (= :params (get-in st [:ui :field])))
    (is (= "units n" (flow/ui-note st)) "the prompt is in the border note")
    (let [st (feed st "22" enter)]
     (is (= :mM (get-in st [:ui :field])))
     (let [row (only-row (feed st "0.1" enter "0.01" enter))]
      (is (same-as-fixture row "PEG 22")))))))
 (testing "PEG by Mn: the second form"
  (let [st (feed (addp) "peg" enter down enter)]
   (is (= "Mn (g/mol)" (flow/ui-note st)))
   (is (same-as-fixture (only-row (feed st "3350" enter "0.05" enter "0.003" enter))
     "PEG 3350"))))
 (testing "a family with two arguments asks for both, shows them as typed"
  (let [st (feed (addp) "pluronic" enter)]
   (is (= "ethylene oxide units nEO" (flow/ui-note st)))
   (let [st (feed st "100" enter)]
    (is (= "propylene oxide units nPO" (flow/ui-note st)))
    (is (= "nEO=100 nPO=6" (:text (flow/edit-view (feed st "6")))))
    (is (same-as-fixture
      (only-row (feed st "65" enter "0.01" enter "0.001" enter))
      "Pluronic")))))
 (testing "an error from the family stays in the cell and says why"
  (let [st (feed (addp) "peg" enter enter "1" enter)]
   (is (= "n: at least 2" (:note st)))
   (is (= :params (get-in st [:ui :field])))
   (is (= "1" (get-in st [:ui :text])))
   (let [st (feed st (bs 1) "x" enter)]
    (is (= "n: not a number" (:note st))))
   (is (= :mM (get-in (feed st (bs 1) "5" enter) [:ui :field])))))
 (testing "dextran by Mn below 1000 tells that it counts as kDa, while mM is typed"
  (let [st (feed (addp) "dextran" enter down enter "40" enter)]
   (is (= :mM (get-in st [:ui :field])))
   (is (= "below 1000 counts as kDa" (flow/ui-note st)))
   (is (= "dextran 40" (:arg (first (rows (feed st "1" enter "0.1" enter))))))
   (is (nil? (flow/ui-note (feed st "1" enter))) "the note goes with the mM cell"))
  (let [st (feed (addp) "dextran" enter down enter "40000" enter)]
   (is (nil? (flow/ui-note st))))))

(deftest custom-solutes
 (testing "a custom non-biological solute stores a snapshot of the entry"
  (let [row (only-row (feed (add)
      "n-acetylcysteine ethyl ester" enter
      "5" enter
      "0.1"
      enter))]
   (is (same-as-fixture (assoc row :custom "N-acetylcysteine ethyl ester") "NACET")
    "the snapshot is the fixture's, with the entry's name")
   (is (= {:kind :custom-nonbio,
      :custom "N-acetylcysteine ethyl ester",
      :z 102,
      :pmv 118.4,
      :sigma-pmv 4.0,
      :name "N-acetylcysteine ethyl ester",
      :mM 5.0,
      :sigma-mM 0.1}
     row))))
 (testing "a blank ± of the entry is kept as nil"
  (let [row (only-row (feed (add) "amm-nitrate-x" enter "10" enter "0.2" enter))]
   (is (nil? (:sigma-pmv row)))
   (is (contains? row :sigma-pmv))))
 (testing "a custom polymer asks the count of each unit in the params cell"
  (let [st (feed (addp) "chain-4" enter)]
   (is (= :params (get-in st [:ui :field])))
   (is (= "nA" (flow/ui-note st)))
   (let [st (feed st "3" enter "4" enter)]
    (is (= "nC" (flow/ui-note st)))
    (is (= "nA=3 nB=4 nC=5" (:text (flow/edit-view (feed st "5")))))
    (let [st (feed st "5" enter "6" enter)
      row (do (is (= :mM (get-in st [:ui :field])))
       (only-row (feed st "0.01" enter "0.0001" enter)))]
     (is (same-as-fixture row "four-unit chain"))))))
 (testing "one unit"
  (let [row (only-row
     (feed (addp) "chain-1" enter "22" enter "0.01" enter "0.0001" enter))]
   (is (same-as-fixture row "one-unit chain"))
   (is (= [22.0] (:counts row)))))
 (testing "an entry that does not make a valid row is refused with a note"
  (let [bad (assoc nacet :z nil :name "broken")
    st (flow/start-add st0 {:customs [bad]} :nonbio)
    st (feed st "broken" enter)]
   (is (= "custom entry invalid" (:note st)))
   (is (= :name (get-in st [:ui :type]))))))

(defn ^:private seq-file
 [dir fname text]
 (let [f (io/file dir fname)]
  (spit f text)
  (str f)))

(deftest sequences-from-files
 (support/with-data-folder
  [root (support/temp-root)]
  (let [dna (seq-file root "primer.fasta" ">p1\nACGTTGCA\n")
    two (seq-file root "two.fa" ">r1 first\nAC\nGT\n>r2\nGGCC\n")
    rna (seq-file root "guide.fa" ">g1\nACGUUGCA\n")
    prot (seq-file root "carrier.fa" ">sp|P1\nMKTAYIAKQR\n")
    fq (seq-file root "reads.fastq" "@q1\nACGT\n+\nIIII\n@q2\nTTGA\n+\nIIII\n")
    to-path (fn [kind]
     (case kind
      :protein (add st0 :protein)
      :dna (feed (add st0 :nucleotide) enter)
      :rna (feed (add st0 :nucleotide) down enter)))]
   (testing "DNA: the choice, a path, then mM and ± once"
    (let [st (to-path :dna)]
     (is (= :path (get-in st [:ui :type])))
     (is (= :dna (get-in st [:ui :seq-kind])))
     (let [st (feed st dna enter)]
      (is (= :mM (get-in st [:ui :field])))
      (is (same-as-fixture (only-row (feed st "0.01" enter "0.001" enter))
        "primer-A"))
      (is (= "p1" (:name (only-row (feed st "0.01" enter "0.001" enter))))
       "the record id names the row")
      (is (= "primer.fasta" (:source (only-row (feed st "1" enter "0" enter))))
       "the file name, not the path"))))
   (testing "RNA and protein"
    (is (same-as-fixture (only-row (feed (to-path :rna)
        rna
        enter
        "0.02" enter
        "0.002" enter))
      "guide"))
    (let [row (only-row
       (feed (to-path :protein) prot enter "0.02" enter "0.002" enter))]
     (is (same-as-fixture row "carrier"))
     (is (= "sp|P1" (:name row)))))
   (testing "a file of several records makes one row each, with mM and ± for all"
    (let [st (feed (to-path :dna) two enter "1.5" enter)
      st (feed st "0.1" enter)]
     (is (= [["r1" "ACGT"] ["r2" "GGCC"]] (mapv (juxt :name :arg) (rows st))))
     (is (every? #(= 1.5 (:mM %)) (rows st)))
     (is (every? #(= 0.1 (:sigma-mM %)) (rows st)))
     (is (= ["two.fa" "two.fa"] (mapv :source (rows st))))
     (is (= ["r1" "r2"] (mapv :record (rows st))))
     (is (every? #(nil? (buffer/row-problem %)) (rows st)))
     (is (= [\* \*] (mapv solutes/mark (get-in st [:s :rows]))))))
   (testing "a FASTQ file is read like a FASTA one"
    (let [st (feed (to-path :dna) fq enter "1" enter "0.1" enter)]
     (is (= [["q1" "ACGT"] ["q2" "TTGA"]] (mapv (juxt :name :arg) (rows st))))))
   (testing "errors keep the prompt open, with a note of at most 22 characters"
    (doseq [[typed note] [["" "type a path first!"] ["rel.fa" "use a full path"]
       [(str root "/none.fa") "no such file"]
       [(str root) "that is a folder"]
       [(seq-file root "bad.fa" ">x\nAC9\n")
        "bad letter 9 (DNA)"]
       [(seq-file root "none.txt" "hello") "wrong format"]
       [(seq-file root "empty.fa" "") "no records"]]
      :let [st (feed (to-path :dna) typed enter)]]
     (is (= :path (get-in st [:ui :type])) typed)
     (is (= note (:note st)) typed)
     (is (<= (count (:note st)) 22))
     (is (= 1 (count (rows st))) "only the draft row so far")))
   (testing "the 999-row cap stops a file that would not fit, adding nothing"
    (let [full {:s (solutes/initial (vec (repeat 998
          {:kind :nonbiological,
           :name "s",
           :arg "s",
           :mM 1.0,
           :sigma-mM 0.1}))),
       :cursor 0,
       :offset 0,
       :note nil,
       :ui nil}
      st (feed (add full :nucleotide) enter)
      st (feed st two enter)]
     (is (= :path (get-in st [:ui :type])))
     (is (= "over 999 rows" (:note st)))
     (is (= 999 (count (rows st))) "only the draft row, nothing of the file")
     (let [st (feed st esc)]
      (is (= 998 (count (rows st)))))
     (let [one (feed (feed (add full :nucleotide) enter) dna enter)]
      (is (= 999 (count (rows one))) "one record still fits")
      (is (= 999 limits/max-rows)))))
   (testing "a DNA file with a U is refused as DNA, an RNA file with a T as RNA"
    (let [u (seq-file root "u.fa" ">x\nACGU\n")
      t (seq-file root "t.fa" ">x\nACGT\n")]
     (is (= "bad letter U (DNA)" (:note (feed (to-path :dna) u enter))))
     (is (= "bad letter T (RNA)" (:note (feed (to-path :rna) t enter))))
     (is (nil? (:note (feed (to-path :dna) t enter))))
     (is (nil? (:note (feed (to-path :rna) u enter))))))
   (testing "o on an empty path takes the file the desktop's picker gave"
    (let [st (to-path :dna)
      picked (flow/step st \o {:pick-file (fn [] {:files [dna]})})]
     (is (= dna (get-in picked [:ui :buffer])))
     (is (= "no desktop"
       (:note (flow/step st \o {:pick-file (fn [] {:problem "no desktop"})}))))
     (is (= st (flow/step st \o {:pick-file (fn [] {:files []})})))
     (is (= "/o" (get-in (flow/step (feed st "/") \o env) [:ui :buffer]))
      "no: with text typed it is just a letter")))
   (testing "hints: Tab completes, Up and Down move"
    (let [st (feed (to-path :dna) (str root "/c"))]
     (is (= (str root "/carrier.fa")
       (get-in (feed st KeyType/Tab) [:ui :buffer]))))))))

;; --- cancel at every stage, and editing

(deftest the-add-keys-start-the-right-flow
 (testing "^n and ^p open a name dropdown of their kind, nothing listed until typed"
  (doseq [kind [:nonbio :polymer]
    :let [ui (:ui (add st0 kind))]]
   (is (= :name (:type ui)))
   (is (= kind (get-in ui [:pick :kind])))
   (is (= [] (get-in ui [:pick :matches])))))
 (testing "the dropdowns list only their kind, whatever is typed"
  (doseq [typed ["peg" "nacl" "chain" "tris" "dna" "ficoll"]
    [kind allowed] [[:nonbio #{:nonbiological :custom-nonbio}]
     [:polymer #{:polymer :polymer-family :custom-polymer}]]
    :let [ms (get-in (feed (add st0 kind) typed) [:ui :pick :matches])]]
   (is (every? (comp allowed :kind) ms) (str kind " " typed))))
 (testing "^f asks for the path of a protein file at once, with no dropdown"
  (let [ui (:ui (add st0 :protein))]
   (is (= {:type :path, :seq-kind :protein, :buffer "", :add [0]}
     (select-keys ui [:type :seq-kind :buffer :add])))))
 (testing "^e asks DNA or RNA first, Up and Down move, Enter opens that path"
  (let [st (add st0 :nucleotide)]
   (is (= :nuc (get-in st [:ui :type])))
   (is (= :dna (get-in (feed st enter) [:ui :seq-kind])))
   (is (= :rna (get-in (feed st down enter) [:ui :seq-kind])))
   (is (= :path (get-in (feed st down enter) [:ui :type])))
   (is (= (count (:rows (:s st))) 1) "one draft row")))
 (testing "Escape at every stage drops the new row"
  (doseq [[label st] [["^n name" (add st0 :nonbio)]
     ["^n typed" (feed (add st0 :nonbio) "tr")]
     ["^p name" (add st0 :polymer)]
     ["^f path" (add st0 :protein)]
     ["^f typed" (feed (add st0 :protein) "/x")]
     ["^e choice" (add st0 :nucleotide)]
     ["^e path" (feed (add st0 :nucleotide) enter)]]
    :let [done (feed st esc)]]
   (is (= 0 (count (rows done))) label)
   (is (nil? (:ui done)) label))))

(deftest tab-completes-in-flows-only
 (testing "in the name dropdown Tab completes to the highlighted name"
  (is (= "ficoll 70"
    (get-in (feed (add st0 :polymer) "ficoll 7" KeyType/Tab)
     [:ui :pick :buffer]))))
 (testing "in the path prompt Tab completes the path"
  (support/with-data-folder
   [root (support/temp-root)]
   (let [f (seq-file root "carrier.fa" ">a\nMK\n")
     st (feed (add st0 :protein) (str root "/c") KeyType/Tab)]
    (is (= f (get-in st [:ui :buffer])))))))

(deftest cancel-drops-the-new-rows
 (let [base (feed (add) "tris" enter "1" enter "0.1" enter)
   n1 (count (rows base))]
  (is (= 1 n1))
  (testing "Escape at the name, the form, the params, mM, ± and the path"
   (doseq [[label typed-keys]
     [["name" []] ["name typed" ["pe"]] ["form" ["peg" enter]]
      ["params" ["peg" enter enter]]
      ["second arg" ["pluronic" enter "10" enter]]
      ["counts" ["chain-4" enter "1" enter]] ["mM" ["tris" enter]]
      ["±" ["tris" enter "1" enter]]]
     :let [st (apply feed (add base) typed-keys)
      done (feed st esc)]]
    (is (= 2 (count (rows st))) (str label ": the draft is there"))
    (is (= 1 (count (rows done))) (str label ": dropped"))
    (is (nil? (:ui done)) label)
    (is (= 0 (:cursor done)) (str label ": the cursor is where it was"))))
  (testing "a file's rows all go, after the mM was taken"
   (support/with-data-folder
    [root (support/temp-root)]
    (let [two (seq-file root "two.fa" ">r1\nAC\n>r2\nGG\n")
      st (feed (add base :nucleotide) enter two enter "1" enter)
      done (feed st esc)]
     (is (= 3 (count (rows st))))
     (is (= 1 (count (rows done)))))))
  (testing "a saved row is never dropped"
   (let [saved {:s (solutes/initial [(fixture-row "NaCl")]),
      :cursor 0,
      :offset 0,
      :note nil,
      :ui nil}
     st (feed (add saved) esc)]
    (is (= [(fixture-row "NaCl")] (rows st)))))))

(deftest editing-rows
 (let [on (fn [row-name]
    {:s (solutes/initial [(fixture-row row-name)]),
     :cursor 0,
     :offset 0,
     :note nil,
     :ui nil})
   fields (fn [st]
    (loop [st (flow/start-edit st)
      seen []]
     (if-let [f (get-in st [:ui :field])]
      (recur (feed st enter) (conj seen f))
      seen)))]
  (testing "the fields of an edit, in order, skipping what does not apply"
   (is (= [:name :mM :sigma-mM] (fields (on "NaCl"))))
   (is (= [:name :mM :sigma-mM] (fields (on "NACET"))))
   (is (= [:name :params :mM :sigma-mM] (fields (on "PEG 22"))))
   (is (= [:name :params :params :mM :sigma-mM] (fields (on "Pluronic"))))
   (is (= [:name :params :params :params :params :mM :sigma-mM]
     (fields (on "four-unit chain"))))
   (is (= [:name :mM :sigma-mM] (fields (on "primer-A")))
    "a sequence has no params")
   (is (= [:name :mM :sigma-mM]
     (fields {:s (solutes/initial [{:kind :polymer,
          :name "F",
          :arg "ficoll 70",
          :mM 1.0,
          :sigma-mM 0.1}]),
       :cursor 0,
       :ui nil}))))
  (testing "the name is a free label: arg and kind stay"
   (let [st (feed (on "NaCl") enter)]
    (is (nil? (:ui st)) "no edit was open"))
   (let [st (feed (flow/start-edit (on "NaCl")) (bs 4) "salt" enter)
     row (first (rows st))]
    (is (= "salt" (:name row)))
    (is (= "sodium chloride" (:arg row)))
    (is (= :nonbiological (:kind row)))
    (is (= :mM (get-in st [:ui :field])))
    (is (= "name needed"
      (:note (feed (flow/start-edit (on "NaCl")) (bs 4) enter))))))
  (testing "a family's numbers are re-typed and the arg rebuilt"
   (let [st (flow/start-edit (on "PEG 22"))
     st (feed st enter)]
    (is (= :params (get-in st [:ui :field])))
    (is (= "22" (get-in st [:ui :text])) "the old number is the start")
    (is (= "units n" (flow/ui-note st)))
    (let [st (feed st (bs 2) "30" enter)]
     (is (= "PEG n=30" (:arg (first (rows st)))))
     (is (= "n=30" (:text (flow/params-cell (first (rows st)) 22)))))))
  (testing "a custom polymer's counts are re-typed"
   (let [st (feed (flow/start-edit (on "one-unit chain")) enter)]
    (is (= "22" (get-in st [:ui :text])))
    (let [st (feed st (bs 2) "50" enter)]
     (is (= [50.0] (:counts (first (rows st)))))
     (is (= "chain-1" (:custom (first (rows st))))))))
  (testing "Escape stops the edit and what was taken stays a draft"
   (let [st (feed (flow/start-edit (on "NaCl")) enter (bs 3) "150" enter esc)]
    (is (nil? (:ui st)))
    (is (= 150.0 (:mM (first (rows st)))))
    (is (= [\*] (mapv solutes/mark (get-in st [:s :rows]))))))
  (testing "a sequence row says the sequence is not edited here"
   (let [st (flow/start-edit (on "carrier"))]
    (is (= "re-add to change the sequence" (flow/ui-note st)))
    (is (nil? (flow/ui-note (feed st enter))))))
  (testing "old-style rows (free-text names that are not in the index) still edit"
   (let [old {:kind :nonbiological,
      :name "my buffer salt",
      :arg "my buffer salt",
      :mM 5.0,
      :sigma-mM 0.5}
     st (feed (flow/start-edit {:s (solutes/initial [old]), :cursor 0, :ui nil})
      enter
      (bs 1)
      "6"
      enter
      (bs 3)
      "0.6"
      enter)]
    (is (= (assoc old :mM 6.0 :sigma-mM 0.6) (first (rows st))))
    (is (= {:text "n/a", :align :center} (flow/params-cell old 22)))))
  (testing "a removed row cannot be edited"
   (let [st (update (on "NaCl") :s solutes/remove-row 0)]
    (is (nil? (:ui (flow/start-edit st))))))))

(deftest the-cap
 (let [full {:s (solutes/initial (vec (repeat 999 (fixture-row "NaCl")))),
    :cursor 0,
    :ui nil}]
  (is (= full (flow/start-add full {:customs []} :nonbio)))))

(deftest custom-file
 (support/with-data-folder
  [root (support/temp-root)]
  (testing "no file: no entries, no note"
   (is (= {:customs []} (flow/load-customs root))))
  (testing "an unusable file: no entries and a note"
   (spit (io/file root "custom-solutes.edn") "{:solutes")
   (let [r (flow/load-customs root)]
    (is (= [] (:customs r)))
    (is (= "custom file unusable!" (:note r)))
    (is (<= (count (:note r)) 22))
    (let [st (flow/start-add st0 r :nonbio)]
     (is (= "custom file unusable!" (:note st))))))
  (testing "entries without a name are left out"
   (spit (io/file root "custom-solutes.edn")
    (pr-str {:solutes [nacet (assoc ammonium :name "")]}))
   (is (= [nacet] (:customs (flow/load-customs root)))))))

(deftest views
 (testing "the name being searched shows in the name cell"
  (let [st (feed (addp) "pe")]
   (is (= {:i 0, :col 0, :text "pe"} (flow/edit-view st)))))
 (testing "the params cell shows the arguments as typed"
  (let [st (feed (addp) "pluronic" enter "1")]
   (is (= {:i 0, :col 3, :text "nEO=1"} (flow/edit-view st)))))
 (testing "nothing open, nothing to show"
  (is (nil? (flow/edit-view st0))))
 (testing "a row with a basis has a note without a flow"
  (is (= "mM per 1000 Da" (flow/row-note {:kind :polymer, :arg "ficoll 70"})))
  (is (nil? (flow/row-note {:kind :polymer, :arg "PEG n=22"})))
  (is (nil? (flow/row-note {:kind :nonbiological, :arg "nacl"})))))

(deftest the-page-uses-the-same-helpers
 (is (= "200" (solutes-menu/format-number 200.0)))
 (is (= (flow/parse-field :mM "3") (solutes-menu/parse-field :mM "3"))))
