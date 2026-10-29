#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Asks the TeX Live installation which fonts the figures can use.
;;
;;     bb fonts NAME [NAME ...]
;;     bb fonts --list
;;
;;   NAME    a font name as `fontspec` takes it ("TeX Gyre Pagella", "Latin Modern Math";
;;           case and spaces do not matter): prints `true` or `false` for each, and the
;;           exit status is 1 if any is `false`. Any such name is a valid `font` of
;;           `results`, alone or in a (text font, math font) pair
;;   --list  every font family installed here (from fontconfig's `fc-list`, or else from
;;           LuaLaTeX's own index), the math fonts first
;;
;; The check is `luaotfload-tool --find`, which comes with TeX Live (the same lookup
;; LuaLaTeX does) and does not rebuild its font database: a font installed since the
;; database was last built needs `luaotfload-tool --update` first. A figure with a font
;; needs `lualatex` or `xelatex`.

(ns fonts
 (:require [babashka.classpath :refer [add-classpath]]
  [babashka.fs :as fs]
  [babashka.process :refer [shell]]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb fonts")

(defn ^:private available?
 "Whether LuaLaTeX finds the font `family`. `--no-reload` keeps a miss from rebuilding
 the font database."
 [family]
 (str/includes? (:out (shell {:continue true, :out :string, :err :string}
    "luaotfload-tool"
    "--no-reload"
    (str "--find=" family)))
  "found!"))

(defn ^:private families
 "Every installed font family, sorted: from fc-list, whose names are the ones to write
 (a family can have several, separated by commas), or else from LuaLaTeX's index, whose
 names are lower case without spaces (which `available?` accepts as well)."
 []
 (if (fs/which "fc-list")
  (->> (str/split-lines (:out (shell {:out :string} "fc-list" ":" "family")))
   (mapcat #(str/split % #","))
   (map str/trim)
   (remove str/blank?)
   distinct
   sort)
  (->> (str/split-lines (:out (shell {:continue true, :out :string, :err :string}
      "luaotfload-tool" "--no-reload"
      "--list=*" "--fields=familyname")))
   (map str/trim)
   (remove #(or (str/blank? %) (str/includes? % "<none>")))
   distinct
   sort)))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [{:keys [flags specs]} (c/split-args who [] ["--list"] argv)]
   (when-not (fs/which "luaotfload-tool")
    (c/fail who
     (str "luaotfload-tool not found: it comes with TeX Live, "
      "and without it no font can be checked")))
   (cond (and (seq flags) (seq specs))
    (c/fail who "give font names or --list, not both")
    (seq flags) (let [math? #(str/includes? (str/lower-case %) "math")
      all (families)]
     (println
      "math fonts (the second entry of a (text, math) pair)")
     (run! #(println " " %) (filter math? all))
     (println "\nfont families (the text font)")
     (run! #(println " " %) (remove math? all))
     nil)
    (empty? specs) (c/fail who "give one or more font names, or --list")
    :else (let [results (doall (for [font specs] [font (available? font)]))]
     (doseq [[font ok] results] (println (str font ": " ok)))
     (when-not (every? second results) 1))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
