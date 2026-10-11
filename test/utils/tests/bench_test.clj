;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of bench.clj. No benchmark is run: the approval guard is tested by running the
;; script WITHOUT --approved (it must print its plan and do nothing), and the rest are the
;; pure functions.

(ns bench-test
    (:require [babashka.fs :as fs]
        [clojure.test :refer [deftest is testing]]
        [bench]
        [helpers :as h]))

(deftest guard-prints-plan-only
    (testing "without --approved the script refuses and says what it would run"
        (let [{:keys [status out]} (h/run-tool (str h/utils-dir "/bench.clj")
                    "--state"
                    "cold"
                    "SASDMJ9")]
            (is (= 0 status))
            (is (h/contains-text? out "not running"))
            (is (h/contains-text? out "Planned: --state cold SASDMJ9"))
            (is (not (h/contains-text? out "cold state in"))))))

(deftest guard-also-for-warm
    (testing "the warm state needs approval too"
        (let [{:keys [status out]} (h/run-tool (str h/utils-dir "/bench.clj")
                    "--state" "warm"
                    "SASDMJ9" "SASDBS6:fit2_model3")]
            (is (= 0 status))
            (is (h/contains-text? out "not running")))))

(deftest parse-args
    (testing "options with a value, the --keep flag, and positional specs"
        (is (= {:opts {"state" "cold", "keep" 1, "samples" "5"},
                    :specs ["SASDMJ9" "SASDBS6:fit2_model3"]}
                (bench/parse-args ["--state" "cold" "--keep" "--samples" "5"
                        "SASDMJ9" "SASDBS6:fit2_model3"]))))
    (testing "an option without its value stops with status 2"
        (let [{:keys [status out]} (h/run-tool (str h/utils-dir "/bench.clj")
                    "--approved"
                    "SASDMJ9"
                    "--out")]
            (is (= 2 status))
            (is (h/contains-text? out "option --out needs a value")))))

(deftest excluded
    (testing "what the cold state's repository copy leaves out"
        (is (= [true true true true true false false false false]
                (map bench/excluded?
                    ["docs/x.md" "test/visualize/xyz/a.xyz"
                        "test/baselines/results/r.json"
                        "test/fitting_tests/SASDMJ9/res.txt"
                        "test/fitting_tests/SASDMJ9/res_hist.png"
                        "test/fitting_tests/SASDMJ9/SASDMJ9.jl"
                        "src/Inference/Inference.jl" "test/baselines/README.md"
                        "test/utils/bench.clj"])))))

(deftest make-depot-links-only-sources
    (testing "the cold depot links source dirs and has no compiled/ cache"
        (let [scratch (h/scratch-dir)]
            (try (fs/create-dirs (str scratch "/real/packages"))
                (fs/create-dirs (str scratch "/real/compiled"))
                (fs/create-dirs (str scratch "/real/artifacts"))
                (bench/make-depot (str scratch "/depot") (str scratch "/real"))
                (is (= ["artifacts" "packages"]
                        (sort (map (comp str fs/file-name)
                                (fs/list-dir (str scratch "/depot"))))))
                (is (fs/sym-link? (str scratch "/depot/packages")))
                (finally (fs/delete-tree scratch))))))

(deftest json-line
    (testing "the child's JSON is its last {...} line, whatever came before it"
        (is (= "{\"a\":1,\"b\":{\"c\":2}}"
                (bench/json-line
                    (str "Transaction\n\n  Prefix: /x\n\nTransaction finished\n\n"
                        "{\"a\":1,\"b\":{\"c\":2}}\n")))))
    (testing "no JSON line gives nil"
        (is (nil? (bench/json-line "Transaction finished\nsomething else\n")))))
