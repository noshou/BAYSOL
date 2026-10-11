;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of common.clj: the git helpers (in a throwaway repository), the fitting-test
;; lookups, the command-line splitting, the symlink-safe directory removal and the
;; number formatting.

(ns common-test
    (:require [babashka.fs :as fs]
        [babashka.process :as p]
        [clojure.string :as str]
        [clojure.test :refer [deftest is testing]]
        [common :as c]
        [helpers :as h]))

(defn- make-repo
    "A throwaway git repository with commits of increasing dates, `tags-at` being
    [date [tag ...]] pairs, one commit each, with the tags on them."
    [dir tags-at]
    (fs/create-dirs dir)
    (let [git (fn [env & args]
                @(apply p/process
                    {:dir dir, :out :string, :err :string, :extra-env env}
                    "git" "-c"
                    "user.name=t" "-c"
                    "user.email=t@example.com" args))]
        (git {} "init" "-q")
        (doseq [[n [date tags]] (map-indexed vector tags-at)]
            (h/write-file (str (fs/path dir (str "f" n ".txt"))) (str n))
            (git {} "add" ".")
            (git {"GIT_COMMITTER_DATE" date, "GIT_AUTHOR_DATE" date}
                "commit" "-q"
                "-m" (str "c" n))
            (doseq [t tags] (git {} "tag" t)))))

