;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of report.clj: one real report in the current format and one in the v0.2.0
;; format (which lacks the MAP-search lines), with every parsed field checked.

(ns report-test
    (:require [clojure.test :refer [deftest is testing]]
        [common :as c]
        [helpers :as h]
        [report]))

(defn- fields
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
