;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of `reindent` in dev/format.clj: the indentation rule of the Clojure
;; code, on small texts and on the repository's own files (which must be fixed
;; points).

(ns format-test
 (:require [babashka.fs :as fs]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]
  [common :as c]
  [format :as fmt]
  [helpers :as h]
  [reflow]))

(defn ^:private lines
 "The lines of the strings `ls` joined by newlines."
 [& ls]
 (str/join "\n" ls))

(deftest continuation-is-parent-plus-one
 (testing "arguments on later lines hang 1 from the line that opened the form"
  (is (= (lines "(foo a" " b" " c)")
    (fmt/reindent (lines "(foo a" "          b" "  c)")))))
 (testing "a form that starts mid-line is indented from its line, not its column"
  (is (= (lines "(def x" " (str 1" "  2))")
    (fmt/reindent (lines "(def x" "      (str 1" "           2))"))))))

(deftest brackets-opened-on-one-line-add-a-level-each
 (testing "(foo (bar a  ... : bar's arguments at 2, foo's at 1"
  (is (= (lines "(foo (bar a" "  b)" " c)")
    (fmt/reindent (lines "(foo (bar a" "          b)" "     c)")))))
 (testing "let bindings are one level deeper than the body"
  (is (= (lines "(let [a 1" "  b 2]" " (+ a b))")
    (fmt/reindent (lines "(let [a 1" "      b 2]" "  (+ a b))"))))))

(deftest top-level-forms-start-at-column-zero
 (is (= (lines "(def a 1)" "" "(def b" " 2)")
   (fmt/reindent (lines "  (def a 1)" "" "    (def b" "  2)")))))

(deftest strings-characters-regexes-and-comments-hide-brackets
 (testing "a bracket in a string, a character, a regex or a comment opens nothing"
  (is (= (lines "(foo \"(\" \\( #\"\\(\" a ; (" " b)")
    (fmt/reindent (lines "(foo \"(\" \\( #\"\\(\" a ; (" "         b)"))))
  (is (= (lines "(foo \\)" " a)") (fmt/reindent (lines "(foo \\)" "      a)")))))
 (testing "an escaped quote does not end a string"
  (is (= (lines "(foo \"a\\\"(\" b" " c)")
    (fmt/reindent (lines "(foo \"a\\\"(\" b" "        c)"))))))

(deftest lines-inside-a-multi-line-string-are-kept
 (let [text (lines "(defn f" " \"Doc line one"
    "      and two (not code)" " \""
    " [x]" " x)")]
  (is (= text (fmt/reindent text)))
  (testing (str
    "code after the string closes is still read; the brackets opened on a "
    "line that starts inside a string count as indentation 0")
   (is (= (lines "(foo \"a" "   b\" (bar c" " d)" " e)")
     (fmt/reindent (lines "(foo \"a" "   b\" (bar c" "   d)" "  e)")))))))

