;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings store: the file made from the bundled defaults, the merge with the defaults
;; of a release, the save of one entry, and how a value reads in the value cell of a page.

(ns baysol.tui.settings-test
 (:require [baysol.tui.screens.sheets :as sheets]
  [baysol.tui.settings :as settings]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (java.nio.file Files)
  (java.nio.file.attribute FileAttribute)))

(defn ^:private temp-root
 "A new empty folder (a File) for a test."
 []
 (.toFile (Files/createTempDirectory "baysol-settings"
   (make-array FileAttribute 0))))

(deftest the-file-is-a-copy-of-the-defaults
 (let [root (temp-root)
   loaded (settings/load! root)]
  (testing "the first load makes settings.edn, a copy of the bundled defaults"
   (is (= (slurp (io/resource "default_settings.edn") :encoding "UTF-8")
     (slurp (settings/settings-file root) :encoding "UTF-8"))))
  (testing "nothing is saved yet, so every value is its default"
   (is (every? #(= (:default %) (settings/value %))
     (mapcat vals (vals loaded)))))))

(deftest a-save-changes-one-entry
 (let [root (temp-root)
   _ (settings/load! root)
   saved (settings/save! root :sampler "N_ADAPT" 450)
   reloaded (settings/load! root)]
  (is (= 450 (settings/value (get-in saved [:sampler "N_ADAPT"]))))
  (testing "a later load has the saved value and every other setting at its default"
   (is (= 450 (settings/value (get-in reloaded [:sampler "N_ADAPT"]))))
   (is (= 700 (settings/value (get-in reloaded [:sampler "N_DRAWS"])))))
  (testing
   "the file stays a readable map in page order, and no temporary file is left"
   (let [text (slurp (settings/settings-file root) :encoding "UTF-8")]
    (is (map? (edn/read-string text)))
    (is (< (str/index-of text "\"N_ADAPT\"") (str/index-of text "\"N_DRAWS\""))))
   (is (not (.exists (io/file root "settings.edn.tmp")))))
  (testing "a value saved again replaces the earlier one"
   (is (= 500
     (settings/value (get-in (settings/save! root :sampler "N_ADAPT" 500)
       [:sampler "N_ADAPT"])))))))

(deftest the-file-is-merged-with-the-defaults-of-the-release
 (let [defaults {:sampler {"A" {:page 1, :default 1, :type :int, :limits {}},
     "B" {:page 2, :default 2, :type :int, :limits {}}}}
   stored {:sampler {"A" {:page 9, :default 99, :value 5},
     "GONE" {:page 3, :default 3, :value 3}}}
   merged (settings/merge-defaults defaults stored)]
  (testing "a saved value is kept, the description comes from the defaults"
   (is (= {:page 1, :default 1, :type :int, :limits {}, :value 5}
     (get-in merged [:sampler "A"]))))
  (testing
   "an entry the file lacks is added at its default, an unknown one is dropped"
   (is (= {:page 2, :default 2, :type :int, :limits {}}
     (get-in merged [:sampler "B"])))
   (is (nil? (get-in merged [:sampler "GONE"]))))
  (testing "a missing or unreadable file leaves the defaults"
   (is (= (settings/merge-defaults defaults nil)
     (settings/merge-defaults defaults {:sampler {}}))))))

(deftest a-value-reads-in-the-value-cell
 (is (= "300" (settings/format-value 300)))
 (is (= "0.55" (settings/format-value 0.55)))
 (is (= "true" (settings/format-value true)))
 (is (= "crimson" (settings/format-value :crimson)))
 (is (= "(4.0, 10.0, 20.0)" (settings/format-value [4.0 10.0 20.0])))
 (is (= "(gray40, 0.6)" (settings/format-value [:gray40 0.6])))
 (is (= "(70, 18)" (settings/format-value {:width 70, :height 18})))
 (testing "a text that is too long is cut short with an ellipsis, at 17 characters"
  (is (= "TeX Gyre Pagella…" (settings/format-value "TeX Gyre Pagella Math")))
  (is (= 17 (count (settings/format-value "TeX Gyre Pagella Math"))))))

(deftest the-values-are-written-into-the-value-cells
 (let [lines (:pages (sheets/load-sheet "sampler-settings"))
   values (settings/screen-values (settings/load! (temp-root)) :sampler)
   page (sheets/with-values (first lines) values)
   row #(first (filter (fn [l] (str/includes? l %)) page))]
  (testing "a page keeps its shape"
   (is (= (count (first lines)) (count page)))
   (is (every? #(= 79 (count %)) (butlast page))))
  (testing "the first row of each setting shows its value after a space"
   (is (str/includes? (row "N_ADAPT") "╬ 300 "))
   (is (str/includes? (row "N_DRAWS") "╬ 700 ")))
  (testing "a row that is no setting's first row is left as it is"
   (is (= (nth (first lines) 3) (nth page 3))))
  (testing "a setting without a value leaves its cell blank"
   (is (= (first lines) (sheets/with-values (first lines) {}))))))
