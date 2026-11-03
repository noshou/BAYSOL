;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The models part of the project menu, drawn over the page of `models` (the items under it,
;; buffer and settings, are blanked while it is open):
;;
;;   the prompt   type the full absolute path of a `.cif` or `.pdb` file; the folder's
;;                names that fit what is typed are hinted below, up and down move among them
;;                and Tab takes the highlighted one. Enter copies the file into the
;;                project's `models/` folder (the original stays where it is) and the prompt
;;                stays for the next one. With nothing typed yet (an absolute path starts
;;                with a slash, so these keys cannot be part of one):
;;                  o   the desktop's file picker (`baysol.tui.file-picker`), to choose one
;;                      or several `.cif` / `.pdb` files; each is copied like a typed path
;;                  m   (only when the project has a model) the list of its models
;;   the list     the models of the project in a dropdown: type to narrow, up and down move.
;;                ^r (or Delete) asks first, with a warning that it is destructive
;;                and a backup should exist; Enter then deletes the file from
;;                `models/`, Escape keeps it. When the last model is deleted the list
;;                closes and the prompt is as it is for a project that never had one.
;;   escape       leaves the prompt (the list, the warning: one step back)

(ns baysol.tui.screens.models-menu
 (:require [baysol.tui.text :as txt]
  [baysol.tui.core :as core]
  [baysol.tui.file-picker :as file-picker]
  [baysol.tui.models :as models]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.state :as state]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

;; The rows under `models`: the prompt (or the `find:` text), then what goes under it. The
;; text is in the left column, which ends before the art of the right one (index 49).
(def ^:private prompt-row 16)
(def ^:private col 6)
(def ^:private width 42)
(def ^:private right-column 49)
(def ^:private hint-top 17)
(def ^:private hint-rows 5) ; four names and a status row, rows 17 to 21
(def ^:private note-row 22)
(def ^:private keys-row 23)
(def ^:private list-rows 7) ; six names and a status row, rows 17 to 23

;; The most characters a path may be typed with.
(def ^:private max-typed 300)

(defn ^:private blank-below
 "`lines` with everything left of the right column from the row under the prompt down made
 blank: the items under `models` (buffer, settings) do not show through."
 [lines]
 (vec (map-indexed
   (fn [i line]
    (if (> i prompt-row) (pgld/put-text line 0 right-column "") line))
   lines)))

(defn typed-path
 "What the prompt shows of the path typed: `path: ` and the end of it, with a cursor."
 [buffer]
 (let [room (- width (count "path: ") 1)]
  (str "path: "
   (if (> (txt/display-width buffer) room)
    (str "…" (txt/take-last-width buffer (dec room)))
    buffer)
   "_")))

(defn ^:private put-row
 "`lines` with `text` written on `row` in the columns of the menu."
 [lines row text]
 (update lines row pgld/put-text col width text))

(defn ^:private key-hints
 "The reminder of the keys on the bottom row of the prompt."
 [buffer n-models]
 (if (str/blank? buffer)
  (str "o: pick files  "
   (when (pos? n-models) (str "m: models (" n-models ")  "))
   "esc: exit")
  "tab: complete  esc: exit"))

(defn prompt-lines
 "The lines of `page` with the prompt of the state `st`, `{:buffer :index :note
 :n-models}`: the path typed, its hints (the highlighted one is `:index`), the note
 (what happened to the last file, or what is wrong) and the keys."
 [page st]
 (let [{:keys [buffer index note n-models]} st
   typed? (not (str/blank? buffer))
   hs (models/hints buffer)]
  (cond-> (-> (blank-below (:asset page))
    (put-row prompt-row (typed-path buffer))
    (put-row keys-row (key-hints buffer n-models)))
   note (put-row note-row note)
   typed? (picker/overlay
    {:matches hs, :index index, :error nil}
    {:row hint-top, :col col, :width width, :rows hint-rows}))))

(defn list-lines
 "The lines of `page` with the dropdown of the models, the state `st` of a picker: the
 `find:` text and the key that deletes on the row of the prompt, the models under it."
 [page st]
 (->
  (blank-below (:asset page))
  (update prompt-row pgld/put-text col 30 (str "find: " (picker/typed-text st 22)))
  (update prompt-row pgld/put-text (+ col 29) 14 "^r: remove")
  (picker/overlay st {:row hint-top, :col col, :width width, :rows list-rows})))

(defn confirm-lines
 "The lines of `page` with the warning before the model `model-name` is deleted."
 [page model-name]
 (-> (blank-below (:asset page))
  (put-row prompt-row (str "remove " model-name "?"))
  (put-row hint-top "WARNING: this is destructive!")
  (put-row (+ hint-top 1) "The file is removed from this project's")
  (put-row (+ hint-top 2) "models/ folder and cannot be recovered.")
  (put-row (+ hint-top 3) "Make sure a backup exists.")
  (put-row keys-row "enter: delete  esc: keep it")))

(defn ^:private confirm-delete!
 "Asks whether to delete the model `model-name`, with the warning, until Enter (true) or
 Escape (false); :quit if the terminal went away, :back for Ctrl-X."
 [screen background page model-name]
 (state/draw-lines! screen background (confirm-lines page model-name))
 (state/confirm! screen))

(defn ^:private list-models!
 "The dropdown of the models of the project `project-dir`, until Escape (:done) or until
 the last model is deleted (:done); :quit if the terminal went away, :back for Ctrl-X
 (anywhere in it, the warning included)."
 [screen background page project-dir]
 (loop [st (picker/initial (models/list-models project-dir) nil)]
  (state/draw-lines! screen background (list-lines page st))
  (let [input (state/read-raw screen)]
   (cond
    (= input KeyType/EOF) :quit
    (state/back-key? input) :back

    (or (= input KeyType/Delete) (= input :ctrl-r))
    (if (empty? (:matches st))
     (recur st)
     (let [model-name (nth (:matches st) (:index st))
       sure (confirm-delete! screen background page model-name)]
      (cond (#{:quit :back} sure) sure
       (true? sure)
       (do (models/delete-model! project-dir model-name)
        (let [names (models/list-models project-dir)]
         (if (empty? names) :done (recur (picker/initial names nil)))))
       :else (recur st))))

    :else (let [result (picker/step st input)]
     (cond (= result :cancel) :done
      (:chosen result) (recur st) ; nothing is done with a model that is picked
      :else (recur (:state result))))))))

(defn pick-note
 "The note to tell about `result`, what `models/add-models!` returned: how many were
 copied and, if any were skipped, how many and why (the first reason)."
 [{:keys [copied skipped]}]
 (let [n (count copied)
   copied-text
   (if (= 1 n) (str "copied " (first copied)) (str "copied " n " files"))]
  (cond (and (empty? copied) (empty? skipped)) "nothing was picked"
   (empty? skipped) copied-text
   :else (str (if (seq copied) (str copied-text ", ") "")
    "skipped " (count skipped)
    ": " (second (first skipped))))))

(defn ^:private pick-files!
 "Opens the desktop's file picker, in the user's home folder, to choose files (several
 allowed), copies them into the models of `project-dir` and returns the note to tell. The
 keys typed while the picker window was open are thrown away."
 [screen project-dir]
 (let [system (core/read-system)
   {:keys [files problem]} (file-picker/pick! (str (or (:home system)
      (:cwd system))))]
  (state/discard-pending! screen)
  (or problem (pick-note (models/add-models! project-dir files)))))

(defn show!
 "Runs the models part of the project menu of the project `project-dir` on `screen`, drawn
 over `page` (the page of `models`, a map with its `:asset`), with the solid colour
 `background`, until Escape: returns :done, :back for Ctrl-X (from the prompt, the list or
 the warning) or :quit if the terminal went away."
 [^TerminalScreen screen ^TextColor background page project-dir]
 (loop [st {:buffer "", :index 0, :note nil}]
  (let [n-models (count (models/list-models project-dir))
    {:keys [buffer index]} st
    n-hints (count (models/hints buffer))
    index (if (pos? n-hints) (min index (dec n-hints)) 0)
    st (assoc st :index index :n-models n-models)]
   (state/draw-lines! screen background (prompt-lines page st))
   (let [input (state/read-raw screen)
     empty-buffer? (str/blank? buffer)]
    (cond
     (= input KeyType/EOF) :quit
     (= input KeyType/Escape) :done
     (state/back-key? input) :back

     (and empty-buffer? (contains? #{\o \O} input))
     (recur (assoc st :note (pick-files! screen project-dir)))

     (and empty-buffer? (contains? #{\m \M} input) (pos? n-models))
     (let [r (list-models! screen background page project-dir)]
      (if (#{:quit :back} r) r (recur (assoc st :note nil))))

     (= input KeyType/Enter)
     (let [path (str/trim buffer) ; a typed or pasted path may end in blanks or a newline
       problem (models/path-problem path (models/list-models project-dir))
       copied (when-not problem
        (try (models/add-model! project-dir path)
         :ok
         (catch Exception _ :failed)))]
      (cond problem (recur (assoc st :note problem))
       (= copied :ok) (recur {:buffer "",
         :index 0,
         :note (str "copied "
          (.getName (java.io.File. ^String
            path)))})
       :else (recur (assoc st :note "could not copy the file!"))))

     (and (#{KeyType/ArrowDown KeyType/ArrowUp} input) (pos? n-hints))
     (recur (assoc st
       :note nil
       :index
       (txt/cycle-index index n-hints (= input KeyType/ArrowDown))))

     (and (= input KeyType/Tab) (pos? n-hints))
     (recur (assoc st
       :buffer (models/complete buffer
        (nth (models/hints buffer) index))
       :index 0
       :note nil))

     (txt/edits? input buffer max-typed)
     (recur
      (assoc st :buffer (txt/typed buffer input max-typed) :index 0 :note nil))

     (txt/at-cap? input buffer max-typed)
     (recur (assoc st :note (txt/too-long "path" max-typed)))

     :else (recur st))))))
