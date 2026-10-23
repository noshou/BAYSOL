;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Shared helpers of the dev tools (dev/*.clj): the repository root,
;; running programs, git, the fitting-test lookups, command lines, and the number
;; formatting the tools' output depends on.

(ns common
    (:require [babashka.fs :as fs]
        [babashka.process :as p]
        [clojure.string :as str])
    (:import (java.io OutputStreamWriter PrintWriter)
        (java.math BigDecimal MathContext RoundingMode)))

;; --- the repository

;; Repository root: one level above this file, dev/ (BAYSOL_ROOT overrides it,
;; for testing elsewhere). Dynamic, so a test can point the helpers at a scratch tree.
(def ^:dynamic *root*
    (or (System/getenv "BAYSOL_ROOT")
        (str (fs/normalize (fs/path (fs/parent (fs/absolutize *file*)) "..")))))

(def fit-dir "test/fitting_tests")

(def line-limit
    "The longest line the code may have, in characters (`bb linelen --check`)."
    92)

(defn char-count
    "Characters of `s`, not UTF-16 units: a code point outside the BMP counts once."
    [s]
    (.codePointCount ^String s 0 (count s)))

(defn in-root [& parts] (str (apply fs/path *root* parts)))

(defn slurp8 [path] (slurp (str path) :encoding "UTF-8"))

(defn spit8 [path text] (spit (str path) text :encoding "UTF-8"))

;; --- the program

(defn usage
    "Prints the header comment of the running script: the `;` lines after the shebang,
    the SPDX line and the blank one."
    []
    (doseq [l (take-while #(str/starts-with? % ";")
                (drop 3
                    (str/split-lines (slurp8 (System/getProperty
                                "babashka.file")))))]
        (println (str/replace l #"^;+ ?" ""))))

(defn exit
    "Flushes the output, then exits with `code`."
    [code]
    (flush)
    (System/exit code))

(defn fail
    "Stops with \"who: msg\" on stderr and exit status 2 (a wrong command line)."
    [who msg]
    (binding [*out* *err*] (println (str who ": " msg)))
    (exit 2))

;; Environment variables for the programs `sh` starts (the `--threads` option).
(def ^:dynamic *env* {})

(defn take-threads
    "Takes `--threads N` (N as `julia -t` takes it: `4`, `auto`, `4,1` for four workers
    and one interactive thread) out of an argument list: [rest-of-args env], the env
    being {\"JULIA_NUM_THREADS\" N} or empty. An error if N is missing."
    [argv]
    (if-let [i (first (keep-indexed #(when (= %2 "--threads") %1) argv))]
        (if (< (inc i) (count argv))
            [(vec (concat (take i argv) (drop (+ i 2) argv)))
                {"JULIA_NUM_THREADS" (nth argv (inc i))}]
            (throw (ex-info "--threads needs a value (e.g. 4, auto, 4,1)" {})))
        [argv {}]))

(defn main
    "Runs `(f args)` as a main program: `--threads N` taken out of `args` first, UTF-8
    output, `f`'s result the exit status (nil is 0), an `ex-info` reported as a message
    with status 1. A closed pipe (`... | head`) is not an error: a `PrintWriter`
    swallows the exception."
    [f args]
    (let [writer #(PrintWriter. (OutputStreamWriter. % "UTF-8") true)
            code (binding [*out* (writer System/out)
                    *err* (writer System/err)]
                (try (let [[args env] (take-threads (vec args))]
                        (binding [*env* env] (f args)))
                    (catch clojure.lang.ExceptionInfo e
                        (binding [*out* *err*] (println (ex-message e)))
                        1)
                    (finally (flush))))]
        (System/exit (or code 0))))

;; The working directory of the programs `run-cmd` and `sh` start: nil, the directory
;; the tool was started in. A tool that starts another Babashka tool by its `bb <task>`
;; name binds it to the root, because Babashka finds `bb.edn` in the current directory.
(def ^:dynamic *dir* nil)

(defn- spawn
    "Starts a program: `opts` (babashka.process options) and the command, a nested
    collection of strings and numbers that is flattened. The process is not waited for."
    [opts cmd]
    (apply p/process opts (map str (flatten cmd))))

(defn run-cmd
    "Runs a command with our terminal (input, output and error), the variables of `*env*`
    added to its environment. True when it succeeded; the command is not printed."
    [cmd]
    (zero? (:exit @(spawn (cond-> {:inherit true, :continue true, :extra-env *env*}
                    *dir* (assoc :dir *dir*))
                cmd))))

(defn sh
    "Prints a command and, unless `dry`, runs it with our terminal. True when it
    succeeded."
    [dry & cmd]
    (println (str "$ " (str/join " " (flatten cmd))))
    (or dry (run-cmd cmd)))

(defn find-julia
    "The Julia executable: $JULIA if set, else `julia` from the PATH. An error if it
    cannot be found."
    []
    (let [julia (or (System/getenv "JULIA") "julia")]
        (when-not (fs/which julia)
            (throw (ex-info "julia not found (set JULIA to its path)" {})))
        julia))

;; --- code files

(def code-extensions
    "The extensions of the code the layout rules apply to."
    #{".jl" ".clj" ".edn" ".scss" ".yml"})

;; Folders that hold no code of ours: version control, build output, caches, notes.
(def ^:private skip-dirs
    #{".git" "build" "_cache" "sources" "manuscript" ".CondaPkg" "node_modules"})

;; Paths (relative to the root) that hold code of others: the hook files clj-kondo
;; copies into .clj-kondo/imports. They are gitignored and not ours to format.
(def ^:private skip-paths #{".clj-kondo/imports"})

(defn code-files
    "Every code file under `path` (a file or a directory) as a path relative to the
    root, sorted by path. Folders like .git and _cache, and the hook files clj-kondo
    copies into .clj-kondo/imports, are skipped."
    [path]
    (let [root (str (fs/normalize *root*))
            rel #(str (fs/relativize root (fs/normalize %)))
            code? #(contains? code-extensions (str "." (fs/extension %)))
            ;; a relative path is relative to the working directory, as for any tool
            path (fs/normalize (fs/absolutize path))]
        (if (fs/regular-file? path)
            (if (code? path) [(rel path)] [])
            (->> (fs/list-dir path)
                (sort-by str)
                (mapcat (fn [e]
                        (cond (fs/directory? e)
                            (if (or (skip-dirs (str (fs/file-name e)))
                                    (skip-paths (rel e)))
                                []
                                (code-files e))
                            (code? e) [(rel e)]
                            :else [])))))))

;; --- git

(defn git
    "Output of `git -C <root> args`, decoded as UTF-8 (tag and path names can be
    non-ASCII). A failing git raises an error."
    [& args]
    (let [git-proc (spawn {:out :stream, :err :inherit, :dir *root*} ["git" args])
            out (slurp (:out git-proc) :encoding "UTF-8")]
        (when-not (zero? (:exit @git-proc))
            (throw (ex-info (str "git " (str/join " " args) " failed") {})))
        out))

(defn resolve-rev
    "The commit hash of `rev`, or nil if git does not know it."
    [rev]
    (try (str/trim (git "rev-parse" "--verify" "--quiet" (str rev "^{commit}")))
        (catch clojure.lang.ExceptionInfo _ nil)))

(defn latest-release
    "The newest release tag: the most recently created tag whose name starts with \"v\"
    and a digit (v0.2.0-soukouratou, ...), or nil. This is what results are compared
    against by default."
    []
    (->> (str/split-lines (git "for-each-ref" "--sort=-creatordate"
                "--format=%(refname:short)" "refs/tags"))
        (filter #(re-find #"^v\d" %))
        first))

(defn baseline-for
    "The newest benchmark baseline recorded for release `tag`: the last (by name) of
    test/baselines/<tag>*.json, or nil. Baselines are captured when a release is made."
    [tag]
    (->> (fs/glob (in-root "test" "baselines") (str tag "*.json"))
        (map str)
        sort
        last))

;; --- files

(defn rm-tree
    "Deletes the benchmark's throwaway directory `dir` and everything in it, never
    following a symbolic link: a link is unlinked and its target left alone (the cold
    state's depot is made of links into the real one). Refuses any directory that is
    not named baysol-bench-*, so a wrong argument cannot delete anything else."
    [dir]
    (when-not (str/starts-with? (str (fs/file-name dir)) "baysol-bench-")
        (throw (ex-info (str "rm_tree: refusing to delete " dir) {})))
    (when (fs/directory? dir) (fs/delete-tree dir {:force true})))

;; --- the fitting tests under test/fitting_tests/

;; Scripts whose tags are not in a `const RUNS = [...]` table; the Julia side of these
;; is the SEED_ENTRY_OVERRIDES table in fit_seed.jl.
(def ^:private special-tags
    {"SASDMZ9" ["model1" "model2" "model3"], "SASDJ72" ["model1" "model2"]})

(defn ids
    "The ids of all fitting tests, sorted."
    []
    (->> (fs/list-dir (in-root fit-dir))
        (map fs/file-name)
        (filter #(str/starts-with? % "SASD"))
        sort))

(defn script-of
    "The script of fitting test `id`: <id>.jl, or the folder's only .jl file."
    [id]
    (let [dir (in-root fit-dir id)
            scripts (map fs/file-name (fs/glob dir "*.jl"))]
        (cond (some #{(str id ".jl")} scripts) (str (fs/path dir (str id ".jl")))
            (= 1 (count scripts)) (str (fs/path dir (first scripts)))
            :else (throw (ex-info (str dir
                        ": expected " id
                        ".jl or a single script, found " (vec
                            scripts))
                    {})))))

(defn tags-of
    "The tags a fitting test accepts: the `tag = \"...\"` entries of its RUNS table, a
    fixed list for the special scripts, or [\"\"] for a script with a single run."
    [id]
    (or (special-tags id)
        (if-let [[_ table] (re-find #"(?s)const RUNS = \[(.*?)\n\]"
                    (slurp8 (script-of id)))]
            (mapv second (re-seq #"tag = \"([^\"]+)\"" table))
            [""])))

(defn single-run?
    "True for the tag list of a script with a single run, which is the one empty tag."
    [tags]
    (= tags [""]))

(defn specs-of
    "The `ID[:tag]` specs of the fitting tests `selected`: one per tag, or the bare ID
    for a single-run script."
    [selected]
    (for [id selected tag (tags-of id)] (if (= tag "") id (str id ":" tag))))

;; --- command lines of the front ends in dev/

(defn split-args
    "Splits `argv` into the options of `allowed` (each `--key value`, in command-line
    order: [[key value] ...]), the `flags` that were given and the positional specs:
    {:opts :flags :specs}. Anything else starting with -- is an error that names the
    accepted ones after `word` (default \"options\")."
    ([who allowed flags argv] (split-args who allowed flags argv "options"))
    ([who allowed flags argv word]
        (loop [[a & more] argv
                acc {:opts [], :flags [], :specs []}]
            (cond (nil? a) acc
                (some #{a} flags) (recur more (update acc :flags conj a))
                (str/starts-with? a "--")
                (do (when-not (some #{a} allowed)
                        (fail who
                            (str "unknown option "
                                a
                                " ("
                                word
                                ": "
                                (str/join ", " (concat allowed flags))
                                ")")))
                    (when (empty? more)
                        (fail who (str "option " a " needs a value")))
                    (recur (rest more) (update acc :opts conj [a (first more)])))
                :else (recur more (update acc :specs conj a))))))

(defn check-specs
    "Checks the ID[:tag] specs: at least one, each a fitting test (with a tag where it
    has several runs)."
    [who specs]
    (when (empty? specs) (fail who "give at least one ID[:tag] (see: --list)"))
    (let [known (set (ids))]
        (doseq [spec specs
                :let [[id tag] (str/split spec #":" 2)
                    tags (when (known id) (tags-of id))]]
            (when-not (known id)
                (fail who (str "no fitting test '" id "' (see: --list)")))
            (when-not (some #{(or tag "")} tags)
                (if (single-run? tags)
                    (fail
                        who
                        (str id " has a single run and takes no tag, got '" tag "'"))
                    (fail who
                        (str id
                            " needs a tag, one of: "
                            (str/join ", " tags)
                            " (got '"
                            (if (seq tag) tag "none")
                            "')")))))))

(defn check-folders
    "Stops unless every one of `specs` names a fitting-test folder; only the ID before
    a `:` counts when `tagged` is true (the default), the whole word otherwise. The
    message lists the folders that exist."
    ([who specs] (check-folders who specs true))
    ([who specs tagged]
        (let [known (set (ids))
                bad (remove #(known (if tagged (first (str/split % #":" 2)) %)) specs)]
            (when (seq bad)
                (fail who
                    (str "no fitting test folder for: "
                        (str/join ", " bad)
                        " (available: "
                        (str/join " " (ids))
                        ")"))))))

(defn list-fits
    "Prints every fitting test with the tags it accepts."
    []
    (doseq [id (ids)
            :let [tags (tags-of id)]]
        (println (format "%-8s %s"
                id
                (if (single-run? tags)
                    "(single run, no tag)"
                    (str/join " " tags))))))

;; --- numbers
;;
;; C-style `printf` conversions on the exact binary value of the double: Java's `%f`
;; rounds the shortest decimal form instead (0.15 -> 0.2, where C gives 0.1), and its
;; `%g` neither strips zeros nor picks C's form.

(defn as-number
    "A numeric string as the number it stands for (\"3.20\" is 3.2, \"+7\" is 7), anything
    else unchanged."
    [v]
    (cond (not (string? v)) v
        (re-matches #"[-+]?\d+" v) (parse-long v)
        (re-matches #"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?" v) (parse-double
            v)
        :else v))

(defn- fmt-f
    "`%.<n>f` of x. A negative value that rounds to zero keeps its sign (\"-0.00\")."
    [x n]
    (let [s (-> (BigDecimal. (Math/abs (double x)))
                (.setScale n RoundingMode/HALF_EVEN)
                .toPlainString)]
        (if (neg? (Math/copySign 1.0 (double x))) (str "-" s) s)))

(defn- fmt-g
    "`%.<p>g` of x: p significant digits, trailing zeros dropped, the exponent form
    (\"1.23e+05\") below 1e-4 and from 10^p up."
    [x p]
    (if (zero? x)
        "0"
        (let [d (-> (BigDecimal. (Math/abs (double x)))
                    (.round (MathContext. p RoundingMode/HALF_EVEN))
                    .stripTrailingZeros)
                ;; decimal exponent of the rounded value
                e (- (.precision d) (.scale d) 1)
                digits (str (.unscaledValue d))]
            (str (when (neg? x) "-")
                (if (< -5 e p)
                    (.toPlainString d)
                    (str (first digits)
                        (when (next digits) (str "." (subs digits 1)))
                        (format "e%+03d" e)))))))

(defn fmt
    "A number (or numeric string) by the C conversion `spec`: %d, %.<n>f, %+.<n>f or
    %.<n>g. An error for anything that is not a number."
    [spec x]
    (let [[_ plus prec conv] (re-matches #"%(\+?)(?:\.(\d+))?([dfg])" spec)
            x (as-number x)
            n (some-> prec
                parse-long)]
        (when-not (number? x)
            (throw (ex-info (str "expected a number, got '" x "'") {})))
        (let [s (case conv
                    "d" (str (long x))
                    "f" (fmt-f x n)
                    "g" (fmt-g x n))]
            (if (and (seq plus) (not (str/starts-with? s "-"))) (str "+" s) s))))

(defn num-str
    "A value as the tools print a number: a double by its shortest digits (a whole one
    keeps its \".0\"; outside 1e-4 .. 1e16 the exponent form, \"6.75e-7\"), anything
    else by `str`."
    [v]
    (if (double? v)
        (let [d (.stripTrailingZeros (BigDecimal. (Double/toString v)))
                e (- (.precision d) (.scale d) 1)
                digits (str (.abs (.unscaledValue d)))
                plain (.toPlainString d)]
            (if (< -5 e 17)
                (if (str/includes? plain ".") plain (str plain ".0"))
                (str (when (neg? v) "-")
                    (first digits)
                    (when (next digits) (str "." (subs digits 1)))
                    "e"
                    (if (neg? e) "-" "+")
                    (abs e))))
        (str v)))

;; A decimal number as a regex fragment, one capture group: optional sign, fraction
;; and exponent.
(def num-re "([-+]?\\d+\\.?\\d*(?:[eE][-+]?\\d+)?)")
