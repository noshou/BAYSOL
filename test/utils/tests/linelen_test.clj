;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of linelen.clj's re-wrapping: balanced lines, nothing but whitespace changed,
;; structure kept.

(ns linelen-test
    (:require [clojure.string :as str]
        [clojure.test :refer [deftest is testing]]
        [linelen]))

(defn- words-of [lines] (re-seq #"\S+" (str/join " " lines)))

(deftest balanced-no-orphan
    (testing
        "a paragraph that overflows by a word gets even lines, not a one-word last line"
        (let [lines (linelen/balanced (repeat 19 "abcdefghi") 92)]
            (is (= 3 (count lines)))
            (is (> (count (last lines)) 40)))))

(deftest balanced-keeps-words
    (testing "no word is lost, added or changed"
        (let
            [ws
                (str/split
                    "the quick brown fox jumps over the lazy dog and keeps running far away"
                    #" ")]
            (is (= ws (words-of (linelen/balanced ws 30)))))))

(deftest balanced-code-span-in-one-piece
    (testing "a backtick span with spaces is never split"
        (let [text (str "text before `a span with spaces` and "
                    "text after, enough words to need wrapping here")]
            (is (every? #(even? (count (re-seq #"`" %)))
                    (linelen/balanced (linelen/words text) 30))))))

(deftest balanced-no-markdown-start
    (testing "a continuation line never starts like a list, heading or table"
        (let
            [ws
                (str/split
                    "aaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbb - cccccccccccccccccccc dddd"
                    #" ")]
            (is (not-any? linelen/bad-start? (rest (linelen/balanced ws 45)))))))

(deftest reflow-comment-block
    (testing "a comment block with a long line is re-wrapped under the same prefix"
        (let [long-line (str "    # " (apply str (repeat 25 "word ")) "end")
                wrapped (linelen/reflow-lines [long-line] "jl")]
            (is (= 2 (count wrapped)))
            (is (str/starts-with? (first wrapped) "    # "))
            (is (= (remove #{"#"} (words-of [long-line]))
                    (remove #{"#"} (words-of wrapped))))
            (is (every? #(<= (count %) 92) wrapped)))))

(deftest reflow-clojure-comment-block
    (testing "the same for the `;;` comments of Clojure"
        (let [long-line (str ";; " (apply str (repeat 30 "word ")) "end")
                wrapped (linelen/reflow-lines [long-line] "clj")]
            (is (< 1 (count wrapped)))
            (is (every? #(str/starts-with? % ";; ") wrapped))
            (is (every? #(<= (count %) 92) wrapped)))))

(deftest reflow-leaves-short-lines
    (testing "nothing changes when no line is too long"
        (let [lines ["# a short comment" "# and another" "x = 1"]]
            (is (= lines (linelen/reflow-lines lines "jl"))))))

(deftest reflow-leaves-code-blocks
    (testing "indented text in a docstring is not re-wrapped"
        (let [lines ["\"\"\"" (str "    " (apply str (repeat 120 "x"))) "\"\"\""]]
            (is (= lines (linelen/reflow-lines lines "jl"))))))

(deftest reflow-trailing-comment
    (testing "a trailing comment that makes a Julia line too long moves above it"
        (let [line (str "    x = f(y)  # " (apply str (repeat 20 "word ")) "end")
                wrapped (linelen/reflow-lines [line] "jl")]
            (is (= "    x = f(y)" (last wrapped)))
            (is (= \# (nth (first wrapped) 4))))))
