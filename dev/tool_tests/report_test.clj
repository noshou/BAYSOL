;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of report.clj: one real report in the current format and one in the v0.2.0
;; format (which lacks the MAP-search lines), with every parsed field checked.

(ns report-test
    (:require [clojure.string :as str]
        [clojure.test :refer [deftest is testing]]
        [common :as c]
        [helpers :as h]
        [report]))

(defn ^:private fields
    "The values of `ks` in the report `file` of the test data, as printed."
    [file ks]
    (let [r (report/parse (c/slurp8 (str h/data-dir "/" file)))]
        (mapv #(c/num-str (r %)) ks)))

(deftest parse-current
    (testing "the current report format"
        (is (= ["+0.868097" "+1.2486" "false" "+0.336156" "-1.09317" "+1.95561"
                    "-5.67044" "0.0000" "5.70" "2.52" "0.9019" "0.9579" "15.37" "2.67"
                    "3.05" "0.68" "4.2" "12170.0" "0.5" "6.11" "-0.792701" "2" "15.37"]
                (fields "res_current.txt"
                    [:chi2 :c1 :sat :rho_e :d1 :d2 :d3 :div :steps :depth :accept
                        :ebfmi :wall :fwd :map_s :reprofile :gc :leapfrog :ms_step
                        :nuts :z3 :n_modes :wall_ex])))))

(deftest parse-v0.2.0
    (testing "the v0.2.0 format: fields it lacks are empty, the others parse"
        (is (= ["+1.13124" "+1.12324" "+1.97557" "-2.15674" "-9.83588" "6.18"
                    "56.43" "24.17" "" "" "15200.0" "27.27" "-2.11641" "56.43"]
                (fields "res_v020.txt"
                    [:chi2 :c1 :d1 :d2 :d3 :steps :wall :fwd :map_s :n_modes
                        :leapfrog :nuts :z3 :wall_ex])))))

(deftest parse-shannon
    (testing
        "a Shannon-binned report: chi2 is the fit's own, chi2_raw the measured-grid
    one, chi2_cmp the latter"
        (is (= ["+0.912345" "0.951234" "0.951234" "+1.2486" "-5.67044"]
                (fields "res_shannon.txt" [:chi2 :chi2_raw :chi2_cmp :c1 :d3])))))

(deftest chi2-cmp-without-raw
    (testing
        "an older report has no measured-grid line: chi2_cmp falls back to chi2"
        (is (= ["" "+0.868097"] (fields "res_current.txt" [:chi2_raw :chi2_cmp])))))

(deftest count-suffixes
    (testing "iteration and leapfrog counts with k and M suffixes"
        (is (= [496680.0 12400.0 1200000.0 750.0]
                (map @#'report/qty ["496.68k" "12.4k" "1.2M" "750"])))))

(deftest number-trap
    (testing "a number capture keeps all its digits"
        (is (=
                "215.45"
                (@#'report/grab "mean_n_steps   = 215.45" #"^mean_n_steps\s+= @N@")))))

(deftest parse-all-lines
    (testing "every line of the report parses"
        (is (= ["2592" "32" "1803" "121" "1000" "300" "63.9" "10.0" "12" "1803"
                    "121" "0" "700" "0.9094" "2.51" "3" "5.72" "1.1027" "0.0029" "false"
                    "0.0000" "+152.294" "+0.336164" "-5.99051" "+0.873836" "16" "84"]
                (fields "res_chains.txt"
                    [:n_atoms :lMax :n_q_raw :n_q :n_samples :n_adapt :dmax
                        :channels :rebin_per_channel :rebin_measured :rebin_fitted
                        :rebin_dropped :iterations :accept :depth :depth_max :steps
                        :ebfmi :cavity_frac :sat :div :lgdn_MAP :rho_e_MAP :dro3_MAP
                        :chi2_MAP :quantile_lo :quantile_hi])))))

(deftest parse-tables
    (testing "the quantile, bound and z-score columns of every parameter"
        (is (= ["+148.612" "+151.649" "+148.614" "+151.648" "-8.49667" "-2.09783"
                    "+9.2958e-06" "+1.24652" "+0.876655" "+0.287019" "+3.90118"
                    "-0.0218302"]
                (fields "res_chains.txt"
                    [:lgdn_QUANT_LO :lgdn_QUANT_HI :lgdn_BOUND_LO :lgdn_BOUND_HI
                        :dro3_QUANT_LO :dro3_BOUND_HI :scale_QUANT_HI :excl_BOUND_LO
                        :chi2_BOUND_HI :rho_e_Z_MAP :dro2_Z_QUANT_LO
                        :dro3_Z_QUANT_HI])))))

(deftest parse-timing-stages
    (testing "every stage of the timing table, the MAP search and NUTS metadata"
        (is (= ["0.13" "6.4e-05" "9.4e-04" "1.1e-05" "6.8e-03" "0.03" "4.3e-03"
                    "0.09" "0.07" "0.02" "6.7e-04" "1.8e-04" "0.72" "0.02" "2.0e-04"
                    "0.64" "6.0e-03" "0.06" "0.11" "0.62" "0.01" "8" "8" "2" "4000"
                    "18420.0" "0.1" "3000"]
                (fields "res_chains.txt"
                    [:static_build :resolve_structure :propka :pdb2pqr
                        :load_molecule :sasa :shannon :fwd :vacuum_excluded
                        :hydration :gram_rm :seed_fitting :sampling :map_s
                        :nuts_setup :nuts :reprofile :map_quantiles :report_write
                        :unaccounted :gc :map_starts_ok :map_starts_total :map_modes
                        :nuts_iters :leapfrog :ms_per_step :draws])))))

(deftest parse-chains
    (testing
        "the chain lines: pooled and total, dropped, the worst R-hat and the smallest ESS"
        (is (= ["3" "4" "1" "1.0032" "1843" "1211"]
                (fields "res_chains.txt"
                    [:chains_pooled :chains_total :chains_dropped :rhat_max
                        :ess_min :ess_tail_min])))))

(deftest parse-modes
    (testing "the modes line and the shares of the modes"
        (is (= ["2" "0.81" "0.19"]
                (fields "res_chains.txt" [:modes :mode_share_max :mode_share_min])))
        (testing
            "a mode with a tiny share is printed in scientific notation and still parsed"
            (is (= ["2" "1.0" "7.1e-10"]
                    (fields "res_chains_negligible.txt"
                        [:modes :mode_share_max :mode_share_min]))))))

(deftest parse-optima (is (= ["2"] (fields "res_optima.txt" [:optima]))))

(deftest parse-chains-absent
    (testing "a report from before the chains has none of them"
        (is (= ["" "" "" "" "" "0" "" ""]
                (fields "res_current.txt"
                    [:chains_pooled :chains_total :rhat_max :ess_min
                        :ess_tail_min :chains_dropped :modes :mode_share_max])))))

(deftest keys-keep-their-first-seen-order
    (testing "the order metadata starts with the one-line entries"
        (let [r (report/parse (c/slurp8 (str h/data-dir "/res_current.txt")))]
            (is (= [:n_atoms :lMax :n_q_raw] (take 3 (:order (meta r)))))
            (is (apply distinct? (:order (meta r)))))))

;; --- the stages of the nucleotide work. The timing sections in data/timing_*.txt are the
;; ones `Pipeline._write_timing` printed for a seed build (no sampling) of the fixtures
;; 1EHZ (nucleic acid with modified nucleotides), 3HDD (protein + DNA) and 1CRN (protein
;; only); note how a name longer than the label column touches its note.

(defn ^:private report-with
    "The text of res_current.txt before its timing section, then the timing section in
    the file `timing` of the test data."
    [timing]
    (str (first (str/split (c/slurp8 (str h/data-dir "/res_current.txt"))
                #"(?m)^=== Timing ==="
                2))
        (c/slurp8 (str h/data-dir "/" timing))))

(defn ^:private near? [a b] (< (Math/abs (- (double a) (double b))) 1e-9))

(def ^:private new-stages
    [:components :components_download :structure_checks :classify
        :modified_hydrogens :heavy_atoms])

(deftest nucleotide-stages-nucleic
    (testing
        "a nucleic-acid run: no PROPKA, the AMBER hydrogenation, modified residues"
        (let [r (report/parse (report-with "timing_nucleic.txt"))]
            (is (= ["6.4e-04" "0" "0.01" "2.7e-03" "0.02" "0.03"]
                    (mapv r new-stages)))
            (is (= ["" "0.01" "0.02" "0.20" "0.39"]
                    (mapv r [:propka :pdb2pqr :load_molecule :static_build :wall])))
            (testing
                "pdb2pqr (nucleic, none) is the pdb2pqr key; wall_ex drops only it"
                (is (near? 0.38 (r :wall_ex)))))))

(deftest nucleotide-stages-mixed
    (testing
        "a protein + nucleic run: PROPKA and pdb2pqr (mixed, propka), no modified"
        (let [r (report/parse (report-with "timing_mixed.txt"))]
            (is (= ["6.5e-04" "0" "4.3e-03" "1.5e-03" "" "9.7e-03"]
                    (mapv r new-stages)))
            (is (= ["1.0e-03" "0.04"] (mapv r [:propka :pdb2pqr])))
            (is (near? (- 0.32 0.001 0.04) (r :wall_ex))))))

(deftest nucleotide-stages-protein
    (testing
        "a protein-only run: PROPKA and pdb2pqr as before, the new stages present"
        (let [r (report/parse (report-with "timing_protein.txt"))]
            (is (= ["2.3e-04" "0" "8.0e-04" "3.0e-04" "" "1.9e-03"]
                    (mapv r new-stages)))
            (is (near? (- 0.91 0.89 0.000017) (r :wall_ex))))))

(deftest wall-ex-download
    (testing
        "a component download counts as external time, a lookup without one does not"
        (let [text (report-with "timing_nucleic.txt")
                downloaded (-> text
                    (str/replace "0 cache, 0 download]"
                        "0 cache, 1 download]")
                    (str/replace "6.4e-04" "0.25"))
                r (report/parse downloaded)]
            (is (= ["0.25" "1"] (mapv r [:components :components_download])))
            (is (near? (- 0.39 0.01 0.25) (r :wall_ex)))
            (is (near? 0.38 (:wall_ex (report/parse text)))
                "0 downloads: the table load stays in the wall clock"))))

(deftest wall-ex-without-the-new-stages
    (testing
        "a report without them gives the numbers it always gave; the keys are empty"
        (let [r (report/parse (c/slurp8 (str h/data-dir "/res_current.txt")))]
            (is (= (repeat 6 "") (map r new-stages)))
            (is (= 15.37 (r :wall_ex)))))
    (testing
        "the same report, a nucleic run's stages added: only its pdb2pqr time goes"
        (let [r (report/parse (report-with "timing_nucleic.txt"))]
            (is (near? (- (c/as-number (r :wall)) (c/as-number (r :pdb2pqr)))
                    (r :wall_ex))))))

(deftest stage-notes-parse
    (testing "the notes of a nucleic run, the glued ones included"
        (is (= {"components" "[17 residue names: 17 builtin, 0 cache, 0 download]",
                    "structure checks"
                    (str "[0 chains relabelled, 0 duplicate atoms dropped, "
                        "0 dummy-like findings]"),
                    "classify" "[nucleic: AMBER, titration none]",
                    "pdb2pqr (nucleic, none)" "[cache hit]",
                    "modified nucleotide hydrogens"
                    (str
                        "[14 residues: 14 hydrogenated through their base, 0 without a "
                        "base; 149 hydrogens placed, 232 in the free "
                        "components' formulas]"),
                    "heavy atoms" "[1821 in, 1821 out; 1 restored, 0 added by pdb2pqr]"}
                (report/stage-notes (c/slurp8 (str h/data-dir
                            "/timing_nucleic.txt"))))))
    (testing "mixed and protein runs"
        (is (= {"classify" "[mixed: PARSE, titration propka]",
                    "propka" "[cache hit]",
                    "pdb2pqr (mixed, propka)" "[cache hit]"}
                (select-keys (report/stage-notes
                        (c/slurp8 (str h/data-dir "/timing_mixed.txt")))
                    ["classify" "propka" "pdb2pqr (mixed, propka)"])))
        (is (= {"classify" "[protein: PARSE, titration propka]",
                    "propka" "[cache miss]",
                    "pdb2pqr" "[cache hit]"}
                (select-keys (report/stage-notes
                        (c/slurp8 (str h/data-dir "/timing_protein.txt")))
                    ["classify" "propka" "pdb2pqr"]))))
    (testing
        "an older report has only the propka and pdb2pqr notes; no section: none"
        (is (= {"propka" "[cache hit]", "pdb2pqr" "[cache hit]"}
                (report/stage-notes (c/slurp8 (str h/data-dir "/res_current.txt")))))
        (is (= {} (report/stage-notes "n_atoms = 3\n"))))
    (testing "parse carries them without making them a TSV column"
        (let [r (report/parse (report-with "timing_nucleic.txt"))]
            (is (= "[nucleic: AMBER, titration none]"
                    (get-in r [:stage_notes "classify"])))
            (is (not (some #{:stage_notes} (:order (meta r))))))))

;; --- modified amino acids: data/timing_protein_mse.txt is a protein with one MSE
;; (HETATM, synthetic), data/timing_mixed_mse.txt SASDH39 (protein + DNA, 20 MSE); both
;; are the unedited output of `Pipeline._write_timing`. `modified amino acid hydrogens`
;; is longer than the label column, so its note touches the name.

(deftest modified-amino-stage
    (testing "a protein-only run with modified amino acids"
        (let [r (report/parse (report-with "timing_protein_mse.txt"))]
            (is (= ["0.02" ""]
                    (mapv r [:modified_amino_hydrogens :modified_hydrogens])))
            (is (= ["0.03" "2.59" "8.6e-04"]
                    (mapv r [:heavy_atoms :pdb2pqr :propka])))
            (is (near? (- 3.39 0.00086 2.59) (r :wall_ex)))))
    (testing "a mixed run; pdb2pqr (mixed, propka) is the pdb2pqr key"
        (let [r (report/parse (report-with "timing_mixed_mse.txt"))]
            (is (= ["0.01" "7.56"] (mapv r [:modified_amino_hydrogens :pdb2pqr])))
            (is (near? (- 8.86 0.003 7.56) (r :wall_ex)))))
    (testing
        "the two modified stages are separate keys; a run without either has both empty"
        (let [r (report/parse (report-with "timing_nucleic.txt"))]
            (is (= ["0.02" ""]
                    (mapv r [:modified_hydrogens :modified_amino_hydrogens]))))
        (let [r (report/parse (report-with "timing_protein.txt"))]
            (is (= ["" ""]
                    (mapv r [:modified_hydrogens :modified_amino_hydrogens])))))
    (testing "the glued note"
        (is (= (str "[1 residues: 1 hydrogenated through their parent, "
                    "0 without a parent; 9 hydrogens placed]")
                (get (report/stage-notes (c/slurp8 (str h/data-dir
                                "/timing_protein_mse.txt")))
                    "modified amino acid hydrogens")))
        (is (= (str "[20 residues: 20 hydrogenated through their parent, "
                    "0 without a parent; 183 hydrogens placed]")
                (get (report/stage-notes (c/slurp8 (str h/data-dir
                                "/timing_mixed_mse.txt")))
                    "modified amino acid hydrogens")))))

;; --- the notes on a line of their own (today's layout), data/timing_notes_own_line.txt
(deftest stage-notes-own-line
    (testing "the note under its stage; a stage without one has none"
        (is (= {"components" "[21 residue names: 21 builtin, 0 cache, 2 download]",
                    "classify" "[protein: PARSE, titration propka]",
                    "pdb2pqr (nucleic, none)" "[cache hit]"}
                (report/stage-notes (c/slurp8 (str h/data-dir
                            "/timing_notes_own_line.txt"))))))
    (testing
        "the download count and the stage seconds are read across the two lines"
        (let [r (report/parse (report-with "timing_notes_own_line.txt"))]
            (is (= ["2" "2.7e-03" "0.04"]
                    (mapv r [:components_download :components :pdb2pqr])))
            (is (= "0.10" (r :sasa))))))

(deftest stage-notes-wrapped
    (testing "a note wrapped over lines is joined; the next stage is not swallowed"
        (let [text (str "=== Timing ===     seconds\n"
                    "    heavy atoms        0.04\n"
                    "      [1821 in, 1821 out; 1 restored,\n"
                    "      0 added by pdb2pqr]\n"
                    "    SASA               0.10\n")]
            (is (= {"heavy atoms"
                        "[1821 in, 1821 out; 1 restored, 0 added by pdb2pqr]"}
                    (report/stage-notes text))))))

(deftest plot-timing
    (testing
        "the last two lines of the timing table, and the plotting left out of wall_ex"
        (let [text (str (report-with "timing_protein.txt")
                    "fit timing  = 0.8 s\nplot timing = 0.1 s\n")
                r (report/parse text)
                old (report/parse (report-with "timing_protein.txt"))]
            (is (= ["0.8" "0.1"] (mapv r [:fit_timing :plot_timing])))
            (is (= ["" ""] (mapv old [:fit_timing :plot_timing]))
                "a report from before plotting has neither, and is read as it was")
            (is (near? (- (old :wall_ex) 0.1) (r :wall_ex))))))
