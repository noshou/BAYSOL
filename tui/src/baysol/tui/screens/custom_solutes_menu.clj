;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The custom solutes of the user: a table (resources/custom-solutes/pages/page.txt, drawn
;; by `baysol.tui.screens.table`) of one row for each entry of `custom-solutes.edn` in the
;; BAYSOL folder, laid out and run like the solutes of a buffer (`solutes-menu`). Columns:
;; name | formula | Z | PMV @ 25 °C | ± (cm³/mol). Nothing is written until `^w`; a row that
;; is new or edited shows `*`, one marked to be removed shows `-`.
;;
;;   up, down   the previous and the next row (no wrapping)
;;   enter      edit the row under the cursor in its form page (below)
;;   ^n         add a non-biological solute: opens its form page (`custom-nonbio-form`)
;;   ^p         add a polymer: opens its form page (`custom-polymer-form`); neither past 999
;;              rows
;;   ^r         mark the row to be removed at the next save (`-`); a row that was never
;;              saved goes at once
;;   ^u         undo: the removal mark of the row, else its draft
;;   ^w         save every change (a row that is not complete is told, nothing is saved)
;;   ^x         back to where this was opened from     escape   quit the program
;; Leaving without `^w` drops what was not saved.
;;
;; An entry is made and changed in a FORM PAGE (`screens/form` draws it from its art): ^n
;; and ^p open an empty one, Enter on a row the same page of that row's kind with its
;; values. A form accepted with ^w gives the entry back to the table as a draft (`*`; for a
;; new entry a
;; new row at the end), a form left with Esc changes nothing (no row is added). The form
;; pages check the entry as the table does (`custom/entry-problem`: name needed, in use,
;; built-in, ...), so a draft that comes back is complete; `^w` here checks all the rows
;; again and writes the file. Units B to D of a polymer are edited in its form page.
;;
;; A polymer shows, by the labels of its units: in the formula cell the units `A:C2H4O
;; B:C3H6O`, in the Z cell `24A+32B+10`, in the PMV cell `36.9A+53.1B+9` (slope of each
;; unit, then the end groups; a first minus is kept, `-5.2A+3`), in the ± cell the ± of
;; the first unit or `(2%)` when it is blank, and `…` when the units' ± differ (it is a
;; summary; the form page shows them all). The ± of the ends is not shown. A blank ± of a
;; non-biological solute shows the setting `PMV_FALLBACK_UNCERT` in parentheses; nothing
;; is computed here, the defaults apply at the run.

(ns baysol.tui.screens.custom-solutes-menu
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.custom :as custom]
  [baysol.tui.custom-store :as store]
  [baysol.tui.draft :as draft]
  [baysol.tui.screens.custom-nonbio-form :as nonbio-form]
  [baysol.tui.screens.custom-polymer-form :as polymer-form]
  [baysol.tui.screens.loop :as lp]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.table :as table]
  [baysol.tui.settings :as settings]
  [baysol.tui.solute-index :as solute-index]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "custom-solutes")

(def art
 "The art of the table, parsed."
 (table/parse-art (pgld/load-ascii "page" screen-name)))

(def ^:private empty-hint "none: ^n ^p add")

(def ^:private fallback-default
 "The `PMV_FALLBACK_UNCERT` of the bundled defaults, for when the settings cannot be read."
 3.044643)

(defn fallback-uncertainty
 "The setting `PMV_FALLBACK_UNCERT` of the global settings in the BAYSOL folder `root`
 (the default if they cannot be read)."
 [root]
 (try (let [entry (get-in (settings/load! root) [:model "PMV_FALLBACK_UNCERT"])
    v (settings/value entry)]
   (if (number? v) (double v) fallback-default))
  (catch Exception _ fallback-default)))

(defn ^:private signed
 "`n` as `+n` or `-n`, the number as typed."
 [x]
 (str (if (neg? x) "-" "+") (custom/format-number (abs x))))

(defn ^:private sum-text
 "The terms `[number suffix]` of a sum as text, `36.9A+53.1B+9`: a term with no number is
 left out, the first keeps its minus, the others carry their sign."
 [terms]
 (let [shown (filter (comp some? first) terms)]
  (str/join (map-indexed (fn [i [x suffix]]
     (str (if (zero? i) (custom/format-number x) (signed x))
      suffix))
    shown))))

(defn ^:private z-text
 [e]
 (if (= (:kind e) :polymer)
  (sum-text (concat (map (fn [u] [(:z u) (:label u)]) (:units e))
    [[(:z-ends e) ""]]))
  (if (:z e) (str (:z e)) "")))

(defn ^:private pmv-text
 [e]
 (if (= (:kind e) :polymer)
  (sum-text (concat (map (fn [u] [(:slope u) (:label u)]) (:units e))
    [[(:pmv-ends e) ""]]))
  (custom/format-number (:pmv e))))

