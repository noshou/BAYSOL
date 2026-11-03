;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Ctrl-X is BACK from anywhere: in every mode of a screen (a prompt, a dropdown, a cell
;; being edited, a question, a form page, the add flow at any stage) it drops what is open,
;; writes nothing and makes the screen return `:back` to its parent. It never quits the
;; program. Each test runs the real screen on a virtual terminal and asserts what `show!`
;; returns; a screen that kept waiting for keys is given escapes after a while and the
;; result is `:timeout`, which fails the test.

(ns baysol.tui.screens.back-key-test
 (:require
  [baysol.tui.buffer :as buffer]
  [baysol.tui.core.app :as app]
  [baysol.tui.custom :as custom]
  [baysol.tui.models :as models]
  [baysol.tui.projects :as projects]
  [baysol.tui.runs :as runs]
  [baysol.tui.screens.buffer-landing :as buffer-landing]
  [baysol.tui.screens.custom-landing :as custom-landing]
  [baysol.tui.screens.custom-nonbio-form :as nonbio-form]
  [baysol.tui.screens.custom-polymer-form :as polymer-form]
  [baysol.tui.screens.custom-solutes-menu :as custom-menu]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.main-menu :as main-menu]
  [baysol.tui.screens.models-menu :as models-menu]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.project-menu :as project-menu]
  [baysol.tui.screens.recipes-menu :as recipes-menu]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.screens.sheets :as sheets]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.screens.state :as state]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :as support :refer [background enter esc down eof in-project]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))


(def ^:private right KeyType/ArrowRight)
(def ^:private left KeyType/ArrowLeft)
(def ^:private delete KeyType/Delete)

(defn ^:private run
 "Runs `(show! screen)` on a new virtual terminal with `inputs` fed (a string is each of
 its characters, a vector its keys); returns what it returned, or `:timeout` if it was
 still waiting for a key after 20 seconds (it is then given escapes and the end of the
 terminal, so no thread is left behind)."
 [show! & inputs]
 (first (apply support/run-keys! show! inputs)))

(defn ^:private snapshot
 "The contents of every file under `root`: a map of path to text. What a screen must not
 change when it is left with Ctrl-X."
 [^java.io.File root]
 (into {}
  (for [f (file-seq root)
    :when (.isFile f)]
   [(str f) (slurp f)])))

(defn ^:private changed
 "The paths whose text differs between the snapshots `a` and `b` (or exist in one only)."
 [a b]
 (vec (sort (for [k (distinct (concat (keys a) (keys b)))
     :when (not= (get a k) (get b k))]
    k))))

(def ^:private back-key :ctrl-x)