(deftest latest-release
    (let [scratch (h/scratch-dir)]
        (try (testing "the newest tag that looks like a release, not the newest tag"
                (make-repo (str scratch "/r1")
                    [["2020-01-01T00:00:00" ["v0.1.0-a"]]
                        ["2021-01-01T00:00:00" ["v0.2.0-b"]]
                        ["2022-01-01T00:00:00" ["nightly" "vnext"]]])
                (binding [c/*root* (str scratch "/r1")]
                    (is (= "v0.2.0-b" (c/latest-release)))
                    (testing "resolve: a hash for a known revision, nil otherwise"
                        (is (= 40 (count (c/resolve-rev "v0.1.0-a"))))
                        (is (nil? (c/resolve-rev "no-such-rev"))))))
            (testing "no v<digit> tag means no release"
                (make-repo (str scratch "/r2")
                    [["2020-01-01T00:00:00" ["nightly"]]])
                (binding [c/*root* (str scratch "/r2")]
                    (is (nil? (c/latest-release)))))
            (finally (fs/delete-tree scratch)))))

(deftest baseline-for
    (let [scratch (h/scratch-dir)]
        (try (doseq [f ["v1.0.0-x-cold-hostA" "v1.0.0-x-cold-hostB"
                        "v2.0.0-y-cold-hostA"]]
                (h/write-file (str scratch "/root/test/baselines/" f ".json") ""))
            (binding [c/*root* (str scratch "/root")]
                (testing
                    "the newest baseline file of a tag, nil when there is none"
                    (is (= ["v1.0.0-x-cold-hostB.json" "v2.0.0-y-cold-hostA.json"
                                nil]
                            [(some-> (c/baseline-for "v1.0.0-x")
                                    fs/file-name)
                                (some-> (c/baseline-for "v2.0.0-y")
                                    fs/file-name) (c/baseline-for "v9.9.9")]))))
            (finally (fs/delete-tree scratch)))))

(deftest single-run
    (is (= [true false false false] (map c/single-run? [[""] ["a"] ["a" "b"] []]))))

(deftest fitting-test-lookups
    (testing
        "the real fitting tests: ids, a RUNS table, a single-run script, the specials"
        (is (= 27 (count (c/ids))))
        (is (= ["fit2_model1" "fit2_model2" "fit2_model3" "fit2_model4"
                    "fit2_model5"]
                (c/tags-of "SASDBS6")))
        (is (= [""] (c/tags-of "SASDMJ9")))
        (is (= ["model1" "model2" "model3"] (c/tags-of "SASDMZ9")))
        (is (= ["model1" "model2"] (c/tags-of "SASDJ72"))))
    (testing "<id>.jl when it exists, else the folder's only script"
        (is (= ["SASDMJ9.jl" "SASDA52_fit1.jl"]
                (map (comp str fs/file-name c/script-of) ["SASDMJ9" "SASDA52"]))))
    (testing "one spec per tag, the bare ID for a single-run script"
        (is (= ["SASDMJ9" "SASDJ72:model1" "SASDJ72:model2"]
                (c/specs-of ["SASDMJ9" "SASDJ72"])))))

(deftest rm-tree
    (let [scratch (h/scratch-dir)]
        (try (testing "removes the tree, unlinks a symlink, leaves its target alone"
                (h/write-file (str scratch "/target/sub/sentinel.txt") "keep")
                (let [d (str scratch "/baysol-bench-x")]
                    (fs/create-dirs (str d "/inner/.hiddendir"))
                    (h/write-file (str d "/inner/f.txt") "x")
                    (h/write-file (str d "/.dotfile") "x")
                    (fs/create-sym-link (str d "/link") (str scratch "/target"))
                    (c/rm-tree d)
                    (is (not (fs/exists? d)))
                    (is (fs/exists? (str scratch "/target/sub/sentinel.txt")))))
            (testing "a directory not named baysol-bench-* is never deleted"
                (is (thrown-with-msg? clojure.lang.ExceptionInfo
                        #"refusing to delete"
                        (c/rm-tree (str scratch "/target"))))
                (is (fs/directory? (str scratch "/target"))))
            (finally (fs/delete-tree scratch)))))

(deftest take-threads
    (testing "--threads leaves the other arguments and gives the environment"
        (is (= [["SASDMJ9" "--report"] {"JULIA_NUM_THREADS" "4,1"}]
                (c/take-threads ["SASDMJ9" "--threads" "4,1" "--report"]))))
    (testing "no --threads: arguments unchanged, empty environment"
        (is (= [["SASDMJ9" "--report"] {}]
                (c/take-threads ["SASDMJ9" "--report"]))))
    (testing "--threads without a value is an error"
        (is (thrown-with-msg? clojure.lang.ExceptionInfo
                #"--threads needs a value \(e.g. 4, auto, 4,1\)"
                (c/take-threads ["--threads"])))))

(deftest split-args
    (testing "options with values, flags and positional specs are separated"
        (is (= {:opts [["--out" "x"] ["--n" "3"]],
                    :flags ["--dry-run"],
                    :specs ["A" "B:c"]}
                (c/split-args "t"
                    ["--out" "--n"]
                    ["--dry-run"]
                    ["A" "--out" "x" "--dry-run" "B:c" "--n" "3"]))))
    (testing "an unknown option or a missing value exits 2 with a message"
        (let [script (str (h/scratch-dir) "/probe.clj")]
            (h/write-file
                script
                (str "(require '[babashka.classpath :as cp]) (cp/add-classpath \""
                    h/utils-dir
                    "\") (require '[common :as c])\n"
                    "(c/split-args \"t.clj\" [\"--out\"] [] *command-line-args*)"))
            (doseq [args [["--bad"] ["--out"]]]
                (let [{:keys [status out]} (h/run-tool script args)]
                    (is (= 2 status))
                    (is (h/contains-text? out "t.clj: ")))))))

(deftest formatting
    (testing "C-style conversions on the exact value of the double"
        (is (= ["0.1" "0.15" "-0.00" "+1.50" "21.5" "1e+05" "0.00123" "100" "7"]
                [(c/fmt "%.1f" 0.15) (c/fmt "%.2f" "0.15") (c/fmt "%.2f" -0.001)
                    (c/fmt "%+.2f" 1.5) (c/fmt "%.3g" 21.485) (c/fmt "%.3g" 100000.0)
                    (c/fmt "%.3g" 0.0012345) (c/fmt "%.3g" 100.2) (c/fmt "%d" "7")])))
    (testing "numeric strings as the numbers they stand for"
        (is (= [3.2 0.33 7 "true" ""]
                (map c/as-number ["3.20" "+0.33" "+7" "true" ""]))))
    (testing "doubles as printed in the tools' tables"
        (is (= ["12170.0" "0.0002" "6.75346e-7" "1.5"]
                [(c/num-str 12170.0) (c/num-str 0.0002) (c/num-str 6.75346e-7)
                    (c/num-str 1.5)]))))

(deftest list-fits-names-every-test
    (let [{:keys [status out]} (h/run-tool (str h/dev-dir "/diagnose.clj")
                "--list")]
        (is (= 0 status))
        (is (= 27 (count (str/split-lines out))))
        (is (h/contains-text? out "SASDMJ9  (single run, no tag)"))))
