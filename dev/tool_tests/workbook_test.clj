;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of workbook.clj (reading an .xlsx) and of report/parse-run (a run's numbers
;; from its workbook and timing file), on a small workbook written by the pipeline.

(ns workbook-test
    (:require [clojure.test :refer [deftest is testing]]
        [common :as c]
        [helpers :as h]
        [report]
        [workbook]))

(def ^:private xlsx (str h/data-dir "/run_current.xlsx"))

(deftest sheets
    (testing "every sheet is read, with its header row and its text"
        (let [s (workbook/read-file xlsx)]
            (is (= ["map" "modes" "quantiles_16-84" "run" "stdev_from_prior"]
                    (sort (keys s))))
            (is (= ["key" "value"] (first (s "run"))))
            (is (= ["n_atoms" "2592"] (second (s "run"))))
            (is (= ["parameter" "quantile_lo" "quantile_hi" "bound_lo" "bound_hi"]
                    (first (s "quantiles_16-84")))))))

(deftest parse-run
    (let [r (report/parse-run (workbook/read-file xlsx)
                (c/slurp8 (str h/data-dir
                        "/run_current_timings.txt")))]
        (testing "the run sheet"
            (is (= ["2592" "32" "12" "5" "false"]
                    (mapv #(c/num-str (r %))
                        [:n_atoms :lMax :rebin_per_channel :depth_max :sat]))))
        (testing "the MAP, with the keys the tools compare"
            (is (= (c/as-number (r :chi2_MAP))
                    (c/as-number (r :chi2_cmp))
                    (c/as-number (r :chi2))))
            (is (= (r :dro3_MAP) (r :d3))))
        (testing "the quantile label, the bounds and the z-scores"
            (is (= ["16" "84"] [(r :quantile_lo) (r :quantile_hi)]))
            (is (seq (r :dro3_QUANT_LO)))
            (is (= (r :dro3_Z_MAP) (r :z3))))
        (testing "the modes' shares"
            (is (= [0.75 0.25] [(r :mode_share_max) (r :mode_share_min)])))
        (testing "the timings come from the timing file"
            (is (= "3.00" (r :wall)))
            (is (= "0.40" (r :plot_timing)))
            (is (= 2.5597 (r :wall_ex)))
            (is (= "[cache hit]" ((r :stage_notes) "propka"))))))
