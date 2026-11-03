;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The custom solutes of the user: `custom-solutes.edn` in the BAYSOL data folder, next to
;; `settings.edn` (so it belongs to the user, not to a project, and a reset of the settings
;; never touches it). An EDN map whose `:solutes` is a vector of the entries, one map each:
;;
;;   {:kind :nonbiological, :name "N-acetylcysteine ethyl ester", :formula "C7H13NO3S",
;;    :z 100, :pmv 118.4, :sigma 4.0}
;;   {:kind :polymer, :name "chain-2",
;;    :units [{:label "A", :formula "C2H4O", :z 24, :slope 36.73, :sigma nil}
;;            {:label "B", :formula "C3H6O", :z 32, :slope 53.1, :sigma 0.1}],
;;    :z-ends 10, :pmv-ends 19.24, :sigma-ends nil}
;;
;; A polymer is a generic additive chain of 1 to 4 kinds of repeat unit, each with a label
;; the user chose, its formula, electrons per unit, PMV per unit (`:slope`) and absolute
;; uncertainty per unit; the end groups (`:z-ends`, `:pmv-ends`, `:sigma-ends`) have no
;; default. PMV of a chain with n_i units of each kind is `pmv-ends + sum(slope_i n_i)`. PMV
;; is in cm³ mol⁻¹ as typed; a `:sigma` is nil when it was left blank (the defaults apply
;; then, see `baysol.tui.custom`). The schema is frozen in
;; `test/fixtures/buffer/custom-solutes.edn`.
;;
;; Other keys of the map are kept as they are on write. A missing, empty or comment-only
;; file is no entries; a file that is not an EDN map, whose `:solutes` is not a vector of
;; maps, that has more than 999 entries, or has a polymer without 1 to 4 units (an entry
;; of the single-unit shape older than this one has none) is unusable, and is never
;; written over.

(ns baysol.tui.custom-store
 (:require [baysol.tui.custom :as custom]
  [baysol.tui.edn-store :as store]
  [baysol.tui.limits :as limits]
  [clojure.java.io :as io]))

(defn custom-file
 "The `custom-solutes.edn` (a File) of the BAYSOL folder `root`."
 [root]
 (io/file root "custom-solutes.edn"))

(defn ^:private unusable
 [message]
 (ex-info message {:type ::unusable}))

(defn ^:private usable-entry?
 "Whether `e` is a map and, if it is a polymer, has a vector of 1 to `custom/max-units`
 unit maps."
 [e]
 (and (map? e)
  (or (not= (:kind e) :polymer)
   (let [u (:units e)]
    (and (vector? u) (<= 1 (count u) custom/max-units) (every? map? u))))))

(defn ^:private read-map
 "The map in the file of `root`: `{}` for no file or no content. Throws an exception (`:type
 ::unusable`) if the file is not one EDN map of the kind described above."
 [root]
 (store/read-map (custom-file root)
  {:type ::unusable,
   :name "custom-solutes.edn",
   :expected "a map of up to 999 solutes",
   :valid? (fn [value]
    (let [s (:solutes value [])]
     (and (vector? s)
      (every? usable-entry? s)
      (<= (count s) limits/max-rows))))}))

(defn read-solutes
 "The custom solutes of the folder `root`, a vector of maps (empty for none). Throws an
 exception (`:type ::unusable`) if the file cannot be used."
 [root]
 (vec (:solutes (read-map root) [])))

(defn write-solutes!
 "Writes `solutes` (a vector of entries, at most 999) as the custom solutes of the folder
 `root`, the other keys of the file kept, through a temporary file that replaces it in one
 step. The file is made if there is none; one that cannot be used is not touched (the
 exception of `read-solutes` is thrown). Returns the file."
 [root solutes]
 (when (> (count solutes) limits/max-rows) (throw (unusable "too many solutes")))
 (when-not (every? usable-entry? solutes)
  (throw (unusable "a polymer needs 1-4 units")))
 (let [others (dissoc (read-map root) :solutes)
   file (custom-file root)
   text (store/map-text :solutes (map pr-str solutes) others)]
  (store/write-atomic! file text)))
