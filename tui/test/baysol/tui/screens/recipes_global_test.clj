;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Recipes are GLOBAL: one `recipes.edn` in the BAYSOL data folder, shared by every project,
;; and a project only ever has its own copy of the rows in its own `buffer.edn`.

(ns baysol.tui.screens.recipes-global-test
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.projects :as projects]
  [baysol.tui.recipe-store :as store]
  [baysol.tui.screens.buffer-landing :as buffer-landing]
  [baysol.tui.screens.custom-landing :as custom-landing]
  [baysol.tui.screens.recipes-menu :as recipes-menu]
  [baysol.tui.support :as support :refer
   [background enter esc down eof has?]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))



(def ^:private rows
 (:solutes (edn/read-string
   (slurp (io/file ".." "test" "fixtures" "buffer" "buffer.edn")))))

(defn ^:private drive
 "Runs `(show! screen)` with the keys `inputs` fed, the last one ending the run; returns
 what it returned and the text of the last frame."
 [show! & inputs]
 (apply support/run-keys! show! (concat inputs [eof])))

(defn ^:private landing!
 "The buffer landing of project `dir` with `inputs`; returns the last frame's text."
 [dir & inputs]
 (second (apply drive #(buffer-landing/show! % background dir) inputs)))

(defn ^:private table!
 [& inputs]
 (second (apply drive #(recipes-menu/show! % background) inputs)))


(defn ^:private files-in
 "The relative names of every file under `dir`, sorted."
 [dir]
 (sort (for [f (file-seq (io/file dir))
    :when (.isFile ^java.io.File f)]
   (str (.relativize (.toPath (io/file dir)) (.toPath ^java.io.File f))))))

(def ^:private save-keys
 "From a buffer with solutes: the last option, which asks a name."
 [down down down enter])

(deftest saving-writes-the-data-folder-and-nothing-else-in-the-project
 (support/with-data-folder
  [root (support/temp-root)]
  (let [dir (projects/create! root "alpha")]
   (buffer/write-solutes! dir (vec (take 3 rows)))
   (let [before (files-in dir)]
    (is (not (.exists (store/recipes-file root))))
    (landing! dir save-keys "Shared" enter)
    (is (.isFile (store/recipes-file root))
     "recipes.edn is in the BAYSOL data folder")
    (is (= (io/file root "recipes.edn") (store/recipes-file root)))
    (is (= before (files-in dir)) "the project folder got nothing new")
    (is (not (.exists (io/file dir "recipes.edn"))))
    (is (= ["Shared"] (map :name (store/read-recipes root))))))))

(deftest two-projects-see-the-same-recipe
 (support/with-data-folder
  [root (support/temp-root)]
  (let [a (projects/create! root "alpha")
    b (projects/create! root "beta")
    c (projects/create! root "gamma")]
   (buffer/write-solutes! a (vec (take 3 rows)))
   (landing! a save-keys "Shared" enter)
   (testing "each project loads it into its own buffer.edn"
    (doseq [p [b c]]
     (landing! p enter "Shared" enter :ctrl-w))
    (is (= (vec (take 3 rows)) (buffer/read-solutes b)))
    (is (= (buffer/read-solutes b) (buffer/read-solutes c)))
    (is (not= (.getAbsolutePath (buffer/buffer-file b))
      (.getAbsolutePath (buffer/buffer-file c))))
    (is (= (files-in a) (files-in b)) "the same files, nothing else of the recipe"))
   (testing "a project that did not press ^w has nothing"
    (let [d (projects/create! root "delta")]
     (landing! d enter "Shared" enter)
     (is (= [] (buffer/read-solutes d))))))))

(deftest projects-and-recipes-do-not-follow-each-other
 (support/with-data-folder
  [root (support/temp-root)]
  (let [a (projects/create! root "alpha")
    b (projects/create! root "beta")]
   (buffer/write-solutes! a (vec (take 3 rows)))
   (landing! a save-keys "Shared" enter)
   (landing! b enter "Shared" enter :ctrl-w)
   (let [recipes-text (slurp (store/recipes-file root))]
    (testing "editing and saving the project's buffer leaves the recipe alone"
     (landing! b enter :ctrl-r :ctrl-w)
     (is (= 2 (count (buffer/read-solutes b))))
     (landing! b enter :ctrl-p esc :ctrl-x)
     (is (= recipes-text (slurp (store/recipes-file root))))
     (is (= 3 (count (store/recipe-solutes root "Shared")))))
    (let [b-text (slurp (buffer/buffer-file b))
      a-text (slurp (buffer/buffer-file a))]
     (testing "editing the recipe in the recipes table leaves the projects alone"
      (table! enter enter :ctrl-r :ctrl-w :ctrl-x)
      (is (= 2 (count (store/recipe-solutes root "Shared"))))
      (is (= b-text (slurp (buffer/buffer-file b))))
      (is (= a-text (slurp (buffer/buffer-file a)))))
     (testing "removing and renaming the recipe leaves the projects alone"
      (table! enter
       (vec (repeat 10 KeyType/Backspace))
       "Renamed" enter
       :ctrl-x :ctrl-w)
      (is (= ["Renamed"] (map :name (store/read-recipes root))))
      (table! :ctrl-r :ctrl-w)
      (is (= [] (store/read-recipes root)))
      (is (= b-text (slurp (buffer/buffer-file b))))
      (is (= a-text (slurp (buffer/buffer-file a))))))))))

(deftest a-recipe-made-in-one-project-is-loadable-in-another
 (support/with-data-folder
  [root (support/temp-root)]
  (let [a (projects/create! root "alpha")
    b (projects/create! root "beta")]
   (is (not (.exists (store/recipes-file root))))
   (testing "no recipes.edn: no saved recipes"
    (is (has? (landing! b enter) "no saved recipes!")))
   (buffer/write-solutes! a (vec (take 2 rows)))
   (landing! a save-keys "Made in alpha" enter)
   (testing "now beta can load it"
    (let [text (landing! b enter)]
     (is (not (has? text "no saved recipes!")))
     (is (has? text "Made in alpha (2)")))
    (landing! b enter enter :ctrl-w)
    (is (= (vec (take 2 rows)) (buffer/read-solutes b)))))))

(deftest every-screen-reads-the-same-file-through-the-same-path-function
 (support/with-data-folder
  [root (support/temp-root)]
  (let [alt (support/temp-root)
    asked (atom [])
    real store/recipes-file
    dir (projects/create! root "alpha")]
   (spit (real alt) (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))
   (is (not (.exists (real root))) "the data folder itself has no recipes.edn")
   (with-redefs [store/recipes-file (fn [r] (swap! asked conj r) (real alt))]
    (testing "the recipes table"
     (is (has? (table!) "SEC buffer")))
    (testing "the custom landing"
     (is (has? (second (drive #(custom-landing/show! % background)))
       "recipes (4)")))
    (testing "the buffer landing"
     (is (has? (landing! dir enter) "SEC buffer (3)")))
    (testing
     "all of them asked the data folder for the file, through the one function"
     (is (seq @asked))
     (is (= #{root} (set @asked))))))))
