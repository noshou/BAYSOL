;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The command lines of the front ends: a wrong argument must stop with a message and the
;; documented exit status BEFORE Julia would start, and --dry-run must print the commands
;; without running anything.

(ns cli-test
    (:require [babashka.fs :as fs]
        [clojure.string :as str]
        [clojure.test :refer [deftest is]]
        [common :as c]
        [helpers :as h]))

(defn- tool
    "Runs the front end `name` (dev/<name>.clj) with `args`; {:status :out}."
    [tool-name & args]
    (apply h/run-tool (str h/dev-dir "/" tool-name ".clj") args))

(defn- says? [{:keys [out]} & parts] (every? #(h/contains-text? out %) parts))

(deftest diagnose-unknown-id
    (let [r (tool "diagnose" "--report" "NOPE")]
        (is (= 2 (:status r)))
        (is (says? r "no fitting test 'NOPE'"))))

(deftest diagnose-needs-tag
    (let [r (tool "diagnose" "--report" "SASDEP6")]
        (is (= 2 (:status r)))
        (is (says? r "SASDEP6 needs a tag, one of: fit1_model1, fit1_model2"))))

(deftest diagnose-single-run-takes-no-tag
    (let [r (tool "diagnose" "--report" "SASDMJ9:x")]
        (is (= 2 (:status r)))
        (is (says? r "SASDMJ9 has a single run and takes no tag"))))

(deftest diagnose-bad-numbers
    (is (= [2 2 2]
            (map :status
                [(tool "diagnose" "--chains" "--retry" "2" "SASDMJ9")
                    (tool "diagnose" "--chains" "--seeds" "1,x" "SASDMJ9")
                    (tool "diagnose" "--report" "--samples" "0" "SASDMJ9")]))))

(deftest diagnose-list
    (let [r (tool "diagnose" "--list")]
        (is (= 0 (:status r)))
        ;; one line per fitting-test folder (derived: the folders are the source)
        (is (= (count (filter #(and (fs/directory? %)
                            (str/starts-with? (fs/file-name %) "SASD"))
                        (fs/list-dir (c/in-root c/fit-dir))))
                (count (str/split-lines (str/trim (:out r))))))
        (is (says? r
                "SASDBS6  fit2_model1 fit2_model2"
                "SASDMJ9  (single run, no tag)"))))

(deftest diagnose-parts-default-all
    (let [r (tool "diagnose"
                "--seeds" "1,2"
                "--samples" "50"
                "--out" "/nowhere"
                "--dry-run" "SASDMJ9")]
        (is (= 0 (:status r)))
        (is (= 3 (count (re-seq #"=== diagnose: " (:out r)))))
        ;; in this order
        (is (re-find (re-pattern (str "(?s)"
                        (str/join ".*"
                            (map #(str "=== diagnose: " %)
                                ["report" "residuals"
                                    "chains"]))))
                (:out r)))
        ;; each part gets only its own options
        (is
            (says?
                r
                (str "diagnose.jl --chains --seeds 1,2 --samples 50 "
                    "--out /nowhere/chains.txt SASDMJ9")
                "diagnose.jl --report --samples 50 --out /nowhere/report.txt SASDMJ9"))))

(deftest diagnose-default-all-fits
    (let [r (tool "diagnose" "--residuals" "--dry-run")]
        (is (= 0 (:status r)))
        ;; one ID or ID:tag per run of every fitting test (the scripts' RUNS tables)
        (is (= (count (c/specs-of (c/ids)))
                (count (re-seq #"SASD\w+(?::\w+)?"
                        (last (str/split-lines (:out r)))))))))

(deftest diagnose-parts-select
    (let [r (tool "diagnose" "--chains" "--residuals" "--dry-run" "SASDMJ9")]
        (is (= 0 (:status r)))
        (is (= 2 (count (re-seq #"=== diagnose: " (:out r)))))
        (is (not (h/contains-text? (:out r) "diagnose.jl --report")))))

(deftest fittings-unknown-id
    (let [r (tool "fittings" "NOPE" "SASDMJ9" "--dry-run")]
        (is (= 2 (:status r)))
        (is (says? r "no fitting test folder for: NOPE"))
        (is (not (h/contains-text? (:out r) "=== fit")))))

(deftest fittings-approved-needs-a-step
    (is (= 2 (:status (tool "fittings" "SASDMJ9" "--approved" "--dry-run")))))

(deftest fittings-dry-run
    (let [r (tool "fittings"
                "SASDMJ9" "SASDEP6"
                "--bench" "--report"
                "--fixme" "--dry-run")]
        (is (= 0 (:status r)))
        (is (= 2 (count (re-seq #"=== fit:" (:out r)))))
        (is (says? r
                "bb bench SASDMJ9 SASDEP6:fit1_model1 SASDEP6:fit1_model2"
                "bb results-table SASDMJ9 SASDEP6"
                "bb diagnose --report SASDMJ9 SASDEP6:fit1_model1"))
        ;; the benchmark is not approved
        (is (not (h/contains-text? (:out r) "--approved")))))

(deftest fittings-dry-run-approved
    (let [r (tool "fittings" "SASDMJ9" "--bench" "--approved" "--dry-run")]
        (is (= 0 (:status r)))
        (is (says? r "bb bench --approved SASDMJ9"))))

(deftest fittings-trace-compile
    (let [r (tool "fittings" "SASDMJ9" "--trace-compile" "/tmp/x.jl" "--dry-run")
            missing (tool "fittings" "SASDMJ9" "--trace-compile")]
        (is (= 0 (:status r)))
        (is (re-find #"--trace-compile=/tmp/x.jl.*SASDMJ9.jl"
                (str/replace (:out r) "\n" " ")))
        (is (= 2 (:status missing)))
        (is (says? missing "needs a value"))))

(deftest fittings-table
    (let [r (tool "fittings" "SASDMJ9" "--no-fit" "--table" "--dry-run")]
        (is (= 0 (:status r)))
        (is (says? r "bb results-table --update"))))

(deftest vis-list-and-unknown
    (let [listing (tool "vis" "--list")
            unknown (tool "vis" "nonsense")]
        (is (= 0 (:status listing)))
        (is (says? listing "sasa_hydro_report"))
        (is (= 2 (:status unknown)))
        (is (says? unknown "no visual check named: nonsense"))))
