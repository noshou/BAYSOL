;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of compare.clj: its numeric helpers, and a golden file for its per-fit CSV (the
;; CSV produced from the committed reports of three fixed revisions equals the one
;; verified against the original Python tool).

(ns compare-test
    (:require [babashka.fs :as fs]
        [clojure.string :as str]
        [clojure.test :refer [deftest is testing]]
        [common :as c]
        [compare]
        [helpers :as h]
        [report]))

(deftest median
    (is (= [2 2.5] [(compare/median [3 1 2]) (compare/median [4 1 3 2])])))

(deftest pct
    (testing "linear interpolation between order statistics"
        (is (= [3.0 2.0 5.0 7.0]
                [(compare/pct [1 2 3 4 5] 0.5) (compare/pct [1 2 3 4 5] 0.25)
                    (compare/pct [1 2 3 4 5] 1.0) (compare/pct [7] 0.3)]))))

(deftest commas
    (testing "thousands separators"
        (is (= ["4,782" "1,234,567.89" "12.3" "-4,782"]
                [(compare/commas 4782.4 0) (compare/commas 1234567.891 2)
                    (compare/commas 12.3 1) (compare/commas -4782.4 0)]))))

(deftest ratio
    (testing "a ratio, or n/a when a side is missing or zero"
        (is (= ["2.00x" "n/a" "n/a" "n/a"]
                [(compare/ratio 6 3) (compare/ratio nil 3) (compare/ratio 6 0)
                    (compare/ratio 0 3)]))))

(deftest dash
    (testing "formatting with a dash for empty"
        (is (= ["3.14" "-" "-"]
                [(compare/dash "%.2f" 3.14159) (compare/dash "%.2f" "")
                    (compare/dash "%.2f" nil)]))))

