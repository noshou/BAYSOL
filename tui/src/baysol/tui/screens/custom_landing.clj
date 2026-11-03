;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The landing page of the user's library (resources/custom-landing/pages/page.txt, drawn
;; by `baysol.tui.screens.landing`), opened by `ctrl+e` in the global settings menu. The
;; `your library` box has two options:
;;
;;   recipes (N)   the table of the saved recipes (`baysol.tui.screens.recipes-menu`)
;;   solutes (N)   the table of the custom solutes
;;                 (`baysol.tui.screens.custom-solutes-menu`)
;;
;; The `library` box says what the files hold (`recipes.edn: 3 recipes  custom-solutes.edn:
;; 12 solutes`); a file that cannot be used is told here (`unusable!`, with `?` for its
;; count) and still opens, where its table says so again and edits nothing.
;;
;;   up, down   the previous and the next option (no wrapping)
;;   enter      open it; `ctrl-x` in either table comes back to this landing
;;   ctrl-x     back to the settings menu page this was opened from     escape   quit
;;
;; Linux-tested only; macOS and Windows untested.

(ns baysol.tui.screens.custom-landing
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.custom-store :as custom-store]
  [baysol.tui.edn-store :as edn-store]
  [baysol.tui.recipe-store :as recipe-store]
  [baysol.tui.screens.custom-solutes-menu :as custom-solutes-menu]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.recipes-menu :as recipes-menu]
  [baysol.tui.screens.state :as state])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "custom-landing")

(def art
 "The art of the landing, parsed."
 (landing/parse-art (pgld/load-ascii "page" screen-name)))

(defn counts
 "How many recipes and custom solutes the BAYSOL folder `root` has: `{:recipes n
 :solutes m}`, `::unusable` for a file that cannot be used."
 [root]
 {:recipes (try (count (recipe-store/read-recipes root))
   (catch Exception _ ::unusable)),
  :solutes (try (count (custom-store/read-solutes root))
   (catch Exception _ ::unusable))})

(defn ^:private shown [n] (if (= n ::unusable) "?" n))

(defn options
 "The labels of the two options for `counts`."
 [{:keys [recipes solutes]}]
 [(str "recipes (" (shown recipes) ")") (str "solutes (" (shown solutes) ")")])

(defn status-text
 "What the `library` box says of `counts`."
 [{:keys [recipes solutes]}]
 (let [one (fn [file n word]
    (cond (= n ::unusable) (str file " unusable!")
     (zero? n) (str file ": none yet")
     :else (str file ": " n " " word (when (not= n 1) "s"))))]
  (str (one "recipes.edn" recipes "recipe")
   "  "
   (one "custom-solutes.edn" solutes "solute"))))

(defn lines
 "The lines of the landing for `cs` (see [[counts]]), the cursor on option `cursor` and
 `message` (or nil) under the status."
 ([cs cursor] (lines cs cursor nil))
 ([cs cursor message]
  (landing/frame art
   {:title "custom solutes and recipes",
    :options (options cs),
    :cursor cursor,
    :status [(status-text cs) (or message "")]})))

(defn ^:private option-file
 "The file of the option `cursor` (0 recipes, 1 solutes) in the BAYSOL folder `root`: its
 name and its File."
 [root cursor]
 (if (zero? cursor)
  ["recipes.edn" (recipe-store/recipes-file root)]
  ["custom-solutes.edn" (custom-store/custom-file root)]))

(defn ^:private reset-file!
 "Asks, over `base`, whether the file of the option `cursor` that cannot be used is to be
 reset to empty (kept as `<name>.corrupt`), and does it. Returns the message to show or
 `:quit`."
 [screen background root cursor base]
 (let [[file-name file] (option-file root cursor)]
  (state/draw-lines! screen
   background
   (landing/overlay base 9 3 (landing/reset-box 76 file-name)))
  (let [ok (state/confirm! screen)]
   (cond (= ok :quit) :quit
    (true? ok)
    (try (edn-store/quarantine! file)
     (str file-name " reset, old file kept as " file-name ".corrupt")
     (catch Exception _ "could not reset!"))
    :else nil))))

(defn show!
 "Shows the landing on `screen`, with the solid colour `background`, and handles the keys
 until one leaves it; returns :back (to the settings menu) or :quit."
 [^TerminalScreen screen ^TextColor background]
 (loop [cursor 0
   message nil]
  (let [root @app/app-dir
    cs (counts root)
    ;; the option under the cursor has a file that cannot be used: where it is, and `r`
    unusable? (= ::unusable ((if (zero? cursor) :recipes :solutes) cs))
    message (or message
     (when unusable?
      (landing/unusable-hint (str (second (option-file root
          cursor))))))
    base (lines cs cursor message)
    _ (state/draw-lines! screen background base)
    input (state/read-input screen)]
   (cond
    (state/leave-key input) (state/leave-key input)
    (= input KeyType/ArrowDown) (recur (min 1 (inc cursor)) nil)
    (= input KeyType/ArrowUp) (recur (max 0 (dec cursor)) nil)
    (and (= input \r) unusable?)
    (let [r (reset-file! screen background root cursor base)]
     (if (= r :quit) r (recur cursor r)))
    (= input KeyType/Enter)
    (if (= :quit
      (if (zero? cursor)
       (recipes-menu/show! screen background)
       (custom-solutes-menu/show! screen background)))
     :quit
     (recur cursor nil))
    :else (recur cursor nil)))))
