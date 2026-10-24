;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of dev/extract_components.clj on tiny synthetic dictionaries: quoted values, `?`
;; parents, DNA / RNA / L-RNA and terminus types, tab sanitising, sorting, multi-line
;; names, atom and bond loops with quoted atom names, the base read from the ring by
;; position (every natural base, 5-aminothymidine, an abasic sugar, inosine- and
;; isoguanine-like bases), the signal order and the parent chain, the validation report,
;; the header, and the --check / --update modes through the command line. No network.

(ns extract-components-test
    (:require [babashka.fs :as fs]
        [clojure.java.io :as io]
        [clojure.string :as str]
        [clojure.test :refer [deftest is testing]]
        [extract-components :as ec]
        [helpers :as h])
    (:import (java.io BufferedReader StringReader)
        (java.util.zip GZIPOutputStream)))

;; --- building a dictionary

(defn- q
    "A CIF token: quoted when it holds a quote or a space."
    [s]
    (if (re-find #"['\s]" s) (str "\"" s "\"") s))

(defn- block-text
    "The CIF text of one component. Keys: `:id`, `:type` (default RNA LINKING), `:name`
    (a quoted value; with `:name-block` a `;` text block, with `:name-next` the quoted
    value on the line after an empty one), `:formula`, `:parent`, `:letter`, `:atoms`
    ([name element] ...) and `:bonds` ([a b] ...). A hydrogen is added to the first
    atom, which the reader must drop."
    [{:keys [id name-mode formula parent letter atoms bonds],
            typ :type,
            nm :name,
            :or {typ "RNA LINKING", formula "C1", parent "?", letter "?"}}]
    (let [id (str id)
            name-lines
            (case name-mode
                :block ["_chem_comp.name" (str ";" nm) "continued line" ";"]
                :next ["_chem_comp.name " (str "\"" nm "\"")]
                [(str "_chem_comp.name  " (if nm (str "\"" nm "\"") "?"))])]
        (str/join
            "\n"
            (concat [(str "data_" id) "# " (str "_chem_comp.id " id " ")]
                name-lines
                [(str "_chem_comp.type \"" typ "\"")
                    (str "_chem_comp.formula \"" formula "\"")
                    (str "_chem_comp.mon_nstd_parent_comp_id " parent)
                    (str "_chem_comp.one_letter_code " letter) "# " "loop_"
                    "_chem_comp_atom.comp_id" "_chem_comp_atom.atom_id"
                    "_chem_comp_atom.alt_atom_id" "_chem_comp_atom.type_symbol"]
                (for [[n e] (concat atoms [[(str "H" (rand-int 9)) "H"]])]
                    (str id " " (q n) " " (q n) " " e " 0 1 N"))
                ["# " "loop_" "_chem_comp_bond.comp_id" "_chem_comp_bond.atom_id_1"
                    "_chem_comp_bond.atom_id_2" "_chem_comp_bond.value_order"]
                (for [[a b] bonds] (str id " " (q a) " " (q b) " SING"))
                ["# "]))))

(defn- ring-bonds
    "The bonds closing the ring `names` into a cycle."
    [names]
    (map vector names (concat (rest names) [(first names)])))

(def ^:private sugar-atoms
    [["O4'" "O"] ["C1'" "C"] ["C2'" "C"] ["C3'" "C"] ["C4'" "C"] ["C5'" "C"]
        ["O3'" "O"]])

(def ^:private sugar-bonds
    (concat (ring-bonds ["C1'" "C2'" "C3'" "C4'" "O4'"])
        [["C4'" "C5'"] ["C3'" "O3'"]]))

(defn- pyrimidine
    "The atoms and bonds of a nucleoside with a pyrimidine: the oxygen on C2, the atom
    `c4` ([name element]) on C4 and, if given, `c5` on C5."
    [c4 c5]
    {:atoms (concat sugar-atoms
            [["N1" "N"] ["C2" "C"] ["N3" "N"] ["C4" "C"] ["C5" "C"]
                ["C6" "C"] ["O2" "O"] c4]
            (when c5 [c5])),
        :bonds (concat sugar-bonds
            [["C1'" "N1"]]
            (ring-bonds ["N1" "C2" "N3" "C4" "C5" "C6"])
            [["C2" "O2"] ["C4" (first c4)]]
            (when c5 [["C5" (first c5)]]))})

(defn- purine
    "The atoms and bonds of a nucleoside with a purine: `c6` ([name element]) on C6 and,
    if given, `c2` on C2."
    [c6 c2]
    {:atoms (concat sugar-atoms
            [["N9" "N"] ["C8" "C"] ["N7" "N"] ["C5" "C"] ["C4" "C"]
                ["N3" "N"] ["C2" "C"] ["N1" "N"] ["C6" "C"] c6]
            (when c2 [c2])),
        :bonds (concat sugar-bonds
            [["C1'" "N9"]]
            (ring-bonds ["N9" "C8" "N7" "C5" "C4"])
            [["C4" "N3"] ["N3" "C2"] ["C2" "N1"] ["N1" "C6"] ["C6" "C5"]]
            [["C6" (first c6)]]
            (when c2 [["C2" (first c2)]]))})

(def ^:private O4 ["O4" "O"])
(def ^:private N4 ["N4" "N"])
(def ^:private C5-methyl ["CM5" "C"])
(def ^:private C5-amine ["N5" "N"])

;; the base of each synthetic nucleoside as the ring reads it
(def ^:private nucleosides
    {"cytidine" [(pyrimidine N4 nil) "C"],
        "5-aminocytidine" [(pyrimidine N4 C5-amine) "C"],
        "uridine" [(pyrimidine O4 nil) :ut],
        "thymidine" [(pyrimidine O4 C5-methyl) :ut],
        "5-aminothymidine" [(pyrimidine O4 C5-amine) :ut],
        "adenosine" [(purine ["N6" "N"] nil) "A"],
        "guanosine" [(purine ["O6" "O"] ["N2" "N"]) "G"],
        "inosine-like" [(purine ["O6" "O"] nil) nil],
        "isoguanine-like" [(purine ["N6" "N"] ["O2" "O"]) nil],
        "abasic" [{:atoms (conj (vec sugar-atoms) ["O1'" "O"]),
                :bonds (conj (vec sugar-bonds) ["C1'" "O1'"])} nil]})

(defn- reader [text] (BufferedReader. (StringReader. text)))

(defn- blocks-of
    [& blocks]
    (ec/read-blocks (reader (str/join "\n" (map block-text blocks)))))

;; --- parsing

(deftest block-parsing
    (testing "quotes, text blocks, empty values, atoms with quoted names, hydrogens"
        (let [[b] (blocks-of (merge {:id "X1", :name "O'Neil", :name-mode :block}
                        (pyrimidine O4 nil)))]
            (is (= "O'Neil continued line" (get b "name")))
            (is (some #{["O4'" "O"]} (:atoms b)))
            (is (not-any? #(= "H" (second %)) (:atoms b)))
            (is (some #{["C1'" "N1"]} (:bonds b))))
        (is (= "ADENOSINE"
                (get (first (blocks-of
                            {:id "X2", :name "ADENOSINE", :name-mode :next}))
                    "name")))
        (testing "a component that is not a nucleic acid keeps no atoms"
            (is (nil? (:atoms (first (blocks-of {:id "X3",
                                    :type "NON-POLYMER",
                                    :atoms [["C" "C"]]}))))))
        (is (thrown-with-msg? clojure.lang.ExceptionInfo
                #"no _chem_comp.id"
                (ec/read-blocks (reader
                        "data_Q\n_chem_comp.type X\n"))))))

(deftest tokens
    (is (= ["X" "O5'" "H5''" "a b" "N"] (ec/tokens "X \"O5'\" \"H5''\" 'a b' N"))))

(deftest classes
    (testing "the word DNA or RNA decides, nothing else"
        (is (= ["dna" "dna" "rna" "rna" "rna" "other" "other"]
                (map ec/component-class
                    ["dna linking" "l-dna linking" "rna linking" "l-rna linking"
                        "rna oh 3 prime terminus" "non-polymer" "dnarna-like"])))))

(deftest unquoting
    (is (= ["a b" "a b" "ab" "'ab" "'" ""]
            (map ec/unquote-value ["'a b'" "\"a b\"" "ab" "'ab" "'" ""]))))

;; --- the base

(deftest ring-reads-the-base-by-position
    (doseq [[nm [structure expected]] nucleosides]
        (testing nm
            (is (= expected
                    (ec/ring-base (first (blocks-of (assoc structure :id "R")))))))))

(deftest ring-is-not-fooled
    (testing
        "an amine only at C5 is not a cytosine; no sugar and no base give nothing"
        (is (not= "C"
                (ec/ring-base
                    (first (blocks-of (assoc (pyrimidine O4 C5-amine) :id "R"))))))
        (is (nil? (ec/ring-base (first (blocks-of {:id "R",
                                :atoms [["C1" "C"]]})))))))

(deftest name-and-letter
    (is (= ["A" "G" "C" "T" "U" nil nil]
            (map ec/name-base
                ["adenosine" "2'-deoxyguanosine" "5-methylcytidine" "THYMIDINE"
                    "URIDINE-5'-MONOPHOSPHATE" "inosine"
                    "adenosine-guanosine dimer"])))
    (is (= ["A" "T" nil nil] (map ec/letter-base ["A" "t" "N" "?"]))))

(deftest parent-chain
    (let [parent-of {"TTD" "DT", "P1" "P2", "P2" "P1", "M" "TTD", "X" "DT, DA"}]
        (is (= "T" (ec/parent-base parent-of "DT, DT")))
        (is (= "T" (ec/parent-base parent-of "TTD")))
        (is (= "T" (ec/parent-base parent-of "M")))
        (is (nil? (ec/parent-base parent-of "X")))
        (is (nil? (ec/parent-base parent-of "P1")))
        (is (nil? (ec/parent-base parent-of "NOPE")))
        (is (nil? (ec/parent-base parent-of "-")))))

(deftest signal-order
    (let [infer (fn [m] (ec/infer-base (first (blocks-of (merge {:id "Z"} m)))))]
        (is (= ["C" "ring"] (infer (assoc (pyrimidine N4 nil) :name "unrelated"))))
        (is (= ["C" "letter"] (infer (assoc (pyrimidine N4 nil) :letter "C"))))
        (is (= ["C" "name"] (infer {:name "cytidine"})))
        (is (= ["-" "-"] (infer (assoc (pyrimidine N4 nil) :name "adenosine")))
            "ring and name disagree")
        (is (= ["T" "name"]
                (infer (assoc (pyrimidine O4 C5-methyl) :name "thymidine")))
            "a uracil or thymine ring takes the base from the name")
        (is (= ["-" "-"] (infer (pyrimidine O4 C5-methyl)))
            "...and decides nothing alone")
        (is (= ["-" "-"] (infer (assoc (pyrimidine O4 nil) :letter "A")))
            "a letter that is not U or T contradicts a uracil ring")
        (is (= ["-" "-"] (infer (assoc (purine ["O6" "O"] nil) :name "inosine"))))
        (is (= ["A" "self"] (infer {:id "DA"})))))

(deftest rows-with-bases
    (testing
        "declared parent first, non-nucleic acids '-', the five columns unchanged"
        (let [rows (ec/rows-of
                    (blocks-of
                        {:id "AAA", :type "DNA LINKING", :parent "DT, DT", :letter "A"}
                        {:id "BBB", :type "NON-POLYMER", :name "adenosine"}
                        (assoc (pyrimidine N4 nil) :id "CCC")
                        {:id "DDD", :parent "TTD"}
                        {:id "TTD", :parent "DT"}))
                by-id (into {} (map (juxt first identity) rows))]
            (is (= ["AAA" "dna" "dna linking" "DT, DT" "C1" "T" "parent"]
                    (by-id "AAA")))
            (is (= ["BBB" "other" "non-polymer" "-" "C1" "-" "-"] (by-id "BBB")))
            (is (= ["C" "ring"] (subvec (by-id "CCC") 5)))
            (is (= ["T" "parent"] (subvec (by-id "DDD") 5))))))

;; --- validation

(deftest validation-report
    (testing "each signal against the base the declared parent leads to"
        (let [blocks
                (blocks-of
                    (assoc (pyrimidine N4 nil)
                        :id "V1"
                        :parent "C"
                        :letter "C"
                        :name "cytidine")
                    (assoc (pyrimidine N4 nil) :id "V2" :parent "DA" :name "adenosine")
                    (assoc (pyrimidine O4 nil) :id "V3" :parent "U")
                    {:id "V4"})
                v (ec/validate blocks)]
            (is (= 3 (:total v)))
            (is (= {:found 1, :correct 1}
                    (select-keys (get-in v [:signals :letter]) [:found :correct])))
            (is (= {:found 2, :correct 1}
                    (select-keys (get-in v [:signals :ring]) [:found :correct])))
            (is (= {:found 2, :correct 2}
                    (select-keys (get-in v [:signals :name]) [:found :correct])))
            (is (= {:found 1, :correct 1} (:ring-ut v)))
            (is (h/contains-text? (ec/validation-text v)
                    "A -> C: 1   <-- wrong")))))

;; --- the table

(def ^:private cif
    (str/join
        "\n"
        ["data_ZZZ" "_chem_comp.id ZZZ" "_chem_comp.name \"x\""
            "_chem_comp.type NON-POLYMER" "_chem_comp.formula \"C2 H4 O3\""
            "_chem_comp.mon_nstd_parent_comp_id ?" "#" "loop_" "_chem_comp_atom.comp_id"
            "ZZZ C C C 0" "#" "data_DA" "_chem_comp.id DA" "_chem_comp.type 'DNA LINKING'"
            "_chem_comp.formula \"C10 H14 N5 O6 P\""
            "_chem_comp.mon_nstd_parent_comp_id ?" "#" "data_5MC" "_chem_comp.id 5MC"
            "_chem_comp.type \"RNA linking\"" "_chem_comp.formula \"C10 H16 N3 O8 P\""
            "_chem_comp.mon_nstd_parent_comp_id C" "#" "data_LR" "_chem_comp.id LR"
            "_chem_comp.type \"L-RNA LINKING\"" "_chem_comp.formula 'C9 H14 N3 O8 P'"
            "_chem_comp.mon_nstd_parent_comp_id ?" "#" "data_DT5" "_chem_comp.id DT5"
            "_chem_comp.type \"DNA OH 5 prime terminus\""
            "_chem_comp.formula \"C10 H15 N2 O7 P\""
            "_chem_comp.mon_nstd_parent_comp_id DT" "#" "data_TAB" "_chem_comp.id TAB"
            "_chem_comp.type \"PEPTIDE-LIKE\"" "_chem_comp.formula \"C1\tH2\""
            "_chem_comp.mon_nstd_parent_comp_id ?" "#" "data_BARE" "_chem_comp.id BARE"
            "_chem_comp.type SACCHARIDE" ""]))

(def ^:private expected-rows
    [["5MC" "rna" "rna linking" "C" "C10 H16 N3 O8 P" "C" "parent"]
        ["BARE" "other" "saccharide" "-" "?" "-" "-"]
        ["DA" "dna" "dna linking" "-" "C10 H14 N5 O6 P" "A" "self"]
        ["DT5" "dna" "dna oh 5 prime terminus" "DT" "C10 H15 N2 O7 P" "T" "parent"]
        ["LR" "rna" "l-rna linking" "-" "C9 H14 N3 O8 P" "-" "-"]
        ["TAB" "other" "peptide-like" "-" "C1 H2" "-" "-"]
        ["ZZZ" "other" "non-polymer" "-" "C2 H4 O3" "-" "-"]])

(deftest rows-of-a-dictionary
    (testing "quotes, ? parents, classes, tabs, missing fields, the base columns"
        (is (= expected-rows
                (sort-by first (ec/rows-of (ec/read-blocks (reader cif))))))))

(deftest table-text-sorted-with-header
    (testing "sorted by id, header counts the rows, duplicates are an error"
        (let [text (ec/table-text {:url "U", :source-date "D", :fetched "F"}
                    (reverse expected-rows))
                lines (str/split-lines text)]
            (is (= "# Source: U (Last-Modified D; fetched F)." (second lines)))
            (is (= "# Generated by dev/extract_components.clj; do not edit by hand."
                    (nth lines 4)))
            (is (= "# rows: 7" (nth lines 5)))
            (is (= "#id\tclass\ttype\tparent\tformula\tbase\tbase_source"
                    (nth lines 6)))
            (is (= (map #(str/join "\t" %) expected-rows) (drop 7 lines)))
            (is (str/ends-with? text "\n"))
            (is (= {:url "U", :source-date "D", :fetched "F"}
                    (ec/header-meta text)))
            (is (thrown-with-msg? clojure.lang.ExceptionInfo
                    #"occurs twice"
                    (ec/table-text {}
                        [["A" "other" "t" "-" "f"]
                            ["A" "other" "t" "-" "f"]]))))))

;; --- the command line

(defn- write-gz
    "Writes `text` gzip-compressed to `path`."
    [path text]
    (with-open [out (GZIPOutputStream. (io/output-stream (str path)))]
        (.write out (.getBytes ^String text "UTF-8"))))

(def ^:private opts
    ["--source-date" "Sat, 10 Oct 2026 05:56:05 GMT" "--fetched" "2026-10-14"])

(defn- tool [& args] (h/run-tool (str h/dev-dir "/extract_components.clj") args))

(deftest command-line
    (testing "stdout, --update, --check (stale and fresh) and --validate-inference"
        (let [scratch (h/scratch-dir)
                gz (str scratch "/c.cif.gz")
                out (str scratch "/out.tsv")]
            (try (write-gz gz cif)
                (let [{:keys [status], :as r} (apply tool gz opts)]
                    (is (= 0 status))
                    (is (h/contains-text?
                            (:out r)
                            "5MC\trna\trna linking\tC\tC10 H16 N3 O8 P\tC\tparent\n"))
                    (is (h/contains-text? (:out r) "# rows: 7\n")))
                (is (= 0 (:status (apply tool gz "--update" "--out" out opts))))
                (is (= 0 (:status (tool gz "--check" "--out" out))))
                ;; a changed row is reported and fails
                (h/write-file out (str/replace (slurp out) "C10 H14 N5 O6 P" "X"))
                (let [{:keys [status], text :out} (tool gz "--check" "--out" out)]
                    (is (= 1 status))
                    (is (h/contains-text? text "out of date"))
                    (is (h/contains-text? text "DA\tdna\tdna linking\t-\tX")))
                (let [{:keys [status], text :out} (tool gz "--validate-inference")]
                    (is (= 0 status))
                    (is (h/contains-text? text "validation on 2 nucleic acid")))
                (finally (fs/delete-tree scratch))))))
