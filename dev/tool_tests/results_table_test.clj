;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of results_table.clj: the bold rules for one row, the table-cell normalisation
;; behind --check, and --check itself on the real README (the table must be up to date).

(ns results-table-test
    (:require [clojure.test :refer [deftest is testing]]
        [helpers :as h]
        [results-table]))

(def ^:private row @#'results-table/row)
(def ^:private run-label @#'results-table/run-label)
(def ^:private table-cells @#'results-table/table-cells)

(defn ^:private report-dict
    "A parsed-report map with sensible defaults, overridden by the key/value pairs."
    [& kvs]
    (merge {:chi2 "+21.485",
            :chi2_cmp "+21.485",
            :rho_e "+0.34",
            :d1 "+0.04",
            :d2 "+1.67",
            :d3 "+0.50",
            :c1 "+1.201",
            :sat "false",
            :div "0.0000"}
        (apply hash-map kvs)))

(deftest row-plain
    (testing "nothing at a bound: no bold, a true minus sign, 3 significant digits"
        (is (= ["SASDX one" "21.5" "EOM 11.3" "−0.37" "1.67" "−2.50" "1.201" "0"]
                (row "SASDX one" (report-dict :d1 "-0.37" :d3 "-2.5") "EOM 11.3")))))

(deftest row-uses-measured-grid-chi2
    (testing
        "the table shows the comparison chi2 (the measured-grid one for a binned fit)"
        (is (= "1.2"
                (second
                    (row "r" (report-dict :chi2 "+0.9" :chi2_cmp "+1.2") "-"))))))

(deftest row-bounds
    (testing
        "contrasts within tolerance of their bounds are bold; rho_e 0.34 puts the
    delta-rho3 bounds at -11.33 and 2.833"
        (is (= ["r" "21.5" "-" "**1.99**" "**−9.97**" "**2.83**" "1.201" "0"]
                (row "r" (report-dict :d1 "+1.99" :d2 "-9.97" :d3 "+2.83") "-"))))
    (testing "the lower delta-rho3 bound"
        (is (= "**−11.30**" (nth (row "r" (report-dict :d3 "-11.30") "-") 5)))))

(deftest row-saturated-c1
    (is (= "**0.780 (saturated)**"
            (nth (row "r" (report-dict :c1 "+0.780" :sat "true") "-") 6))))

(deftest row-divergences
    (testing "divergences print as a percentage, bold above 5 %"
        (is (= ["0.3 %" "**6.0 %**" "5.0 %"]
                (for [d ["0.0030" "0.0600" "0.0500"]]
                    (nth (row "r" (report-dict :div d) "-") 7))))))

(deftest table-cells-normalisation
    (testing "padding, spacing and the separator row do not matter"
        (is (= (table-cells
                    "| A   |  b  | c |\n| --- | :-: | -- |\n|  1  | 2   |  3 |")
                (table-cells "|A|b|c|\n|---|---|---|\n|1|2|3|"))))
    (testing "a changed cell is a difference"
        (is (not= (table-cells "| a | 1 |") (table-cells "| a | 2 |")))))

(deftest labels
    (testing "run labels from a folder and a section title"
        (is (= ["SASDMJ9 —" "SASDBS6 fit2_model1"]
                [(run-label "SASDMJ9" "SASDMJ9")
                    (run-label "SASDBS6" "fit2_model1")]))))

(deftest check-readme
    (testing "the Results table of fitting_tests/README.md is up to date"
        (let [{:keys [status out]} (h/run-tool (str h/dev-dir "/results_table.clj")
                    "--check")]
            (is (= 0 status))
            (is (h/contains-text? out "is up to date"))))
    (testing "--check covers the whole table"
        (is (= 2
                (:status (h/run-tool (str h/dev-dir "/results_table.clj")
                        "--check"
                        "SASDMJ9"))))))