(deftest comment-lines-take-the-indentation-of-the-next-code-line
 (is (= (lines ";; top" "(foo" " ;; about a" " a" " b)")
   (fmt/reindent (lines ";; top" "(foo" ";; about a" "  a" "         b)"))))
 (testing "trailing comments stay where they are"
  (is (= (lines "(foo a ; trailing" " b)")
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
   (is (= text (fmt/reindent text)) (str f " is not a fixed point of reindent")))))

(deftest an-unknown-option-is-refused-before-any-formatter-runs
 (let [{:keys [status out]}
   (h/run-tool (str h/dev-dir "/format.clj") "--apply" "--check")]
  (is (= 2 status))
  (is (h/contains-text? out "unknown option --check"))
  (is (h/contains-text? out "bb fmt-check"))))

(deftest line-breaks-and-blank-lines-are-the-authors
 (testing "the options ask zprint to respect both, for .clj and .edn alike"
  (doseq [path ["dev/report.clj" "bb.edn" "dev/x/y.edn"]]
   (is (every? (set (:style (fmt/options-for path))) [:respect-nl :respect-bl])
    path))
  (is (= 1 (get-in (fmt/options-for "dev/report.clj") [:list :indent]))))
 (testing "text with line breaks and blank lines inside its forms is a fixed point"
  (let [zp (#'fmt/zprint-file-str)
    text (lines
     "(ns demo)" ""
     "(defn f" " \"doc\""
     " [x]" " (let [a 1"
     ""
     "   b 2]"
     "  (println a" "   b)"
     "" "  (cond"
     "   (= a 1) :one" ""
     "   :else :other)))" ""
     "(def m" " {:a 1,"
     "" "  :b 2})"
     ""
     "(defn -main"
     " \"Starts.\"" " [& _]"
     " (println \"x\"))" "")]
   (is (= text (fmt/format-text zp text "x.clj"))))))

(deftest only-blank-lines-before-the-end-of-the-file-go
 (is (= "(def a 1)\n" (fmt/trim-eof "(def a 1)\n\n\n")))
 (is (= "(def a 1)\n" (fmt/trim-eof "(def a 1)")))
 (is (= "" (fmt/trim-eof "\n \n")))
 (testing "blank lines inside the text stay"
  (is (= "a\n\n\nb\n" (fmt/trim-eof "a\n\n\nb\n\n")))))

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

;; The license header. Everything below works on strings or on files in a scratch
;; directory; no test reads or writes the repository's own files.

(def ^:private spdx "SPDX-License-Identifier: LGPL-3.0-or-later")

(deftest header-is-inserted-first-in-the-files-comment-syntax
 (is (= (lines (str "# " spdx) "" "x = 1") (fmt/with-header "x = 1" ".jl")))
 (is (= (lines (str ";; " spdx) "" "(ns a)") (fmt/with-header "(ns a)" ".clj")))
 (is (= (lines (str ";; " spdx) "" "{:a 1}") (fmt/with-header "{:a 1}" ".edn")))
 (is (= (lines (str "// " spdx) "" "a {}") (fmt/with-header "a {}" ".scss")))
 (testing ".yml is not covered"
  (is (= "name: x" (fmt/with-header "name: x" ".yml"))))
 (testing "a file that is only a comment or a docstring still gets it on top"
  (is (= (lines (str "# " spdx) "" "\"\"\"Doc.\"\"\"")
    (fmt/with-header "\"\"\"Doc.\"\"\"" ".jl")))))

(deftest header-follows-a-shebang-on-the-next-line
 (is (= (lines "#!/usr/bin/env bb" (str ";; " spdx) "" "(ns a)")
   (fmt/with-header (lines "#!/usr/bin/env bb" "(ns a)") ".clj")))
 (testing "a shebang with the header but no blank line gets the blank line"
  (is (= (lines "#!/usr/bin/env bb" (str ";; " spdx) "" ";; about")
    (fmt/with-header (lines "#!/usr/bin/env bb" (str ";; " spdx) ";; about")
     ".clj")))))

(deftest a-correct-header-is-left-alone
 (doseq [[ext prefix] [[".jl" "#"] [".clj" ";;"] [".scss" "//"]]
   :let [text (lines (str prefix " " spdx) "" "body" "" "" "more")]]
  (is (= text (fmt/with-header text ext)) ext))
 (testing "extra blank lines after it are not collapsed"
  (let [text (lines (str "# " spdx) "" "" "x")]
   (is (= text (fmt/with-header text ".jl")))))
 (testing "the final newline is kept either way"
  (let [text (str (lines (str "# " spdx) "" "x") "\n")]
   (is (= text (fmt/with-header text ".jl")))
   (is (= (str (lines (str "# " spdx) "" "x") "\n")
     (fmt/with-header "x\n" ".jl"))))))

(deftest a-missing-blank-line-or-a-stale-identifier-is-repaired
 (is (= (lines (str "# " spdx) "" "x = 1")
   (fmt/with-header (lines (str "# " spdx) "x = 1") ".jl")))
 (testing "another license line in that place is replaced, not duplicated"
  (is (= (lines (str "# " spdx) "" "x = 1")
    (fmt/with-header
     (lines "# SPDX-License-Identifier: LGPL-3.1-or-later" "" "x = 1")
     ".jl"))))
 (testing "a header further down is not a header: the top gets one"
  (is (= (lines (str "# " spdx) "" "x = 1" (str "# " spdx))
    (fmt/with-header (lines "x = 1" (str "# " spdx)) ".jl")))))

(deftest odd-files
 (testing "an empty file becomes the header alone"
  (is (= (str "# " spdx "\n") (fmt/with-header "" ".jl")))
  (is (= (str "# " spdx "\n") (fmt/with-header (str "# " spdx "\n") ".jl"))))
 (testing "an extension without a comment syntax is not touched"
  (is (= "{\"a\": 1}" (fmt/with-header "{\"a\": 1}" ".json")))))

(deftest with-header-is-idempotent
 (doseq [text ["" "x" "x\n" "#!/usr/bin/env bb\n(ns a)"
    "# SPDX-License-Identifier: X\ny" (str "# " spdx "\ny")
    (str "# " spdx "\n\n\ny\n")]
   ext [".jl" ".clj"]
   :let [once (fmt/with-header text ext)]]
  (is (= once (fmt/with-header once ext)) (pr-str text))))

(defn ^:private in-scratch
 "Runs `f` with a fresh scratch directory (never the repository) holding `files`, a map
 of relative name to text, and removes it afterwards."
 [files f]
 (let [dir (h/scratch-dir)]
  (try (doseq [[fname text] files] (h/write-file (str dir "/" fname) text))
   (f dir)
   (finally (fs/delete-tree dir)))))

(deftest check-lists-and-apply-repairs-in-an-isolated-folder
 (in-scratch
  {"a.clj" "(ns a)\n",
   "b.clj" (str ";; " spdx "\n\n(ns b)\n"),
   "c.jl" "x = 1\n",
   "notes.txt" "plain\n"}
  (fn [dir]
   (let [check (h/run-tool (str h/dev-dir "/format.clj") "--check" "--clj" dir)]
    (is (= 1 (:status check)) (:out check))
    (is (h/contains-text? (:out check) "license header missing:"))
    (is (h/contains-text? (:out check) "a.clj"))
    (is (not (h/contains-text? (:out check) "b.clj")))
    (is (= "(ns a)\n" (c/slurp8 (str dir "/a.clj"))) "check changes nothing")
    (is (= "x = 1\n" (c/slurp8 (str dir "/c.jl")))))
   (let [apply* (h/run-tool (str h/dev-dir "/format.clj") "--apply" "--clj" dir)]
    (is (= 0 (:status apply*)) (:out apply*))
    (is (str/starts-with? (c/slurp8 (str dir "/a.clj"))
      (str ";; " spdx "\n\n(ns a)")))
    (is (= "x = 1\n" (c/slurp8 (str dir "/c.jl"))) "--clj leaves Julia files")
    (is (= "plain\n" (c/slurp8 (str dir "/notes.txt")))))
   (let [again (h/run-tool (str h/dev-dir "/format.clj") "--check" "--clj" dir)]
    (is (= 0 (:status again)) (:out again))))))

(deftest scss-flag-checks-only-scss-headers
 (in-scratch
  {"a.scss" "a {}\n", "b.clj" "(ns b)\n"}
  (fn [dir]
   (let [check (h/run-tool (str h/dev-dir "/format.clj") "--check" "--scss" dir)]
    (is (= 1 (:status check)) (:out check))
    (is (h/contains-text? (:out check) "a.scss"))
    (is (not (h/contains-text? (:out check) "b.clj"))))
   (let [apply* (h/run-tool (str h/dev-dir "/format.clj") "--apply" "--scss" dir)]
    (is (= 0 (:status apply*)) (:out apply*))
    (is (= (str "// " spdx "\n\na {}\n") (c/slurp8 (str dir "/a.scss"))))
    (is (= "(ns b)\n" (c/slurp8 (str dir "/b.clj"))))))))

;; SCSS: `reindent-scss` and `bb fmt --scss`. The
;; repository's own .scss files are only read.

(deftest scss-nesting-is-four-spaces-a-level
 (is (= (lines "a {" "    color: red;" "    b {" "        margin: 0;" "    }" "}")
   (fmt/reindent-scss
    (lines "a {" "color: red;" "  b {" "      margin: 0;" "  }" "      }"))))
 (testing "tabs and trailing whitespace go"
  (is (= (lines "a {" "    color: red;" "}")
    (fmt/reindent-scss (lines "a {  " "\t\tcolor: red;   " "}"))))))

(deftest a-declaration-continues-one-level-in
 (is (= (lines "a {"
    "    src: url(\"a.woff2\") format(\"woff2\"),"
    "        url(\"b.woff2\");"
    "    color: red;" "}")
   (fmt/reindent-scss (lines "a {"
     "src: url(\"a.woff2\") format(\"woff2\"),"
     "url(\"b.woff2\");"
     "color: red;" "}"))))
 (testing "a variable at the top level"
  (is (= (lines "$f: \"A\", \"B\"," "    \"C\";" "a {}")
    (fmt/reindent-scss (lines "$f: \"A\", \"B\"," "\"C\";" "a {}")))))
 (testing "a selector list is not a declaration: its lines stay level"
  (is (= (lines "a:hover," "b," "c {" "    x: y;" "}")
    (fmt/reindent-scss (lines "a:hover," "  b," "      c {" "x: y;" "}")))))
 (testing "a bracket the declaration opens is indented by the bracket only"
  (is (= (lines "$m: (" "    'a': 1," "    'b': 2," ");" "a {}")
    (fmt/reindent-scss
     (lines "$m: (" "'a': 1," "        'b': 2," "    );" "a {}"))))))

(deftest strings-comments-and-urls-hide-brackets
 (is (= (lines "a {" "    content: \"{\"; // }" "    b: c;" "}")
   (fmt/reindent-scss (lines "a {" "content: \"{\"; // }" "b: c;" "}"))))
 (testing "an unquoted url with // and a quote in it"
  (is (= (lines "a {" "    background: url(http://x.org/a'b);" "    b: c;" "}")
    (fmt/reindent-scss (lines "a {" "background: url(http://x.org/a'b);"
      "b: c;" "}")))))
 (testing "interpolation balances itself"
  (is (= (lines "a {" "    width: #{$w}px;" "    b: c;" "}")
    (fmt/reindent-scss (lines "a {" "width: #{$w}px;" "b: c;" "}"))))))

(deftest scss-comments
 (is (= (lines "// top" "a {" "    // inside" "    b: c;" "    // last" "}")
   (fmt/reindent-scss
    (lines "// top" "a {" "// inside" "b: c;" "      // last" "}"))))
 (testing "block comments: the opener is indented, the rest kept"
  (is (= (lines "a {" "    /* one" "     two */" "    b: c;" "}")
    (fmt/reindent-scss (lines "a {" "/* one" "     two */" "b: c;" "}")))))
 (testing "blank lines stay, the final newline too"
  (let [text (lines "a {}" "" "" "b {}" "")]
   (is (= text (fmt/reindent-scss text))))))

(deftest scss-reindent-is-idempotent
 (doseq [text [(lines "a {" "b: c," "d;" "}") (lines "$m: (" "'a': 1" ");") ""
    "a{b:c}" (lines "x {" "/* a" "b */" "y: z" "}")]
   :let [once (fmt/reindent-scss text)]]
  (is (= once (fmt/reindent-scss once)) (pr-str text))))

(deftest the-repository-scss-files-are-fixed-points
 (doseq [f (mapcat c/code-files [c/*root*])
   :when (str/ends-with? f ".scss")
   :let [text (c/slurp8 (c/in-root f))]]
  (is (= text (fmt/reindent-scss text))
   (str f " is not a fixed point of reindent"))))

(deftest long-scss-comments-are-re-wrapped
 (let [long-line (str "// " (str/join " " (repeat 30 "word")))
   out (reflow/reflow-lines [long-line] "scss")]
  (is (< 1 (count out)))
  (is (every? #(str/starts-with? % "// ") out))
  (is (every? #(<= (count %) c/line-limit) out))
  (testing "a comment that fits is kept"
   (is (= ["// short"] (reflow/reflow-lines ["// short"] "scss"))))))

(deftest bb-fmt-scss-in-an-isolated-folder
 (let [dir (h/scratch-dir)
   file (str dir "/t.scss")]
  (try
   (h/write-file file "a {\ncolor: red;\n}\n")
   (let [check (h/run-tool (str h/dev-dir "/format.clj") "--check" "--scss" dir)]
    (is (= 1 (:status check)) (:out check))
    (is (h/contains-text? (:out check) "not formatted:"))
    (is (= "a {\ncolor: red;\n}\n" (c/slurp8 file)) "check changes nothing"))
   (let [done (h/run-tool (str h/dev-dir "/format.clj") "--apply" "--scss" dir)]
    (is (= 0 (:status done)) (:out done))
    (is
     (= "// SPDX-License-Identifier: LGPL-3.0-or-later\n\na {\n    color: red;\n}\n"
      (c/slurp8 file))))
   (is (= 0
     (:status
      (h/run-tool (str h/dev-dir "/format.clj") "--check" "--scss" dir))))
   (finally (fs/delete-tree dir)))))

(deftest the-release-name-must-fit-the-main-menu
 (let [toml (fn [version release]
    (str "name = \"BAYSOL\"\nversion = \""
     version
     "\"\nrelease_name = \""
     release
     "\"\n"))]
  (is (= "v0.4.0-yals-n-gɛsga" (fmt/version-name (toml "0.4.0" "yals-n-gɛsga"))))
  (testing "22 characters fit, 23 do not"
   (is (nil? (fmt/version-problem (toml "0.4.0" "yals-n-gɛsga"))))
   (is (nil? (fmt/version-problem (toml "0.4.0" (apply str (repeat 15 "a"))))))
   (is (some? (fmt/version-problem (toml "0.4.0" (apply str (repeat 16 "a")))))))
  (testing "a missing key is a problem"
   (is (some? (fmt/version-problem "name = \"BAYSOL\"\nversion = \"0.4.0\"\n"))))
  (testing "the Project.toml of the repository fits"
   (is (nil? (fmt/version-problem (c/slurp8 (c/in-root "Project.toml"))))))))
