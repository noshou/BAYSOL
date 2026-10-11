;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of compare.clj: its numeric helpers, and a golden file for its per-fit CSV (the
;; CSV produced from the committed reports of three fixed revisions equals the one
;; verified against the original Python tool).

(ns compare-test
    (:require [babashka.fs :as fs]
        [clojure.test :refer [deftest is testing]]
        [common :as c]
        [compare]
        [helpers :as h]))

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
                    {:keys [status]} (h/run-tool (str h/utils-dir "/compare.clj")
                        "30f55ea" "81cf301"
                        "24af397" "--no-tree"
                        "--csv" out)]
                (is (= 0 status))
                (is (= (c/slurp8 (str h/data-dir "/compare_golden.csv"))
                        (c/slurp8 out)))
                (fs/delete-tree (fs/parent out))))))

(deftest unknown-revision
    (testing "an unknown revision stops with status 1 and names the tags"
        (let [{:keys [status out]} (h/run-tool (str h/utils-dir "/compare.clj")
                    "no-such-rev")]
            (is (= 1 status))
            (is (h/contains-text? out "unknown git revision 'no-such-rev'")))))

(deftest default-is-latest-release
    (when (h/git-history?)
        (testing "with no revision the baseline is the latest release tag"
            (let [{:keys [status out]} (h/run-tool (str h/utils-dir
                            "/compare.clj"))]
                (is (= 0 status))
                (is (h/contains-text? out
                        (str "baseline: "
                            (c/latest-release)
                            ", the latest release")))))))
