;; SPDX-License-Identifier: LGPL-3.0-or-later

;; resources/default_settings.edn is harvested from the Params.jl files by `bb precommit`
;; (`dev/scripts/harvest_defaults.jl`). These tests check it against the pages of the settings
;; sheets, so a page added, renamed or reordered without a harvest is noticed here: every
;; page has an entry on its own page number, and every entry has a page.

(ns baysol.tui.screens.default-settings-test
 (:require [baysol.tui.screens.sheets :as sheets]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(def ^:private defaults
 (edn/read-string (slurp (io/resource "default_settings.edn") :encoding "UTF-8")))

(defn ^:private cursor-name
 "The name of the setting on the first row of `page` that has the cursor `>`."
 [lines]
 (->> lines
  (some #(when (str/starts-with? % " > ╠") %))
  (re-find #"╠ ([^╬]*)╬")
  second
  str/trim))

(deftest every-page-has-its-default
 (doseq [screen [:sampler :model :output :plots]
   :let [sheet (sheets/load-sheet (str (name screen) "-settings"))
    entries (get defaults screen)]]
  (testing (name screen)
   (is (= (count (:pages sheet)) (count entries)) "one entry for every page")
   (doseq [[i lines] (map-indexed vector (:pages sheet))
     :let [setting (cursor-name lines)]]
    (is (= (inc i) (get-in entries [setting :page]))
     (str setting " is on page " (inc i)))))))

(deftest every-entry-is-complete
 (doseq [[screen entries] defaults
   [setting {:keys [default limits], kind :type}] entries]
  (testing (str (name screen) " " setting)
   (is (contains? #{:int :float :bool :colour :font :set :tuple} kind))
   (is (some? default))
   (is (map? limits))
   (is (every? #{:above :below :at-least :at-most} (keys limits))))))
