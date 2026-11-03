;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The saved recipes of the user: `recipes.edn` in the BAYSOL data folder, next to
;; `settings.edn` and `custom-solutes.edn` (it belongs to the user, not to a project). A
;; recipe is a named buffer: the same rows a project's `buffer.edn` has (the schema of
;; `test/fixtures/buffer/buffer.edn`, checked by `baysol.tui.buffer/row-problem`; custom
;; rows are snapshots, so a recipe is self-contained). An EDN map whose `:recipes` is a
;; vector of maps, one for each recipe:
;;
;;   {:recipes [{:name "SEC buffer",
;;               :solutes [{:kind :nonbiological, :name "NaCl", :arg "sodium chloride",
;;                          :mM 150.0, :sigma-mM 5.0}
;;                         ...]}
;;              ...]}
;;
;; A recipe is keyed by its name: unique without regard to case, not blank. At most 999
;; recipes (the counter of the recipes table has room for three digits), each of at most
;; 999 solutes. Other keys of the map are kept as they are on write. A missing, empty or
;; comment-only file is no recipes; a file that is not an EDN map, whose `:recipes` is not
;; a vector of maps with a name and a vector of valid rows, that has a name twice or more
;; recipes or solutes than the limits, is unusable, and is never written over. The project
;; side never reads this file: loading a recipe copies its rows into the project's own
;; `buffer.edn` (and the Julia side only ever reads that file).

(ns baysol.tui.recipe-store
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.edn-store :as store]
  [baysol.tui.limits :as limits]
  [baysol.tui.text :as txt]
  [clojure.java.io :as io]
  [clojure.string :as str]))

(def max-name
 "The most characters a recipe name typed in the TUI may have."
 40)

(defn recipes-file
 "The `recipes.edn` (a File) of the BAYSOL folder `root`."
 [root]
 (io/file root "recipes.edn"))

(defn name-problem
 "What is wrong with `n` as the name of a recipe, a short message, or nil: blank, longer
 than `max-name`, or with a control character in it. Whether it is taken is for
 [[index-of-name]]."
 [n]
 (cond (str/blank? n) "type a name first!"
  (> (count (str/trim n)) max-name) (str max-name " characters at most")
  (re-find #"\p{Cc}" n) "no control characters"))

(defn index-of-name
 "The position in the vector of recipes `recipes` of the recipe named `n` (without regard
 to case and to the spaces at the ends), or nil."
 [recipes n]
 (let [t (txt/fold n)]
  (first (keep-indexed #(when (= t (txt/fold (:name %2))) %1) recipes))))

(defn ^:private usable-recipe?
 "Whether `r` is a map with a name and at most 999 valid buffer rows."
 [r]
 (and (map? r)
  (string? (:name r))
  (not (str/blank? (:name r)))
  (vector? (:solutes r))
  (<= (count (:solutes r)) limits/max-rows)
  (every? map? (:solutes r))
  (not-any? buffer/row-problem (:solutes r))))

(defn ^:private usable-recipes?
 [recipes]
 (and (vector? recipes)
  (<= (count recipes) limits/max-rows)
  (every? usable-recipe? recipes)
  (let [lowered (map #(txt/fold (:name %)) recipes)]
   (= (count lowered) (count (distinct lowered))))))

(defn ^:private unusable
 [message]
 (ex-info message {:type ::unusable}))

(defn ^:private read-map
 "The map in the file of `root`: `{}` for no file or no content. Throws an exception
 (`:type ::unusable`) if the file is not one EDN map of the kind described above."
 [root]
 (store/read-map (recipes-file root)
  {:type ::unusable,
   :name "recipes.edn",
   :expected "a map of valid recipes",
   :valid? #(usable-recipes? (:recipes % []))}))

(defn read-recipes
 "The recipes of the folder `root`, a vector of `{:name :solutes}` maps (empty for none).
 Throws an exception (`:type ::unusable`) if the file cannot be used."
 [root]
 (vec (:recipes (read-map root) [])))

(defn recipe-solutes
 "The solutes of the recipe named `n` in the folder `root` (a vector), or nil when there
 is no such recipe. Throws like [[read-recipes]]."
 [root n]
 (let [recipes (read-recipes root)]
  (some->> (index-of-name recipes n)
   (nth recipes)
   :solutes)))

(defn write-recipes!
 "Writes `recipes` (a vector of `{:name :solutes}`) as the recipes of the folder `root`,
 the other keys of the file kept, through a temporary file that replaces it in one step.
 The file is made if there is none; one that cannot be used is not touched (the exception
 of [[read-recipes]] is thrown). Recipes that break the rules above are not written: an
 exception (`:type ::unusable`) is thrown first. Returns the file."
 [root recipes]
 (let [recipes (vec recipes)]
  (when-not (usable-recipes? recipes) (throw (unusable "not valid recipes")))
  (let [others (dissoc (read-map root) :recipes)
    file (recipes-file root)
    one (fn [r]
     (str "{:name "
      (pr-str (:name r))
      "\n   :solutes ["
      (str/join "\n             " (map pr-str (:solutes r)))
      "]"
      (apply str
       (for [[k v] (dissoc r :name :solutes)]
        (str "\n   " (pr-str k) " " (pr-str v))))
      "}"))
    text (store/map-text :recipes (map one recipes) others)]
   (store/write-atomic! file text))))

(defn save-recipe!
 "Saves the recipe `n` with `solutes` in the folder `root`: a recipe of that name (without
 regard to case) is replaced where it stands, else the recipe goes at the end. Everything
 else in the file is kept. Throws like [[write-recipes!]] (too many recipes or solutes, an
 invalid row, an unusable file). Returns the file."
 [root n solutes]
 (let [recipes (read-recipes root)
   n (str/trim n)
   recipe {:name n, :solutes (vec solutes)}]
  (write-recipes! root
   (if-let [i (index-of-name recipes n)]
    (assoc recipes i (merge (nth recipes i) recipe))
    (conj recipes recipe)))))

(defn kinds-summary
 "A compact summary of the rows `solutes`: the counts of each group that has any, as
 `3 solute 1 polymer 2 custom 4 seq` (non-biological solutes, polymers, custom ones of
 either kind, and DNA, RNA and protein together as `seq`); `none` for no rows."
 [solutes]
 (let [group (fn [row]
    (case (:kind row)
     :nonbiological "solute"
     :polymer "polymer"
     (:custom-nonbio :custom-polymer) "custom"
     "seq"))
   counts (frequencies (map group solutes))
   parts (for [g ["solute" "polymer" "custom" "seq"]
     :when (counts g)]
    (str (counts g) " " g))]
  (if (seq parts) (str/join " " parts) "none")))
