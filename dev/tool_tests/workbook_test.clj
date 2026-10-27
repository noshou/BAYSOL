;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of workbook.clj (reading an .xlsx), on a small workbook written by the pipeline.

(ns workbook-test
    (:require [clojure.test :refer [deftest is testing]]
        [helpers :as h]
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
