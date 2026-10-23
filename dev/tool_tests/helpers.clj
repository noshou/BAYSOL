;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Helpers shared by the *_test.clj files (loaded by them, not a test file). The tests of
;; the dev tools run no fit and no benchmark and need no Julia: they exercise the
;; functions directly and the command lines of the tools that fail before Julia would
;; start.

(ns helpers
    (:require [babashka.fs :as fs]
        [babashka.process :as p]
        [clojure.string :as str]
        [common :as c]))

(def repo-dir c/*root*)
(def dev-dir (c/in-root "dev"))
(def data-dir (c/in-root "dev" "tool_tests" "data"))

(defn run-tool
    "Runs `bb script args...` and returns {:status n :out combined-stdout-and-stderr}."
    [script & args]
    (let [result @(apply p/process
                {:out :string, :err :out, :continue true, :dir repo-dir}
                "bb"
                (str script)
                (map str (flatten args)))]
        {:status (:exit result), :out (:out result)}))

(defn scratch-dir
    "A fresh scratch directory; the caller removes it with `fs/delete-tree`."
    []
    (str (fs/create-temp-dir {:prefix "cltests-"})))

(defn write-file
    "Writes `text` to `path`, creating the folders."
    [path text]
    (fs/create-dirs (fs/parent path))
    (c/spit8 path text))

(defn contains-text?
    "Does the text `s` contain `sub`?"
    [s sub]
    (str/includes? s sub))

(defn git-history?
    "Is the history of the fixed revisions of the golden files present? Not in a shallow
    clone or a copy without history."
    []
    (every?
        (fn [rev]
            (zero? (:exit @(p/process
                        {:out :string, :err :string, :continue true, :dir repo-dir}
                        "git" "cat-file"
                        "-e" (str rev "^{commit}")))))
        ["30f55ea" "81cf301" "24af397"]))
