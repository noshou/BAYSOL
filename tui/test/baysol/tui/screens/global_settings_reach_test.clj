;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The whole way from the GLOBAL settings menu to editing a saved recipe's solutes and the
;; custom solutes, on a virtual terminal: settings menu, ctrl-e (the library), the recipes
;; table, a recipe, its solutes (the same table and add flow as a project's buffer), ^w, and
;; the way back out. Recipes are global files; nothing here touches a project.

(ns baysol.tui.screens.global-settings-reach-test
 (:require [baysol.tui.custom-store :as custom-store]
  [baysol.tui.recipe-store :as store]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.support :as support :refer [background enter down eof]]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private bs (vec (repeat 45 KeyType/Backspace)))

(def ^:private fixture-recipes
 (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))

(def ^:private fixture-customs
 (slurp (io/file ".." "test" "fixtures" "buffer" "custom-solutes.edn")))

(defn ^:private setup!
 "Puts the fixture recipes and custom solutes in the data folder `root`."
 [root]
 (io/make-parents (store/recipes-file root))
 (spit (store/recipes-file root) fixture-recipes)
 (spit (custom-store/custom-file root) fixture-customs))

(defn ^:private run!-keys
 "Runs the GLOBAL settings menu with `inputs` fed; returns [result screen-text]."
 [& inputs]
 (apply support/run-keys! #(settings-menu/show! % background) inputs))

(deftest a-recipes-solutes-are-edited-from-the-global-settings
 (support/with-data-folder
  [root (support/temp-root)]
  (setup! root)
  (let [before (store/read-recipes root)
    customs-before (slurp (custom-store/custom-file root))
    ;; ctrl-e: the library; enter: `recipes`; enter: the first recipe, enter: keep its
    ;; name; its solutes open: enter edits row 1 (name, kept; mM, retyped; ±, kept);
    ;; ^w saves the recipe at once; then back out four times
    [r _] (run!-keys :ctrl-e
     enter
     enter
     enter
     enter
     enter
     bs
     "150"
     enter
     enter
     :ctrl-w
     :ctrl-x :ctrl-x
     :ctrl-x :ctrl-x)
    after (store/read-recipes root)]
   (testing "the way in and out ends on the settings menu's own back"
    (is (= :back r)))
   (testing
    "the recipe's first solute has the new concentration, nothing else changed"
    (is (= 150.0 (get-in after [0 :solutes 0 :mM])))
    (is (= (assoc-in (vec before) [0 :solutes 0 :mM] 150.0) after)))
   (testing "no custom solute was touched"
    (is (= customs-before (slurp (custom-store/custom-file root))))))))

(deftest the-custom-solutes-open-from-the-same-library
 (support/with-data-folder
  [root (support/temp-root)]
  (setup! root)
  (let [[r text] (run!-keys :ctrl-e down enter eof)]
   (is (= :quit r))
   (is (str/includes? text "custom [")
    "the custom solutes table is on screen")
   (is (str/includes? text "N-acetylcysteine")
    "with the first custom solute of the file"))))

(deftest the-recipes-table-lists-the-recipes-of-the-global-file
 (support/with-data-folder
  [root (support/temp-root)]
  (setup! root)
  (let [[_ text] (run!-keys :ctrl-e enter eof)]
   (is (str/includes? text "recipes ["))
   (is (str/includes? text "SEC buffer"))
   (is (str/includes? text "Everything")))))