(deftest total
    (testing "a sum over reports, nil when no report has the field"
        (let [reports {"a" {:x "1.5", :y ""}, "b" {:x "2.5", :y ""}}
                total-of @#'compare/total]
            (is (= [4.0 nil] [(total-of reports :x) (total-of reports :y)])))))

(deftest csv-golden
    (when (h/git-history?)
        (testing
            "the per-fit CSV for three fixed revisions equals the verified golden file"
            (let [out (str (h/scratch-dir) "/cmp.csv")
                    {:keys [status]} (h/run-tool (str h/dev-dir "/compare.clj")
                        "30f55ea" "81cf301"
                        "24af397" "--no-tree"
                        "--csv" out)]
                (is (= 0 status))
                (is (= (c/slurp8 (str h/data-dir "/compare_golden.csv"))
                        (c/slurp8 out)))
                (fs/delete-tree (fs/parent out))))))

(deftest unknown-revision
    (testing "an unknown revision stops with status 1 and names the tags"
        (let [{:keys [status out]} (h/run-tool (str h/dev-dir "/compare.clj")
                    "no-such-rev")]
            (is (= 1 status))
            (is (h/contains-text? out "unknown git revision 'no-such-rev'")))))

(deftest default-is-latest-release
    (when (h/git-history?)
        (testing "with no revision the baseline is the latest release tag"
            (let [{:keys [status out]} (h/run-tool (str h/dev-dir "/compare.clj"))]
                (is (= 0 status))
                (is (h/contains-text? out
                        (str "baseline: "
                            (c/latest-release)
                            ", the latest release")))))))

;; --- the stages of the nucleotide work (timing sections: data/timing_*.txt, see
;; report_test.clj)

(defn- report-with
    "res_current.txt before its timing section, then the section in the test-data file
    `timing` (nil: res_current.txt as it is, a report without the new stages)."
    [timing]
    (let [text (c/slurp8 (str h/data-dir "/res_current.txt"))]
        (report/parse (if timing
                (str (first (str/split text #"(?m)^=== Timing ===" 2))
                    (c/slurp8 (str h/data-dir "/" timing)))
                text))))

(defn- timing-text
    "The timing table `compare` prints for the revisions `names` (name -> one fit)."
    [names reports]
    (with-out-str (@#'compare/timing-table
            (into {} (for [[n r] (map vector names reports)] [n {"fit" r}]))
            names)))

(defn- cells-of
    "The cells of the table row labelled `label` in `text`."
    [text label]
    (some (fn [line]
            (let [cells (map str/trim (str/split line #"\|"))]
                (when (= label (nth cells 1 nil)) (vec (drop 2 cells)))))
        (str/split-lines text)))

(deftest timing-table-new-stages
    (let [old (report-with nil)
            text (timing-text ["old" "new"] [old (report-with "timing_nucleic.txt")])]
        (testing
            "a stage the old report lacks is missing (-), not zero, and ratios n/a"
            (doseq [label ["components" "structure checks" "classify"
                        "modified nucleotide hydrogens" "heavy atoms"]]
                (is (= ["-" "n/a"] ((juxt first #(nth % 2)) (cells-of text label)))
                    label)))
        (testing "the stage the new report has is there, with its own time"
            (is (= "0.00 s" (second (cells-of text "components"))))
            (is (= "0.02 s"
                    (second (cells-of text "modified nucleotide hydrogens")))))
        (testing
            "the pdb2pqr row is the variant's time, propka (not run) is missing"
            (is (= ["0.00 s" "0.01 s"]
                    (take 2 (cells-of text "pdb2pqr (any variant)"))))
            (is (= "-" (second (cells-of text "propka")))))
        (testing "the wall clock row excludes the external tools"
            (is (= "0.38 s"
                    (second (cells-of
                            text
                            "wall clock excl. PROPKA/pdb2pqr/downloads")))))))

(deftest timing-table-stage-dropped
    (testing
        "the reverse (the judged revision lacks a stage the old one has) is fine too"
        (let [text (timing-text ["old" "new"]
                    [(report-with "timing_mixed.txt")
                        (report-with nil)])]
            (is (= ["0.01 s" "-"] (take 2 (cells-of text "heavy atoms"))))
            (is (= "n/a" (nth (cells-of text "heavy atoms") 2))))))

(deftest stage-total-absent
    (testing "a benchmark run without a stage shows it missing; variants are summed"
        (let [fit {:stage_name ["propka" "pdb2pqr (mixed, propka)"
                        "pdb2pqr (nucleic, none)" "load_molecule"],
                    :stage_seconds [1.0 2.0 3.0 4.0]}
                summed (@#'compare/stage-total fit :stage_seconds "pdb2pqr")]
            (is (= 5.0 summed))
            (is (nil? (@#'compare/stage-total fit :stage_seconds "components")))
            (is (= 1.0 (@#'compare/stage-total fit :stage_seconds "propka"))))
        (is (= "-"
                (compare/dash
                    "%.2f"
                    (@#'compare/stage-total {} :stage_seconds "propka"))))))

(deftest notes-table
    (let [shown (fn [pairs]
                (with-out-str
                    (@#'compare/notes-table (into (sorted-map) pairs) "new")))
            nucleic (report-with "timing_nucleic.txt")
            mixed (report-with "timing_mixed.txt")
            hit (-> (c/slurp8 (str h/data-dir "/timing_protein.txt"))
                (str/replace "cache miss" "cache hit"))
            protein-hit (report/parse (str (first (str/split
                            (c/slurp8 (str h/data-dir
                                    "/res_current.txt"))
                            #"(?m)^=== Timing ==="
                            2))
                    hit))]
        (testing "nucleic and mixed fits get a line with their notes"
            (let [text (shown {"fitting_tests/A/res.txt" nucleic,
                            "fitting_tests/B/res.txt" mixed})]
                (is (h/contains-text? text "[nucleic: AMBER, titration none]"))
                (is (h/contains-text? text "[mixed: PARSE, titration propka]"))
                (is (h/contains-text?
                        text
                        "14 residues: 14 hydrogenated through their base"))
                (is (h/contains-text?
                        text
                        "[17 residue names: 17 builtin, 0 cache, 0 download]"))))
        (testing
            "a protein-only fit with every cache hit, and an old report, get none"
            (is (h/contains-text? (shown {"p" protein-hit, "o" (report-with nil)})
                    "every fit is protein-only")))
        (testing "a cache miss is shown"
            (is (h/contains-text? (shown {"p" (report-with "timing_protein.txt")})
                    "[cache miss]")))))

(deftest timing-table-modified-amino
    (testing "an old report lacks the stage: -, n/a; the new one shows its time"
        (let [text (timing-text ["old" "new"]
                    [(report-with nil)
                        (report-with "timing_protein_mse.txt")])
                cells (cells-of text "modified amino acid hydrogens")]
            (is (= ["-" "0.02 s" "n/a"] (take 3 cells)))
            (is (= "-" (first (cells-of text "modified nucleotide hydrogens"))))))
    (testing "bench: the two modified stages are summed separately"
        (let [fit {:stage_name ["modified nucleotide hydrogens"
                        "modified amino acid hydrogens"],
                    :stage_seconds [1.0 2.0]}
                st @#'compare/stage-total]
            (is (= [1.0 2.0]
                    [(st fit :stage_seconds "modified nucleotide hydrogens")
                        (st fit :stage_seconds "modified amino acid hydrogens")]))))
    (testing "the notes table shows its note for a run that is notable otherwise"
        (let [r (report-with "timing_mixed_mse.txt")
                text (with-out-str (@#'compare/notes-table {"fit" r} "new"))]
            (is (h/contains-text? text "20 hydrogenated through their parent")))))
