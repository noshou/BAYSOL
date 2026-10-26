#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Renders the LaTeX figures (.tex) of a folder to SVG, PDF, PNG or JPEG, next to them.
;;
;;     bb render-plots DIR [--recursive] [--type pdf|svg|png|jpeg]
;;
;;   DIR          the folder with the .tex files
;;   --recursive  also the files in its subfolders
;;   --type       the output format (default pdf). svg, png and jpeg also need poppler's
;;                `pdftocairo`; pdf needs only a LaTeX engine
;;
;; Needs `lualatex` or `xelatex` on the PATH. Each file is compiled in its own folder
;; and the .aux and .log are removed afterwards (a failed file keeps its .log). A file
;; that fails is reported and the others still run; the exit status is 1 if any failed.

(ns render-tex
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [babashka.process :refer [shell]]
        [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb render-plots")

(def ^:private types
    "The --type values: pdftocairo's flag and the extension of what it writes
    (nothing to convert for pdf)."
    {"pdf" nil, "svg" ["-svg" "svg"], "png" ["-png" "png"], "jpeg" ["-jpeg" "jpg"]})

(defn ^:private find-tex
    "The .tex files of `dir` (and of its subfolders if `rec`), sorted."
    [dir rec]
    (->> (fs/glob dir (if rec "**.tex" "*.tex"))
        (filter fs/regular-file?)
        sort))

(defn ^:private find-program
    "The path of the first of `names` on the PATH; an error that says what to install
    if there is none."
    [names hint]
    (or (some fs/which names)
        (throw (ex-info (str "could not find " (str/join " or " names)
                    " on the PATH; " hint)
                {}))))

(defn ^:private render
    "Compiles `file` in its own folder and, if `conversion` is [flag ext], converts the
    PDF (and removes it). Returns nil, or the reason it failed."
    [engine conversion file]
    (let [dir (str (fs/parent (fs/absolutize file)))
            fname (fs/file-name file)
            base (fs/strip-ext fname)
            ok? (fn [& cmd]
                (zero? (:exit
                        (apply
                            shell
                            {:dir dir, :continue true, :out :string, :err :string}
                            cmd))))
            tidy #(doseq [ext [".aux" ".log"]]
                (fs/delete-if-exists (fs/path dir (str base ext))))]
        (if-not (ok? engine "-interaction=nonstopmode" "-halt-on-error" fname)
            (str "LaTeX failed (see " base ".log)")
            (do (tidy)
                (when-let [[flag ext] conversion]
                    (if (apply ok?
                            "pdftocairo"
                            flag
                            (str base ".pdf")
                            ;; svg takes the output's name; png and jpeg take its name
                            ;; without the extension, and only they accept -singlefile
                            ;; (without it they number the page: a-1.png)
                            (if (= flag "-svg")
                                [(str base "." ext)]
                                ["-singlefile" base]))
                        (fs/delete (fs/path dir (str base ".pdf")))
                        "pdftocairo failed"))))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (some #{"--help" "-h"} argv)
        (c/usage)
        (let [{:keys [opts flags specs]}
                (c/split-args who ["--type"] ["--recursive"] argv)
                fmt (or (second (last opts)) "pdf")
                dir (first specs)]
            (when-not (= 1 (count specs))
                (c/fail
                    who
                    "give one directory: DIR [--recursive] [--type pdf|svg|png|jpeg]"))
            (when-not (fs/directory? dir)
                (c/fail who (str dir ": not a directory")))
            (when-not (contains? types fmt)
                (c/fail who
                    (str "unknown --type "
                        fmt
                        " (one of: "
                        (str/join ", " (sort (keys types)))
                        ")")))
            (let [engine
                    (find-program
                        ["lualatex" "xelatex"]
                        "install TeX Live (Linux), MacTeX (macOS) or MiKTeX (Windows)")
                    conversion (get types fmt)
                    _ (when conversion
                        (find-program ["pdftocairo"]
                            "install poppler (poppler-utils)"))
                    failed
                    (doall (for [file (find-tex dir (boolean (seq flags)))
                                :let [problem (render engine conversion file)]]
                            (do (println (if problem "FAILED" "ok    ") (str file))
                                (when problem [file problem]))))
                    failed (remove nil? failed)]
                (println (str (count failed) " failed"))
                (doseq [[file problem] failed]
                    (binding [*out* *err*] (println (str file ": " problem))))
                (when (seq failed) 1)))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
