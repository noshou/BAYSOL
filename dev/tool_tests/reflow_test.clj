;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of reflow.clj's re-wrapping: balanced lines, nothing but whitespace changed,
;; structure kept.

(ns reflow-test
 (:require [babashka.fs :as fs]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]
  [common :as c]
  [helpers :as h]
  [linelen]
  [reflow]))

(defn ^:private words-of [lines] (re-seq #"\S+" (str/join " " lines)))

(deftest balanced-no-orphan
 (testing
  "a paragraph that overflows by a word gets even lines, not a one-word last line"
  (let [lines (reflow/balanced (repeat 19 "abcdefghi") 92)]
   (is (= 3 (count lines)))
   (is (> (count (last lines)) 40)))))

(deftest balanced-keeps-words
 (testing "no word is lost, added or changed"
  (let [ws (str/split
     "the quick brown fox jumps over the lazy dog and keeps running far away"
     #" ")]
   (is (= ws (words-of (reflow/balanced ws 30)))))))

(deftest balanced-code-span-in-one-piece
 (testing "a backtick span with spaces is never split"
  (let [text (str "text before `a span with spaces` and "
     "text after, enough words to need wrapping here")]
   (is (every? #(even? (count (re-seq #"`" %)))
     (reflow/balanced (reflow/words text) 30))))))

(deftest balanced-no-markdown-start
 (testing "a continuation line never starts like a list, heading or table"
  (let [ws (str/split
     "aaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbb - cccccccccccccccccccc dddd"
     #" ")]
   (is (not-any? reflow/bad-start? (rest (reflow/balanced ws 45)))))))

(deftest reflow-comment-block
 (testing "a comment block with a long line is re-wrapped under the same prefix"
  (let [long-line (str "    # " (apply str (repeat 25 "word ")) "end")
    wrapped (reflow/reflow-lines [long-line] "jl")]
   (is (= 2 (count wrapped)))
   (is (str/starts-with? (first wrapped) "    # "))
   (is (= (remove #{"#"} (words-of [long-line]))
     (remove #{"#"} (words-of wrapped))))
   (is (every? #(<= (count %) 92) wrapped)))))

(deftest reflow-clojure-comment-block
 (testing "the same for the `;;` comments of Clojure"
  (let [long-line (str ";; " (apply str (repeat 30 "word ")) "end")
    wrapped (reflow/reflow-lines [long-line] "clj")]
   (is (< 1 (count wrapped)))
   (is (every? #(str/starts-with? % ";; ") wrapped))
   (is (every? #(<= (count %) 92) wrapped)))))

(deftest reflow-leaves-short-lines
 (testing "nothing changes when no line is too long"
  (let [lines ["# a short comment" "# and another" "x = 1"]]
   (is (= lines (reflow/reflow-lines lines "jl"))))))

(deftest reflow-leaves-code-blocks
 (testing "indented text in a docstring is not re-wrapped"
  (let [lines ["\"\"\"" (str "    " (apply str (repeat 120 "x"))) "\"\"\""]]
   (is (= lines (reflow/reflow-lines lines "jl"))))))

(deftest reflow-trailing-comment
 (testing "a trailing comment that makes a Julia line too long moves above it"
  (let [line (str "    x = f(y)  # " (apply str (repeat 20 "word ")) "end")
    wrapped (reflow/reflow-lines [line] "jl")]
   (is (= "    x = f(y)" (last wrapped)))
   (is (= \# (nth (first wrapped) 4))))))

(def ^:private long-comment (str "# " (apply str (repeat 30 "word ")) "end"))

(deftest reflow-files-check-then-apply
 (testing "checking lists the file and changes nothing; applying rewrites it once"
  (let [dir (h/scratch-dir)]
   (try (h/write-file (str dir "/a.jl") (str long-comment "\nx = 1\n"))
    (binding [c/*root* dir]
     (let [before (c/slurp8 (str dir "/a.jl"))]
      (is (= ["a.jl"]
        (map #(str (fs/file-name %))
         (reflow/reflow-files false :julia [dir]))))
      (is (= before (c/slurp8 (str dir "/a.jl"))))
      (is (= 1 (count (reflow/reflow-files true :julia [dir]))))
      (is (empty? (reflow/reflow-files true :julia [dir])))
      (is (not= before (c/slurp8 (str dir "/a.jl"))))
      (is (empty? (reflow/reflow-files false :clj [dir])))))
    (finally (fs/delete-tree dir))))))

(deftest linelen-check
 (testing "--check passes on short lines and returns status 1 on a long one"
  (let [dir (h/scratch-dir)]
   (try (binding [c/*root* dir
      *err* (java.io.StringWriter.)
      *out* (java.io.StringWriter.)]
     (h/write-file (str dir "/a.jl") "x = 1\n")
     (is (nil? (linelen/run ["--check" dir])))
     (h/write-file (str dir "/a.jl")
      (str "x = \"" (apply str (repeat 95 "a")) "\"\n"))
     (is (= 1 (linelen/run ["--check" dir]))))
    (finally (fs/delete-tree dir))))))
