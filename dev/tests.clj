#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Runs the tests of the dev tools (dev/tool_tests/*_test.clj, Clojure's own
;; clojure.test). No fit and no benchmark runs, and Julia is not needed.
;;
;;     bb test [NAME ...]
;;
;; With names, only the test files whose name contains one of them run
;; (`common` runs common_test.clj). Exit status 1 if any test failed. The tests of
;; the extraction tool also need the `sqlite3` pod (fetched on first use).

(require '[babashka.classpath :refer [add-classpath]] '[babashka.fs :as fs])

;; The tools under test (dev/) and the tests themselves are all on the classpath.
(let [here (fs/parent (fs/absolutize *file*))]
 (add-classpath (str here))
 (add-classpath (str (fs/path here "tool_tests"))))

(ns tests
 (:require [babashka.fs :as fs]
  [clojure.string :as str]
  [clojure.test :as t]
  [common :as c]))

(defn ^:private test-namespaces
 "The namespaces of the test files that match `names` (all when empty), sorted:
 common_test.clj holds the namespace common-test."
 [names]
 (->> (fs/glob (c/in-root "dev" "tool_tests") "*_test.clj")
  (map #(str (fs/strip-ext (fs/file-name %))))
  sort
  (filter (fn [f] (or (empty? names) (some #(str/includes? f %) names))))
  (map #(symbol (str/replace % "_" "-")))))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [nss (test-namespaces argv)]
   (if (empty? nss)
    (c/fail "bb test" "no test file matches")
    (do (apply require nss)
     (let [{:keys [fail error]} (apply t/run-tests nss)]
      (when (pos? (+ fail error)) 1)))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
