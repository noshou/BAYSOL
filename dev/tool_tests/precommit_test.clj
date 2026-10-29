;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of precommit.clj's whitespace step on a scratch git repository: trailing
;; whitespace on changed lines is stripped (and only there), untracked files are stripped
;; whole, a conflict marker is a failure.

(ns precommit-test
 (:require [babashka.fs :as fs]
  [babashka.process :as p]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]
  [common :as c]
  [helpers :as h]
  [precommit]))

(defn ^:private scratch-repo
 "A scratch repository with one committed file (a.jl: three lines, the second already
 ends in blanks); its path."
 []
 (let [dir (h/scratch-dir)
   git (fn [& args]
    @(apply p/process {:dir dir, :out :string, :err :string} "git" args))]
  (git "init" "-q")
  (h/write-file (str dir "/a.jl") "one\ntwo  \nthree\n")
  (git "add" "a.jl")
  (git "-c" "user.name=t" "-c" "user.email=t@t" "commit" "-q" "-m" "init")
  dir))

(defn ^:private visible [s] (str/replace s "\n" "|"))

(deftest whitespace-strips-only-changed-lines
 (testing
  "changed and untracked lines are stripped, a line git did not see change is not"
  (let [dir (scratch-repo)]
   (try
    ;; lines 1 and 3 changed with blanks, line 2 untouched
    (h/write-file (str dir "/a.jl") "one \ntwo  \nthree\t\nfour\n")
    (h/write-file (str dir "/new.md") "x  \ny\n")
    (binding [c/*root* dir] (with-out-str (is (precommit/whitespace))))
    (is (= "one|two  |three|four|" (visible (c/slurp8 (str dir "/a.jl")))))
    (is (= "x|y|" (visible (c/slurp8 (str dir "/new.md")))))
    (finally (fs/delete-tree dir))))))

(deftest whitespace-conflict-marker-fails
 (testing "a conflict marker in an untracked file is reported and fails"
  (let [dir (scratch-repo)]
   (try (h/write-file (str dir "/b.jl") "ok\n<<<<<<< HEAD\nx\n")
    (binding [c/*root* dir]
     (let [out (with-out-str (is (not (precommit/whitespace))))]
      (is (h/contains-text? out "b.jl:2: conflict marker"))))
    (finally (fs/delete-tree dir))))))

(deftest whitespace-clean-tree
 (testing "nothing to strip: true and the files are byte for byte the same"
  (let [dir (scratch-repo)]
   (try (let [before (c/slurp8 (str dir "/a.jl"))]
     (binding [c/*root* dir] (with-out-str (is (precommit/whitespace))))
     (is (= before (c/slurp8 (str dir "/a.jl")))))
    (finally (fs/delete-tree dir))))))

(deftest whitespace-leaves-tsv-alone
 (testing "a trailing tab in a .tsv is an empty last field, not whitespace"
  (let [dir (scratch-repo)
    tsv "a\tb\tc\nx\ty\t\n"]
   (h/write-file (str dir "/t.tsv") tsv)
   (is (zero? (#'precommit/strip-lines (str dir "/t.tsv") :all)))
   (is (= tsv (c/slurp8 (str dir "/t.tsv")))))))