(deftest the-key-and-the-pickers
 (is (state/back-key? :ctrl-x))
 (is (not-any? state/back-key? [:ctrl-w :ctrl-u \x esc enter eof nil]))
 (testing "a picker gives :back for Ctrl-X and still :cancel for Escape"
  (let [st (picker/initial ["a" "b"] nil)]
   (is (= :back (picker/step st :ctrl-x)))
   (is (= :cancel (picker/step st esc)))
   (is (= {:chosen "a"} (picker/step st enter)))))
 (testing "a landing prompt gives :back for Ctrl-X and still :cancel for Escape"
  (let [st (landing/prompt-initial)
    step #(landing/prompt-step st % (constantly nil) 10)]
   (is (= :back (step :ctrl-x)))
   (is (= :cancel (step esc))))))

;; --- the project menu: the dropdown of runs

(deftest project-menu-runs-dropdown
 (in-project
  (fn [_root dir]
   (runs/record-run! dir {:models ["m"], :output-dir (support/temp-root)})
   (let [before (snapshot dir)]
    (doseq [k [\d \g]]
     (is (= :back (run #(project-menu/show! % background dir) k back-key)) (str k))
     (testing
      "Escape closes only the dropdown, the menu stays (and Ctrl-X then leaves it)"
      (is (= :back (run #(project-menu/show! % background dir) k esc back-key))
       (str k))
      (is (= :quit (run #(project-menu/show! % background dir) k esc esc))
       (str k))))
    (is (= before (snapshot dir)))))))

;; --- the main menu: no parent, a prompt is cancelled, the menu stays

(def ^:private main-loop @#'main-menu/main-loop)

(deftest main-menu-prompts-are-cancelled
 (support/with-data-folder
  [root (support/temp-root)]
  (let [before (snapshot root)]
   (testing
    "new: Ctrl-X cancels the name prompt, the menu stays, Ctrl-X there does nothing"
    ;; if the menu had returned, Escape would not be what ends the run (`:quit`)
    (is (= :quit (run #(main-loop %) \n "ab" back-key back-key esc)))
    (is (= before (snapshot root)))
    (is (empty? (projects/list-projects @app/projects-dir))))
   (testing "the prompt itself returns nil, makes nothing"
    (is (nil? (run #(@#'main-menu/ask-name! %) "abc" back-key)))
    (is (empty? (projects/list-projects @app/projects-dir)))))
  (let [dir (projects/create! root "alpha")
    before (snapshot root)]
   (testing "load: Ctrl-X in the project picker cancels it; the menu stays"
    (is (= :quit (run #(main-loop %) \l back-key back-key esc)))
    (is (= before (snapshot root))))
   (testing "the picker itself returns nil"
    (is (nil? (run #(@#'main-menu/pick-project! % ["alpha"]) "al" back-key))))
   (testing "Ctrl-X in the plain main menu does nothing"
    (is (= :quit (run #(main-loop %) back-key back-key esc))))
   (is (= before (snapshot root)))
   (is (some? dir)))))

;; --- the settings menu and the sheets

(defn ^:private sheet-and-entries
 [kind]
 [(sheets/load-sheet (str (name kind) "-settings"))
  (settings/screen-entries (settings/merge-defaults (settings/read-defaults) nil)
   kind)])

(defn ^:private catalog
 [setting kind]
 (case kind
  :colour ["black" "crimson" "gray20"]
  :font (if (str/includes? setting "MATH") ["Pagella Math"] ["Pagella" "Times"])
  []))

(defn ^:private state0
 [entries]
 (sheets/initial-state entries catalog (constantly nil) (settings/read-relations)))

(defn ^:private at
 "The state of the sheet at the page of `setting`: the pages are walked until the cursor
 is on it."
 [sheet st setting]
 (let [here #(sheets/cursor-setting (nth (:pages sheet) (:i %)))
   move (fn [st k]
    (let [r (sheets/step sheet st k)] (when (map? r) (:state r))))]
  (loop [st st
    seen #{}]
   (cond (= setting (here st)) st
    (seen (:i st)) (throw (ex-info "setting not found" {:setting setting}))
    :else (let [d (move st down)]
     (if (and d (not= (:i d) (:i st)))
      (recur d (conj seen (:i st)))
      (recur (move st right) (conj seen (:i st)))))))))

(deftest sheets-step-gives-back-in-every-edit-mode
 (doseq [[kind setting keys-in label]
   [[:sampler "N_ADAPT" [enter] "a number, just opened"]
    [:sampler "N_ADAPT" [enter \9] "a number being typed"]
    [:plots "PLOT_COLOUR_MAP" [enter] "a colour dropdown"]
    [:plots "PLOT_COLOUR_MAP" [enter \c] "a colour dropdown being typed in"]
    [:plots "PLOT_TEXT_FONT" [enter] "a font dropdown"]
    [:plots "PLOT_WIDTH_HEIGHT_CM" [enter] "a tuple"]
    [:plots "PLOT_WIDTH_HEIGHT_CM" [enter down \5] "a tuple, second cell"]
    [:plots "PLOT_COLOUR_BAND" [enter] "a tuple with a colour part"]
    [:plots "PLOT_COLOUR_BAND" [enter \c] "a colour part being typed in"]
    [:output "FIGURES_FORMATS" [enter] "the format tabs"]
    [:output "FIGURES_FORMATS" [enter right enter]
     "the format tabs, one toggled"]]]
  (let [[sheet entries] (sheet-and-entries kind)
    st (at sheet (state0 entries) setting)
    opened (reduce (fn [st k] (:state (sheets/step sheet st k))) st keys-in)]
   (is (some? (:edit opened)) (str label ": the edit is open"))
   (is (= :back (sheets/step sheet opened :ctrl-x)) label)
   (testing "Escape still only closes the edit"
    (is (map? (sheets/step sheet opened esc)) label))))
 (testing "and not editing, as before"
  (let [[sheet entries] (sheet-and-entries :sampler)]
   (is (= :back (sheets/step sheet (state0 entries) :ctrl-x))))))

(deftest sheets-screen-returns-back-with-an-edit-open
 (doseq [[kind keys-in] [[:sampler [enter]] [:sampler [enter "12"]] [:plots [enter]]
    [:plots [enter "c"]] [:output [enter]] [:model [enter]]]]
  (let [[sheet entries] (sheet-and-entries kind)
    saved (atom [])
    result (run (fn [screen]
      (sheets/show! screen
       sheet
       background
       {:entries entries,
        :catalog catalog,
        :swatch (constantly nil),
        :relations (settings/read-relations),
        :save! #(swap! saved conj [%1 %2])}))
     keys-in
     back-key)]
   (is (= :back result) (str kind " " keys-in))
   (is (empty? @saved) "nothing is saved"))))

(deftest settings-menu-and-its-sheets
 (support/with-data-folder
  [root (support/temp-root)]
  (settings/load! root)
  (let [before (snapshot root)]
   (testing "the menu itself"
    (is (= :back (run #(settings-menu/show! % background) back-key))))
   (testing "an edit open on a sheet: Ctrl-X closes the sheet only, the menu stays"
    ;; `p` opens the plots sheet; the edit is open when Ctrl-X comes; then the menu is
    ;; still there, and Escape (which would only close an edit) quits it
    (is (= :quit
      (run #(settings-menu/show! % background) \p enter "1" back-key esc)))
    (is (= :quit (run #(settings-menu/show! % background) \a enter back-key esc)))
    (is (= :back
      (run #(settings-menu/show! % background) \u enter back-key back-key))))
   (testing "the custom landing under the global menu"
    (is (= :quit (run #(settings-menu/show! % background) :ctrl-e back-key esc)))
    (is (= :back
      (run #(settings-menu/show! % background) :ctrl-e back-key back-key))))
   (is (= before (snapshot root))))))

;; --- the buffer table (the add flow and the cell edits of an existing row)

(def ^:private rows
 (:solutes (edn/read-string
   (slurp (io/file ".." "test" "fixtures" "buffer" "buffer.edn")))))

(defn ^:private table-run
 [dir & inputs]
 (apply run #(solutes-menu/show! % background dir) inputs))

(deftest buffer-table-add-flow
 (in-project
  (fn [root dir]
   (let [folder (support/temp-root)
     fasta (str (doto (io/file folder "primer.fasta") (spit ">p1\nACGTTGCA\n")))
     stages
     {"^n name" [:ctrl-n],
      "^n name typed" [:ctrl-n "tri"],
      "^n mM" [:ctrl-n "tris" enter],
      "^n ±" [:ctrl-n "tris" enter "1" enter],
      "^p name" [:ctrl-p],
      "^p family choice" [:ctrl-p "peg" enter],
      "^p params cell" [:ctrl-p "peg" enter enter],
      "^p params typed" [:ctrl-p "peg" enter enter "22"],
      "^p mM" [:ctrl-p "peg" enter enter "22" enter],
      "^p ±" [:ctrl-p "peg" enter enter "22" enter "0.1" enter],
      "^p second arg" [:ctrl-p "pluronic" enter "10" enter],
      "^f path prompt" [:ctrl-f],
      "^f path typed" [:ctrl-f "some/pa"],
      "^f mM" [:ctrl-f fasta enter],
      "^e DNA/RNA choice" [:ctrl-e],
      "^e path prompt" [:ctrl-e enter],
      "^e path typed" [:ctrl-e enter fasta],
      "^e mM" [:ctrl-e enter fasta enter],
      "^e ±" [:ctrl-e enter fasta enter "0.01" enter]}
     start (snapshot dir)]
    (doseq [[label ks] stages]
     (is (= :back (apply table-run dir (concat ks [back-key]))) label)
     (is (= start (snapshot dir)) (str label ": nothing is written")))
    (testing "Escape still stops only the flow: the table is there for the next key"
     (is (= :quit (table-run dir :ctrl-n "tris" esc esc))))
    (is (= start (snapshot dir)))
    (testing "an existing row, every cell, and nothing written"
     (buffer/write-solutes! dir (vec (take 6 rows)))
     (let [before (snapshot dir)]
      (doseq [[label ks] {"name cell" [enter],
         "name typed" [enter "zz"],
         "mM cell" [enter enter],
         "± cell" [enter enter enter],
         "params cell" [down down enter enter],
         "params typed" [down down enter enter "30"]}]
       (is (= :back (apply table-run dir (concat ks [back-key]))) label)
       (is (= before (snapshot dir)) (str label ": nothing is written")))))
    (testing "the plain table, as before"
     (is (= :back (table-run dir back-key))))
    (is (some? root)))))) ; the folder of the test

;; --- the custom solutes table and the two form pages

(defn ^:private custom-run
 [& inputs]
 (apply run #(custom-menu/show! % background) inputs))

(def ^:private form-cases
 {"nonbio"
  [(fn [& ks]
    (apply run
     #(nonbio-form/show! %
      background
      custom/blank-nonbiological
      {:fallback 3.04, :others [], :builtin? nil})
     ks))
   {"browsing" [],
    "name cell" [enter],
    "name typed" [enter "ab"],
    "formula cell" [down enter "C2H6O"],
    "Z cell" [down down enter "5"],
    "PMV cell" [down down down enter "7.5"],
    "± cell" [down down down down enter "1"]}],
  "polymer"
  [(fn [& ks]
    (apply run
     #(polymer-form/show! %
      background
      custom/blank-polymer
      {:others [], :builtin? nil})
     ks))
   {"browsing" [],
    "name cell" [enter],
    "name typed" [enter "chain"],
    "unit formula cell" [down right enter "(C2H4O)n"],
    "unit slope cell" [down right right enter "36"],
    "unit label cell" [down enter "A"],
    "end formula cell" [down down down down left left enter "H2O"],
    "end Z cell" [down down down down left enter "10"],
    "end PMV cell" [down down down down enter "19"]}]})

(deftest the-form-pages
 (doseq [[kind [show cases]] form-cases
   [label ks] cases]
  (is (= :back (apply show (concat ks [back-key]))) (str kind " " label))
  (testing "Escape still cancels (nil), only for what was open"
   (is (nil? (apply show (concat ks [esc esc esc])))
    (str kind " " label " escapes")))))

(deftest the-custom-solutes-table
 (support/with-data-folder
  [root (support/temp-root)]
  (settings/load! root) ; reading the settings makes their file: not what is tested
  (let [before (snapshot root)]
   (is (= :back (custom-run back-key)))
   (testing
    "a form is left with Ctrl-X: the table continues (one screen up), then again"
    (doseq [[label ks] [["^n form" [:ctrl-n]]
       ["^n form, a cell" [:ctrl-n enter "NA"]]
       ["^p form" [:ctrl-p]]
       ["^p form, a cell" [:ctrl-p enter "ch"]]
       ["^p form, a unit cell"
        [:ctrl-p down right enter "(C2H4O)n"]]]]
     (is (= :quit (apply custom-run (concat ks [back-key esc]))) label)
     (is (= :back (apply custom-run (concat ks [back-key back-key]))) label)))
   (is (= before (snapshot root)) "custom-solutes.edn is not written"))))

;; --- the recipes table and its editor

(def ^:private fixture-recipes
 (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))

(defn ^:private recipes-run
 [& inputs]
 (apply run #(recipes-menu/show! % background) inputs))

(deftest the-recipes-table
 (support/with-data-folder
  [root (support/temp-root)]
  (spit (io/file root "recipes.edn") fixture-recipes)
  (let [before (snapshot root)]
   (testing "the name prompt of Enter and of ^n"
    (doseq [[label ks] [["Enter" [enter]] ["Enter, typed" [enter "x"]]
       ["^n" [:ctrl-n]] ["^n, typed" [:ctrl-n "brand new"]]]]
     (is (= :back (apply recipes-run (concat ks [back-key]))) label)))
   (testing "Escape cancels only the prompt (and the prompt had a name to give up)"
    (is (= :quit (recipes-run enter "x" esc esc))))
   (testing
    "the editor reached from the table: Ctrl-X goes back to the table, not further"
    (doseq [[label ks] [["Enter, name taken, editor" [enter enter]]
       ["^n, editor" [:ctrl-n "brand new" enter]]
       ["editor, a flow open" [enter enter :ctrl-n "tris"]]
       ["editor, a cell open" [enter enter enter]]]]
     ;; a recipe made by ^n stays a draft row of the table: leaving asks, Enter discards
     (let [more (if (= label "^n, editor") [enter] [])]
      (is (= :quit (apply recipes-run (concat ks [back-key esc] more))) label)
      (is (= :back (apply recipes-run (concat ks [back-key back-key] more)))
       label))))
   (is (= before (snapshot root)) "recipes.edn is not written"))))

;; --- the buffer landing

(defn ^:private landing-run
 [dir & inputs]
 (apply run #(buffer-landing/show! % background dir) inputs))

(deftest the-buffer-landing
 (in-project
  (fn [root dir]
   (buffer/write-solutes! dir (vec (take 3 rows)))
   (spit (io/file root "recipes.edn") fixture-recipes)
   (settings/load! root)
   (let [before (snapshot root)
     ;; with solutes: edit, load, new, save
     to-save [down down down]
     to-load [down]]
    (testing "the name prompt of `save`"
     (is (= :back (apply landing-run dir (concat to-save [enter back-key]))))
     (is (= :back
       (apply landing-run dir (concat to-save [enter "mine" back-key])))))
    (testing "the replace question (the name is taken)"
     (is (= :back
       (apply landing-run
        dir
        (concat to-save [enter "Everything" enter back-key])))))
    (testing "the recipe dropdown of `load`"
     (is (= :back (apply landing-run dir (concat to-load [enter back-key]))))
     (is (= :back (apply landing-run dir (concat to-load [enter "ev" back-key])))))
    (testing "Escape cancels only the prompt, the landing stays"
     (is (= :quit (apply landing-run dir (concat to-save [enter "mine" esc esc])))))
    (testing "the table that opens from it goes back to the landing, which stays"
     (is (= :quit (landing-run dir enter :ctrl-n "tris" back-key esc)))
     (is (= :back (landing-run dir enter :ctrl-n "tris" back-key back-key))))
    (is (= [] (changed before (snapshot root)))
     "buffer.edn and recipes.edn are not written")))))

;; --- the custom landing

(deftest the-custom-landing
 (support/with-data-folder
  [root (support/temp-root)]
  (settings/load! root)
  (let [before (snapshot root)
    landing! #(apply run (fn [s] (custom-landing/show! s background)) %&)]
   (is (= :back (landing! back-key)))
   (is (= :quit (landing! enter back-key esc))
    "the recipes table, back to the landing")
   (is (= :quit (landing! down enter back-key esc)) "the custom solutes table")
   (is (= :quit (landing! down enter :ctrl-n back-key back-key esc))
    "the form, then the table, then the landing stays")
   (is (= before (snapshot root))))))

;; --- the models part

(defn ^:private models-run
 [dir & inputs]
 (apply run
  #(models-menu/show! % background (get project-menu/pages :page1) dir)
  inputs))

(deftest the-models-part
 (support/with-data-folder
  [root (support/temp-root)]
  (let [dir (projects/create! root "demo")
    src (support/temp-root)
    pdb (io/file src "one.pdb")]
   (spit pdb "ATOM")
   (models/add-model! dir (str pdb))
   (let [before (snapshot dir)]
    (testing "the path prompt"
     (is (= :back (models-run dir back-key)))
     (is (= :back (models-run dir "/some/pa" back-key))))
    (testing "the list of models"
     (is (= :back (models-run dir \m back-key)))
     (is (= :back (models-run dir \m "on" back-key))))
    (testing "the delete warning, and the model is kept"
     (is (= :back (models-run dir \m delete back-key)))
     (is (= ["one.pdb"] (models/list-models dir))))
    (testing "Escape still closes only the warning, then the list, then the part"
     (is (= :done (models-run dir \m delete esc esc esc))))
    (testing
     "the project menu goes on after the models part is left: it does not return"
     (is (= :quit (run #(project-menu/show! % background dir) \m back-key esc))))
    (is (= before (snapshot dir)))))))
