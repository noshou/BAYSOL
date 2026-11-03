;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The recipes file: the fixture round trip, what is unusable, the caps and the names.

(ns baysol.tui.recipe-store-test
 (:require [baysol.tui.recipe-store :as store]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is]]))

(def ^:private fixture-file (io/file ".." "test" "fixtures" "buffer" "recipes.edn"))

(def ^:private rows
 (:solutes (edn/read-string
   (slurp (io/file ".." "test" "fixtures" "buffer" "buffer.edn")))))

(def ^:private row (first rows))

(defn ^:private in-folder
 [f]
 (let [root (support/temp-root)] (f root)))

(defn ^:private unusable?
 [f]
 (try (f)
  false
  (catch clojure.lang.ExceptionInfo e
   (= ::store/unusable (:type (ex-data e))))))

(deftest fixture-round-trip
 (in-folder
  (fn [root]
   (spit (store/recipes-file root) (slurp fixture-file))
   (let [recipes (store/read-recipes root)]
    (is (= ["SEC buffer" "Everything" "Customs" "empty"] (map :name recipes)))
    (is (= [3 11 4 0] (map #(count (:solutes %)) recipes)))
    (is (= rows (:solutes (second recipes))) "every kind of row survives")
    (store/write-recipes! root recipes)
    (is (= recipes (store/read-recipes root)))
    (is (not (.exists (io/file root "recipes.edn.tmp")))))
   (is (= 3 (count (store/recipe-solutes root "sec BUFFER")))
    "a recipe is found without regard to case")
   (is (nil? (store/recipe-solutes root "nothing"))))))

(deftest no-file-no-recipes
 (in-folder
  (fn [root]
   (is (= [] (store/read-recipes root)))
   (is (nil? (store/recipe-solutes root "x")))
   (spit (store/recipes-file root) "  ; just a comment\n")
   (is (= [] (store/read-recipes root)))
   (spit (store/recipes-file root) "")
   (is (= [] (store/read-recipes root))))))

(deftest save-adds-replaces-and-keeps
 (in-folder
  (fn [root]
   (spit (store/recipes-file root)
    "{:recipes [{:name \"A\" :solutes [] :note 1}] :other [1 2]}")
   (store/save-recipe! root "B" [row])
   (is (= ["A" "B"] (map :name (store/read-recipes root))))
   (store/save-recipe! root " a " [row row])
   (let [recipes (store/read-recipes root)]
    (is (= ["a" "B"] (map :name recipes))
     "replaced in place, under the new spelling")
    (is (= 2 (count (:solutes (first recipes)))))
    (is (= 1 (:note (first recipes))) "other keys of a recipe are kept"))
   (is (= {:other [1 2]}
     (dissoc (edn/read-string (slurp (store/recipes-file root)))
      :recipes))
    "other keys of the map are kept"))))

(deftest unusable-files-are-told-and-never-overwritten
 (doseq [text ["[1 2]" "{:recipes 3}" "{:recipes [1]}"
    "{:recipes [{:name \"\" :solutes []}]}"
    "{:recipes [{:name \"A\"}]}"
    "{:recipes [{:name \"A\" :solutes [{:kind :x}]}]}"
    "{:recipes [{:name \"A\" :solutes []} {:name \"a\" :solutes []}]}"
    "{:recipes [{:name 4 :solutes []}]}" "{:recipes [{:solutes []}]}"
    "{:recipes (" "{:recipes [{:name \"A\" :solutes {}}]}"]]
  (in-folder
   (fn [root]
    (spit (store/recipes-file root) text)
    (is (unusable? #(store/read-recipes root)) text)
    (is (unusable? #(store/save-recipe! root "B" [row])) text)
    (is (unusable? #(store/write-recipes! root [])) text)
    (is (= text (slurp (store/recipes-file root))) "never overwritten")))))

(deftest invalid-writes-are-refused
 (in-folder
  (fn [root]
   (is (unusable? #(store/write-recipes! root
      [{:name "A", :solutes [{:kind :x}]}])))
   (is (unusable? #(store/write-recipes! root [{:name " ", :solutes []}])))
   (is (unusable? #(store/write-recipes! root
      [{:name "A", :solutes []}
       {:name "A ", :solutes []}])))
   (is (not (.exists (store/recipes-file root))) "nothing was made"))))

(deftest the-caps
 (in-folder
  (fn [root]
   (let [many (mapv (fn [i] {:name (str "r" i), :solutes []}) (range 999))]
    (store/write-recipes! root many)
    (is (= 999 (count (store/read-recipes root))))
    (is (unusable? #(store/save-recipe! root "one more" [row])) "a 1000th recipe")
    (store/save-recipe! root "R5" [row])
    (is (= 999 (count (store/read-recipes root))) "a replace is fine at the cap"))
   (store/write-recipes! root [])
   (let [full (vec (repeat 999 row))]
    (store/save-recipe! root "full" full)
    (is (= 999 (count (store/recipe-solutes root "full"))))
    (is (unusable? #(store/save-recipe! root "full" (conj full row)))
     "a 1000th solute"))
   (spit (store/recipes-file root)
    (pr-str {:recipes (mapv (fn [i] {:name (str "r" i), :solutes []})
       (range 1000))}))
   (is (unusable? #(store/read-recipes root))
    "a file of 1000 recipes is unusable"))))

(deftest names
 (is (nil? (store/name-problem "SEC buffer")))
 (is (nil? (store/name-problem (apply str (repeat 40 "x")))))
 (is (= "40 characters at most" (store/name-problem (apply str (repeat 41 "x")))))
 (is (= "type a name first!" (store/name-problem "   ")))
 (is (= "type a name first!" (store/name-problem "")))
 (is (= "no control characters" (store/name-problem "a\tb")))
 (is (nil? (store/name-problem "ångström ± 😀")))
 (let [recipes [{:name "Alpha"} {:name "beta"}]]
  (is (= 0 (store/index-of-name recipes " ALPHA ")))
  (is (= 1 (store/index-of-name recipes "Beta")))
  (is (nil? (store/index-of-name recipes "gamma")))))

(deftest kinds
 (is (= "none" (store/kinds-summary [])))
 (is (= "3 solute 1 polymer 2 custom 4 seq"
   (store/kinds-summary
    (concat (repeat 3 {:kind :nonbiological})
     [{:kind :polymer}]
     [{:kind :custom-nonbio} {:kind :custom-polymer}]
     [{:kind :dna} {:kind :rna} {:kind :protein} {:kind :dna}]))))
 (is (= "1 solute" (store/kinds-summary [{:kind :nonbiological}])))
 (is (= "1 solute 3 polymer 4 custom 3 seq" (store/kinds-summary (take 11 rows)))
  "the fixture's own rows")
 (is (str/includes? (store/kinds-summary rows) "seq")))
