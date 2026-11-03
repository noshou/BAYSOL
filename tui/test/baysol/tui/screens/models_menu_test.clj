;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The models part of the project menu, run for real on a virtual screen: adding a model by
;; path, the lists of hints, the models list and the warning before a delete.

(ns baysol.tui.screens.models-menu-test
 (:require [baysol.tui.models :as models]
  [baysol.tui.projects :as projects]
  [baysol.tui.screens.models-menu :as models-menu]
  [baysol.tui.screens.project-menu :as project-menu]
  [baysol.tui.support :as support :refer [background]]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private page (get project-menu/pages :page1))

(defn ^:private run!-menu
 "Runs the models part on a new virtual screen `vs` for `dir`, in a future."
 [vs dir]
 (future (models-menu/show! (:screen vs) background page dir)))

(deftest the-lines
 (testing "the prompt blanks buffer and settings under models, and keeps models"
  (let [lines (models-menu/prompt-lines page {:buffer "", :index 0, :n-models 0})]
   (is (some #(str/includes? % "path: _") lines))
   (is (some #(str/includes? % "o: pick files") lines))
   (is (not-any? #(str/includes? % "m: models") lines) "no model: no list option")
   (is (= (subs (nth (:asset page) 14) 0 20) (subs (nth lines 14) 0 20))
    "models stays")
   (is (every? #(str/blank? (subs (str % (apply str (repeat 49 \space))) 0 49))
     (drop 17 (take 23 lines)))
    "the left column under the prompt is blank, but for the keys")
   (is (some #(str/includes? % "m: models (2)")
     (models-menu/prompt-lines page {:buffer "", :index 0, :n-models 2})))))
 (testing "the warning says it is destructive and asks for a backup"
  (let [lines (models-menu/confirm-lines page "a.pdb")]
   (is (some #(str/includes? % "destructive") lines))
   (is (some #(str/includes? % "backup") lines))
   (is (some #(str/includes? % "remove a.pdb?") lines)))))

(deftest notes-about-picked-files
 (is (= "nothing was picked" (models-menu/pick-note {:copied [], :skipped []})))
 (is (= "copied a.pdb" (models-menu/pick-note {:copied ["a.pdb"], :skipped []})))
 (is (= "copied 2 files" (models-menu/pick-note {:copied ["a" "b"], :skipped []})))
 (is (= "copied 2 files, skipped 1: no such file"
   (models-menu/pick-note {:copied ["a" "b"],
     :skipped [["/x" "no such file"]]})))
 (is (= "skipped 1: only .cif and .pdb files"
   (models-menu/pick-note {:copied [],
     :skipped [["/x" "only .cif and .pdb files"]]}))))

(deftest adding-listing-deleting
 (support/with-data-folder
  [root (support/temp-root)]
  (let [dir (projects/create! root "demo")
    src (support/temp-root)
    pdb (io/file src "one.pdb")]
   (spit pdb "ATOM")
   (testing "a path is copied, and the prompt stays until escape"
    (let [vs (support/virtual-screen)]
     (support/feed! vs (.getAbsolutePath pdb) KeyType/Enter KeyType/Escape)
     (is (= :done (models-menu/show! (:screen vs) background page dir)))
     (is (= ["one.pdb"] (models/list-models dir)))
     (is (.isFile pdb) "the original stays")))
   (testing "a wrong path is told and nothing is copied"
    (let [vs (support/virtual-screen)
      f (run!-menu vs dir)]
     (support/feed! vs "/no/such/file.pdb" KeyType/Enter)
     (Thread/sleep 300)
     (is (str/includes? (support/screen-text vs) "no such file"))
     (support/feed! vs KeyType/Escape)
     (is (= :done (deref f 2000 :timeout)))
     (is (= ["one.pdb"] (models/list-models dir)))))
   (testing "m lists the models; delete warns; escape keeps it"
    (let [vs (support/virtual-screen)
      f (run!-menu vs dir)]
     (support/feed! vs \m KeyType/Delete)
     (Thread/sleep 300)
     (is (str/includes? (support/screen-text vs) "destructive"))
     (support/feed! vs KeyType/Escape)
     (Thread/sleep 200)
     (is (str/includes? (support/screen-text vs) "one.pdb"))
     (is (= ["one.pdb"] (models/list-models dir)))
     (support/feed! vs KeyType/Escape KeyType/Escape)
     (is (= :done (deref f 2000 :timeout)))))
   (testing "^r is a second key for delete, and the legend says so"
    (let [vs (support/virtual-screen)
      f (run!-menu vs dir)]
     (support/feed! vs \m)
     (Thread/sleep 300)
     (is (str/includes? (support/screen-text vs) "^r: remove"))
     (support/feed! vs :ctrl-r)
     (Thread/sleep 300)
     (is (str/includes? (support/screen-text vs) "destructive"))
     (support/feed! vs KeyType/Escape :ctrl-d)
     (Thread/sleep 200)
     (is (= ["one.pdb"] (models/list-models dir)) "^d does nothing")
     (support/feed! vs KeyType/Escape KeyType/Escape)
     (is (= :done (deref f 2000 :timeout)))))
   (testing "delete then enter removes it; with none left the list option is gone"
    (let [vs (support/virtual-screen)
      f (run!-menu vs dir)]
     (support/feed! vs \m KeyType/Delete KeyType/Enter)
     (Thread/sleep 300)
     (is (= [] (models/list-models dir)))
     (is (not (str/includes? (support/screen-text vs) "m: models")))
     (support/feed! vs KeyType/Escape)
     (is (= :done (deref f 2000 :timeout)))
     (is (.isDirectory (io/file dir "models"))
      "the folder stays, as if it were none")))
   (testing "^r then enter removes it"
    (models/add-model! dir (.getAbsolutePath pdb))
    (let [vs (support/virtual-screen)
      f (run!-menu vs dir)]
     (support/feed! vs \m :ctrl-r KeyType/Enter)
     (Thread/sleep 300)
     (is (= [] (models/list-models dir)))
     (support/feed! vs KeyType/Escape)
     (is (= :done (deref f 2000 :timeout))))))))
