;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of `reindent` in dev/format.clj: the indentation rule of the Clojure
;; code, on small texts and on the repository's own files (which must be fixed
;; points).

(ns format-test
    (:require [clojure.string :as str]
        [clojure.test :refer [deftest is testing]]
        [common :as c]
        [format :as fmt]
        [helpers :as h]))

(defn ^:private lines
    "The lines of the strings `ls` joined by newlines."
    [& ls]
    (str/join "\n" ls))

(deftest continuation-is-parent-plus-four
    (testing "arguments on later lines hang 4 from the line that opened the form"
        (is (= (lines "(foo a" "    b" "    c)")
                (fmt/reindent (lines "(foo a" "          b" "  c)")))))
    (testing "a form that starts mid-line is indented from its line, not its column"
        (is (= (lines "(def x" "    (str 1" "        2))")
                (fmt/reindent (lines "(def x" "      (str 1" "           2))"))))))

(deftest brackets-opened-on-one-line-add-a-level-each
    (testing "(foo (bar a  ... : bar's arguments at 8, foo's at 4"
        (is (= (lines "(foo (bar a" "        b)" "    c)")
                (fmt/reindent (lines "(foo (bar a" "          b)" "     c)")))))
    (testing "let bindings are one level deeper than the body"
        (is (= (lines "(let [a 1" "        b 2]" "    (+ a b))")
                (fmt/reindent (lines "(let [a 1" "      b 2]" "  (+ a b))"))))))

(deftest top-level-forms-start-at-column-zero
    (is (= (lines "(def a 1)" "" "(def b" "    2)")
            (fmt/reindent (lines "  (def a 1)" "" "    (def b" "  2)")))))

(deftest strings-characters-regexes-and-comments-hide-brackets
    (testing
        "a bracket in a string, a character, a regex or a comment opens nothing"
        (is (= (lines "(foo \"(\" \\( #\"\\(\" a ; (" "    b)")
                (fmt/reindent (lines "(foo \"(\" \\( #\"\\(\" a ; ("
                        "         b)"))))
        (is (= (lines "(foo \\)" "    a)")
                (fmt/reindent (lines "(foo \\)" "      a)")))))
    (testing "an escaped quote does not end a string"
        (is (= (lines "(foo \"a\\\"(\" b" "    c)")
                (fmt/reindent (lines "(foo \"a\\\"(\" b" "        c)"))))))

(deftest lines-inside-a-multi-line-string-are-kept
    (let [text (lines "(defn f" "    \"Doc line one"
                "      and two (not code)" "    \""
                "    [x]" "    x)")]
        (is (= text (fmt/reindent text)))
        (testing
            (str
                "code after the string closes is still read; the brackets opened on a "
                "line that starts inside a string count as indentation 0")
            (is (= (lines "(foo \"a" "   b\" (bar c" "    d)" "    e)")
                    (fmt/reindent (lines "(foo \"a" "   b\" (bar c"
                            "   d)" "  e)")))))))

(deftest comment-lines-take-the-indentation-of-the-next-code-line
    (is (= (lines ";; top" "(foo" "    ;; about a" "    a" "    b)")
            (fmt/reindent (lines ";; top" "(foo" ";; about a" "  a" "         b)"))))
    (testing "trailing comments stay where they are"
        (is (= (lines "(foo a ; trailing" "    b)")
                (fmt/reindent (lines "(foo a ; trailing" "       b)")))))
    (testing "a shebang line is left alone"
        (is (= (lines "#!/usr/bin/env bb" "(foo)")
                (fmt/reindent (lines "#!/usr/bin/env bb" "(foo)"))))))

(deftest reindent-is-idempotent
    (let [text (lines "(let [a (foo 1"
                "                2)" "      b 3]"
                "  (bar a" "         b))")
            once (fmt/reindent text)]
        (is (= once (fmt/reindent once)))))

(deftest the-repository-code-is-already-reindented
    (testing "no .clj file of the repository changes under reindent"
        (doseq [f (mapcat c/code-files [c/*root*])
                :when (str/ends-with? f ".clj")
                :let [text (c/slurp8 (c/in-root f))]]
            (is (= text (fmt/reindent text))
                (str f " is not a fixed point of reindent")))))

(deftest an-unknown-option-is-refused-before-any-formatter-runs
    (let [{:keys [status out]}
            (h/run-tool (str h/dev-dir "/format.clj") "--apply" "--check")]
        (is (= 2 status))
        (is (h/contains-text? out "unknown option --check"))
        (is (h/contains-text? out "bb fmt-check"))))

(deftest edn-files-keep-their-line-breaks
    (testing
        "an .edn map respects the author's newlines (blank lines before a comment)"
        (is (true? (get-in (fmt/options-for "bb.edn") [:map :respect-nl?])))
        (is (true? (get-in (fmt/options-for "dev/x/y.edn") [:map :respect-nl?]))))
    (testing "Clojure code is formatted as before"
        (is (nil? (get-in (fmt/options-for "dev/report.clj") [:map :respect-nl?])))
        (is (= 4 (get-in (fmt/options-for "dev/report.clj") [:list :indent])))))

(deftest private-functions-are-defn-private
    (testing "a top-level defn- becomes defn ^:private"
        (is (= "(defn ^:private f [x] x)" (fmt/private-defns "(defn- f [x] x)")))
        (is (= (lines "(defn ^:private a [] 1)" "(defn ^:private b [] 2)")
                (fmt/private-defns (lines "(defn- a [] 1)" "(defn- b [] 2)")))))
    (testing "a public defn, an indented mention and a docstring are left alone"
        (is (= "(defn f [] 1)" (fmt/private-defns "(defn f [] 1)")))
        (is (= (lines "(def x" "    \"use (defn- for a private fn\")")
                (fmt/private-defns (lines "(def x"
                        "    \"use (defn- for a private fn\")"))))
        (is (= "(def ^:private x 1)" (fmt/private-defns "(def ^:private x 1)"))))
    (testing "it is idempotent"
        (let [once (fmt/private-defns "(defn- f [x] x)")]
            (is (= once (fmt/private-defns once))))))