(defn ^:private units-text
 "The units of a polymer as `A:C2H4O B:C3H6O`; a unit with no formula is left out."
 [e]
 (str/join " "
  (for [u (:units e)
    :when (not (str/blank? (:formula u)))]
   (str (:label u) ":" (:formula u)))))

(defn ^:private sigma-text
 [e fallback]
 (if (= (:kind e) :polymer)
  (let [sigmas (distinct (map :sigma (:units e)))]
   (cond (next sigmas) "…"
    (first sigmas) (custom/format-number (first sigmas))
    :else "(2%)"))
  (if (:sigma e)
   (custom/format-number (:sigma e))
   (str "(" (custom/format-rounded fallback) ")"))))

(defn view-rows
 "The rows of the table for the state `s` of the entries, as `table/frame` takes them.
 `fallback` is the number a blank ± of a non-biological solute stands for."
 [s fallback]
 (mapv (fn [row]
   (let [e (custom/value row)
     polymer? (= (:kind e) :polymer)]
    {:cells [(:name e) (if polymer? (units-text e) (:formula e)) (z-text e)
      (pmv-text e)
      (sigma-text e fallback)],
     :aligns [:left :left :right :right :right],
     :mark (custom/mark row)}))
  (:rows s)))

(defn ^:private save-step
 [st root]
 (table/save-rows st
  (custom/problems (:s st) solute-index/builtin-name?)
  #(store/write-solutes! root %)))

(defn ^:private nav-step
 [st input root]
 (let [{:keys [s cursor]} st
   n (count (:rows s))]
  (cond
   (and (= input KeyType/Enter) (pos? n) (not (get-in s [:rows cursor :removed?])))
   (assoc st :form {:row cursor})

   (and (= input :ctrl-n) (draft/room? s)) (assoc st :form {:kind :nonbiological})
   (and (= input :ctrl-p) (draft/room? s)) (assoc st :form {:kind :polymer})

   (= input :ctrl-w) (save-step st root)

   :else (or (table/step st input) st))))

(def ^:private unusable-note "custom-solutes.edn unusable!")

(defn ^:private run-form
 "Runs the form page asked for by `request` (`{:row i}` for the row under the cursor, or
 `{:kind k}` for a new entry) on `screen` and returns the state `st` after it: the entry
 accepted is a draft of its row (a new row at the end, the cursor on it), a form left with
 Esc changes nothing. Returns :quit when the terminal went away."
 [screen background st {:keys [row kind]} fallback]
 (let [rows (get-in st [:s :rows])
   entry
   (if row
    (custom/value (nth rows row))
    (if (= kind :polymer) custom/blank-polymer custom/blank-nonbiological))
   others (for [[i r] (map-indexed vector rows)
     :when (and (not= i row) (not (:removed? r)))]
    (:name (custom/value r)))
   opts
   {:fallback fallback, :others others, :builtin? solute-index/builtin-name?}
   show! (if (= (:kind entry) :polymer) polymer-form/show! nonbio-form/show!)
   result (show! screen background entry opts)]
  (cond (= result :quit) :quit
   ;; Esc or Ctrl-X in the form: back to this table with nothing changed
   (or (nil? result) (= result :back)) st
   row (assoc st :s (custom/set-entry (:s st) row result))
   :else (let [n (count rows)]
    (assoc st
     :s (-> (:s st)
      (custom/add-row (:kind result))
      (custom/set-entry n result))
     :cursor n)))))

(defn show!
 "Shows the custom solutes in the BAYSOL folder on `screen`, with the solid colour
 `background`, and handles the keys until one leaves it. Returns :back or :quit. A file
 that cannot be used is told and left alone: the table is empty and nothing can be
 edited."
 [^TerminalScreen screen ^TextColor background]
 (let [root @app/app-dir
   loaded (try (store/read-solutes root) (catch Exception _ ::unusable))
   unusable? (= loaded ::unusable)
   fallback (fallback-uncertainty root)]
  (lp/run-table!
   screen
   background
   {:init {:s (custom/initial (if unusable? [] loaded)),
     :cursor 0,
     :offset 0,
     :note (when unusable? unusable-note)},
    :frame (fn [st]
     (table/frame art
      (view-rows (:s st) fallback)
      (:cursor st)
      (:offset st)
      {:note (:note st),
       :empty-hint (when-not unusable? empty-hint),
       :hide-legends (when unusable?
        ["edit" "add nonbio" "add polymer" "save"
         "undo" "rmv"])})),
    :handle (fn [st input]
     (if unusable?
      (assoc st :note unusable-note)
      (let [st (nav-step st input root)]
       (if-let [request (:form st)]
        (run-form screen background (dissoc st :form) request fallback)
        st))))})))
