;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The custom landing run for real on a virtual terminal: what it says of the two files,
;; the two tables it opens and the way back, and files that cannot be used.

(ns baysol.tui.screens.custom-landing-test
 (:require [baysol.tui.custom-store :as custom-store]
  [baysol.tui.recipe-store :as store]
  [baysol.tui.screens.custom-landing :as landing]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.support :as support :refer
   [background enter esc down up eof has?]]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]]))



(def ^:private fixture-recipes
 (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))

(def ^:private fixture-customs
 (slurp (io/file ".." "test" "fixtures" "buffer" "custom-solutes.edn")))

(defn ^:private run!-keys
 [& inputs]
 (apply support/run-keys! #(landing/show! % background) inputs))

(defn ^:private snap [& inputs] (second (apply run!-keys (concat inputs [eof]))))


(deftest labels-and-status
 (is (= ["recipes (3)" "solutes (12)"] (landing/options {:recipes 3, :solutes 12})))
 (is (= ["recipes (?)" "solutes (0)"]
   (landing/options {:recipes ::landing/unusable, :solutes 0})))
 (is (= "recipes.edn: 3 recipes  custom-solutes.edn: 12 solutes"
   (landing/status-text {:recipes 3, :solutes 12})))
 (is (= "recipes.edn: 1 recipe  custom-solutes.edn: 1 solute"
   (landing/status-text {:recipes 1, :solutes 1})))
 (is (= "recipes.edn: none yet  custom-solutes.edn: none yet"
   (landing/status-text {:recipes 0, :solutes 0})))
 (is (= "recipes.edn unusable!  custom-solutes.edn: 2 solutes"
   (landing/status-text {:recipes ::landing/unusable, :solutes 2})))
 (let [ls (landing/lines {:recipes 999, :solutes 999} 1)]
  (is (= 24 (count ls)))
  (is (every? #(<= (count %) 79) ls))))

(deftest the-landing
 (support/with-data-folder
  [root (support/temp-root)]
  (testing "nothing saved yet"
   (let [text (snap)]
    (is (has? text "custom solutes and recipes"))
    (is (has? text "> recipes (0)"))
    (is (has? text "solutes (0)"))
    (is (has? text "recipes.edn: none yet  custom-solutes.edn: none yet"))))
  (spit (store/recipes-file root) fixture-recipes)
  (spit (custom-store/custom-file root) fixture-customs)
  (let [n (count (custom-store/read-solutes root))]
   (testing "the counts of the files"
    (let [text (snap)]
     (is (has? text "> recipes (4)"))
     (is (has? text (str "solutes (" n ")")))
     (is (has? text
       (str "recipes.edn: 4 recipes  custom-solutes.edn: " n " solutes"))))
    (testing "the cursor moves, without wrapping"
     (is (has? (snap down) (str "> solutes (" n ")")))
     (is (has? (snap down down down) (str "> solutes (" n ")")))
     (is (has? (snap down up up) "> recipes (4)")))))
  (testing "keys that leave"
   (is (= :back (first (run!-keys :ctrl-x))))
   (is (= :quit (first (run!-keys esc))))
   (is (= :quit (first (run!-keys eof)))))
  (testing "recipes opens the recipes table, ctrl-x comes back to the landing"
   (let [text (snap enter)]
    (is (has? text "SEC buffer"))
    (is (has? text "recipes [  1/4  ]")))
   (let [[r text] (run!-keys enter :ctrl-x :ctrl-x)]
    (is (= :back r))
    (is (has? text "custom solutes and recipes")))
   (is (has? (snap enter :ctrl-x) "your library"))
   (is (= :quit (first (run!-keys enter esc)))))
  (testing "solutes opens the custom solutes table, ctrl-x comes back"
   (let [text (snap down enter)]
    (is (has? text "formula"))
    (is (not (has? text "recipes ["))))
   (is (has? (snap down enter :ctrl-x) "your library"))
   (is (= :back (first (run!-keys down enter :ctrl-x :ctrl-x))))
   (is (= :quit (first (run!-keys down enter esc)))))
  (testing "what the recipes table saved shows in the count"
   (let [text (snap enter down :ctrl-r :ctrl-w :ctrl-x)]
    (is (has? text "> recipes (3)"))))))

(deftest files-that-cannot-be-used
 (support/with-data-folder
  [root (support/temp-root)]
  (spit (store/recipes-file root) "{:recipes [1]}")
  (spit (custom-store/custom-file root) "[")
  (let [text (snap)]
   (is (has? text "recipes.edn unusable!  custom-solutes.edn unusable!"))
   (is (has? text "recipes (?)"))
   (is (has? text "solutes (?)")))
  (testing "each still opens and says so again; nothing is written"
   (is (has? (snap enter) "recipes.edn unusable!"))
   (is (has? (snap down enter) "custom-solutes.e…"))
   (is (= "{:recipes [1]}" (slurp (store/recipes-file root))))
   (is (= "[" (slurp (custom-store/custom-file root)))))))

(deftest ctrl-e-opens-the-landing-from-the-global-settings-menu-only
 (support/with-data-folder
  [_root (support/temp-root)]
  (testing
   "global: ctrl-e shows the landing, ctrl-x comes back to the settings menu page"
   (let [vs (support/virtual-screen)]
    (support/feed! vs :ctrl-e eof)
    (is (= :quit (settings-menu/show! (:screen vs) background)))
    (is (has? (support/screen-text vs) "custom solutes and recipes")))
   (let [vs (support/virtual-screen)]
    (support/feed! vs :ctrl-e :ctrl-x :ctrl-x)
    (is (= :back (settings-menu/show! (:screen vs) background)))
    (is (has? (support/screen-text vs) "solutes: ctrl+e"))))
  (testing "escape in the landing quits the program"
   (let [vs (support/virtual-screen)]
    (support/feed! vs :ctrl-e esc)
    (is (= :quit (settings-menu/show! (:screen vs) background)))))
  (testing "a project's settings menu has no such key"
   (let [vs (support/virtual-screen)]
    (support/feed! vs :ctrl-e :ctrl-x)
    (is (= :back
      (settings-menu/show! (:screen vs)
       background
       (settings-menu/project-opts (support/temp-root)))))
    (is (not (has? (support/screen-text vs) "your library")))))))
