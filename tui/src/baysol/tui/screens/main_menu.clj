;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.main-menu
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.projects :as projects]
  [baysol.tui.screens.open-projects :as open-projects]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.project-menu :as project-menu]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.screens.state :as state]
  [baysol.tui.screens.theme :as theme]
  [baysol.tui.settings :as settings])
 (:import (com.googlecode.lanterna.screen TerminalScreen)
  (com.googlecode.lanterna.terminal DefaultTerminalFactory)
  (com.googlecode.lanterna.input KeyType)))

(set! *warn-on-reflection* true)

(def screen-name "main-menu")

;; the solid colour the whole screen is filled with: the theme's pink
(def background theme/background)

;; Where the release name is written on every page: row 12, under the bottom edge of the box
;; that says "main  menu", from the box's left edge (column 7) to the column before the box
;; of the keys (column 42): 35 characters fit (`bb fmt` checks the name in Project.toml
;; against that). The box is 18 columns wide inside, too narrow for a name of this length.
(def ^:private version-row 12)
(def ^:private version-from 7)
(def ^:private version-to 42)
(def ^:private release-name (app/version-name))

(defn ^:private page-asset
 "The lines of the page file `filename`, with the release name written on them, from the
 left edge of the box, under it."
 [filename]
 (update (pgld/load-ascii filename screen-name)
  version-row
  pgld/put-text
  version-from
  (- version-to version-from)
  release-name))

;; page mappings for the main menu screen
(def ^:private pages
 {:page1 ; new project
  {:asset (page-asset "page1"),
   :actions {KeyType/ArrowRight :page2,
    KeyType/ArrowDown :page3,
    KeyType/Enter :new-project
   }},
  :page2 ; load project
  {:asset (page-asset "page2"),
   :actions {KeyType/ArrowLeft :page1,
    KeyType/ArrowDown :page4,
    KeyType/Enter :load-project
   }},
  :page3 ; goto projects
  {:asset (page-asset "page3"),
   :actions {KeyType/ArrowUp :page1,
    KeyType/ArrowDown :page5,
    KeyType/ArrowRight :page4,
    KeyType/Enter :goto-projects
   }},
  :page4 ; settings
  {:asset (page-asset "page4"),
   :actions {KeyType/ArrowUp :page2,
    KeyType/ArrowDown :page6,
    KeyType/ArrowLeft :page3,
    KeyType/Enter :settings
   }},
  :page5 ; help
  {:asset (page-asset "page5"),
   :actions {KeyType/ArrowUp :page3,
    KeyType/ArrowRight :page6,
    KeyType/Enter :page5 ; future -> :settings
   }},
  :page6 ; quit
  {:asset (page-asset "page6"),
   :actions
   {KeyType/ArrowUp :page4, KeyType/ArrowLeft :page5, KeyType/Enter :quit}}})

;; How long a hotkey shows its page selected before it presses Enter there, in
;; milliseconds, so that the selection can be seen.
(def ^:private hotkey-delay-ms 50)

;; hotkeys: a letter (either case), or Esc, jumps to a page and then presses Enter on it
;; (Esc, and the terminal closing, go to the quit page, which is shown selected before the
;; program ends)
(def ^:private hotkeys
 {\n :page1, ; new project
  \l :page2, ; load project
  \o :page3, ; goto projects dir
  \s :page4, ; settings
  \h :page5, ; help
  KeyType/Escape :page6, ; quit (Esc)
  KeyType/EOF :page6 ; the terminal went away: quit, do not wait for keys that never come
 })

(defn ^:private page-after
 "The page that `input` leads to from `page`. A hotkey goes to its page and then does
 what Enter does there."
 [page input]
 (if-let [target (hotkeys input)]
  (state/handle pages target KeyType/Enter)
  (state/handle pages page input)))

;; The row between the rows of items that has room for a line of text: under `new` and
;; `load`. A prompt for a project name goes under `new`, in the left column, and a message
;; or what is typed to find a project under `load`, in the right one.
(def ^:private text-row 16)
(def ^:private prompt-col 6)
(def ^:private prompt-width 40)
(def ^:private message-col 50)
(def ^:private message-width 29)

;; The most characters a name may be typed with: a few more than it may have, so that a
;; name that is too long is told so.
(def ^:private max-typed 60)

;; The art of the right column (settings, quit) starts at index 49, the fiftieth column, on
;; every page; the left column ends by index 32.
(def ^:private right-column 49)

(def ^:private exit-hint
 "The reminder under a prompt or a list of how to leave it."
 "exit: esc")

(defn with-prompt
 "The lines of a page with `text` written in the row under `new`, in the left column; under
 it the `error` (nil for none), and then `exit: esc`. Everything left of the fiftieth
 column below the prompt (the items under `new`, open and help) is made blank first, so
 they do not show through."
 ([lines text] (with-prompt lines text nil))
 ([lines text error]
  (-> (vec (map-indexed
     (fn [i line]
      (if (> i text-row) (pgld/put-text line 0 right-column "") line))
     lines))
   (update text-row pgld/put-text prompt-col prompt-width text)
   (cond-> error
    (update (inc text-row) pgld/put-text prompt-col prompt-width error))
   (update (if error (+ 2 text-row) (inc text-row))
    pgld/put-text
    prompt-col
    prompt-width
    exit-hint))))

(defn with-message
 "The lines of a page with `text` (nil for none) written in the row under `load`, in the
 right column: 29 characters at most."
 [lines text]
 (if text
  (update lines text-row pgld/put-text message-col message-width text)
  lines))

(defn ^:private draw!
 "Draws the page `page` with a prompt (left) and a message (right) if given."
 [screen page prompt message]
 (state/draw-page screen
  {:asset (cond-> (:asset (pages page))
    prompt (with-prompt prompt message)
    (and message (not prompt)) (with-message message))}
  background))

(defn typed-name
 "The text of a name being typed for the prompt: `name: ` and the end of the name, with a
 cursor."
 [buffer]
 (let [room (- prompt-width (count "name: ") 1)]
  (str "name: "
   (if (> (count buffer) room)
    (str "…" (subs buffer (- (count buffer) (dec room))))
    buffer)
   "_")))

(defn ^:private ask-name!
 "Asks for the name of a new project under `new` on page 1 until it makes one, then returns
 its folder; nil if the user gives up with Escape. A name that is not valid, or is taken,
 is told on the right and the prompt stays; so is a problem making the project."
 [screen]
 (loop [buffer ""
   error nil]
  (draw! screen :page1 (typed-name buffer) error)
  (let [input (state/read-raw screen)]
   (cond
    (or (= input KeyType/Escape) (= input KeyType/EOF)) nil

    (= input KeyType/Enter)
    (let [problem (projects/name-problem buffer
       (projects/entry-names @app/projects-dir))]
     (if problem
      (recur buffer problem)
      (let [made (try (projects/create! @app/app-dir buffer)
         (catch clojure.lang.ExceptionInfo e
          (if (= ::projects/invalid-name (:type (ex-data e)))
           (:reason (ex-data e))
           "global settings unusable!"))
         (catch Exception _ "could not create the project!"))]
       (if (string? made) (recur buffer made) made))))

    (= input KeyType/Backspace) (recur (subs buffer 0 (max 0 (dec (count buffer))))
     nil)

    (and (char? input)
     (>= (int input) 32)
     (not= (int input) 127)
     (< (count buffer) max-typed))
    (recur (str buffer input) nil)

    :else (recur buffer error)))))

(defn blank-below-load
 "The lines of a page with everything from the fiftieth column (index 49) on, from the row
 under `load` to the bottom, made blank: the room a dropdown of projects takes, so that
 the items of the menu that were there (settings, quit) do not show through it."
 [lines]
 (vec (map-indexed
   (fn [i line]
    (if (>= i text-row) (pgld/put-text line right-column 31 "") line))
   lines)))

(defn ^:private pick-project!
 "Lets the user pick one of the projects `ids` from a dropdown under `load` on page 2: type
 to narrow the list, up and down to move, Enter to pick. Everything from the fiftieth
 column on below `load` is blank while it is open. Returns the folder of the project; nil
 if the user gives up with Escape."
 [screen ids]
 (loop [st (picker/initial ids nil)]
  (let [lines (-> (:asset (pages :page2))
     blank-below-load
     (with-message (str "find: " (picker/typed-text st 22)))
     (picker/overlay st
      {:row (inc text-row),
       :col message-col,
       :width message-width,
       :rows 7}))]
   (state/draw-page screen {:asset lines} background)
   (let [result (picker/step st (state/read-raw screen))]
    (cond (= result :cancel) nil
     (:chosen result) (projects/project-dir @app/projects-dir (:chosen result))
     :else (recur (:state result)))))))

(defn ^:private open-project!
 "Opens the project in `dir` on `screen`: its settings are checked first (the file is made
 as a copy of the global settings the first time), then its menu runs. Returns :back or
 :quit, or the message to show when the settings of the project cannot be used."
 [screen dir]
 (or (try (settings/load-project! dir @app/app-dir)
   nil
   (catch Exception _ "project settings unusable!"))
  (project-menu/show! screen background dir)))

(defn ^:private choose-project!
 "Chooses the project to load under `load` on page 2: the dropdown of the projects there
 are, and the folder of the one picked, or nil if the user gives up. With no project to
 pick from it says so under `load` and returns `{:message \"no projects to load!\"}`."
 [screen]
 (let [ids (projects/list-projects @app/projects-dir)]
  (if (empty? ids)
   (do (draw! screen :page2 nil "no projects to load!")
    {:message "no projects to load!"})
   (pick-project! screen ids))))

(defn ^:private main-loop
 "Draws the main menu on `screen` and handles the keys until an action ends it; returns that
 action (`:quit` or `:goto-projects`). The settings menu, the prompt for a new project, the
 list of projects and the project menu run on the same screen from here."
 [^TerminalScreen screen]
 ; draw initial page
 (draw! screen :page1 nil nil)

 ; loop through events; `message` is what is told on the page just drawn, until a key
 (loop [page :page1
   message nil]
  (let [input (state/read-input screen)
    target (hotkeys input)

    ; a hotkey first shows its page selected, waits, and only then presses Enter
    _ (when (and target (not= target page))
     (draw! screen target nil nil)
     (Thread/sleep (long hotkey-delay-ms)))
    next-page (page-after page input)
    ;; what a project that was made or picked ends on: `:quit` for the program, else
    ;; `[page message]`, back to this menu with the page it was opened from selected
    ;; and the message to tell, if there is one
    after-project (fn [from dir]
     (let [r (when (and dir (not (map? dir)))
        (open-project! screen dir))
       message (cond (string? r) r
        (map? dir) (:message dir))]
      (if (= r :quit)
       :quit
       (do (draw! screen from nil message) [from message]))))]
   (cond
    ;; the settings menu runs on this screen; when it goes back, the main menu is back
    ;; with the settings page selected, and when it quits so does the program
    (= next-page :settings)
    (if (= :quit (settings-menu/show! screen background))
     :quit
     (do (draw! screen :page4 nil nil) (recur :page4 nil)))

    ;; a new project: asked for a name, then its menu
    (= next-page :new-project)
    (let [r (after-project :page1 (ask-name! screen))]
     (if (= r :quit) :quit (recur (first r) (second r))))

    ;; a project to load: none to pick from is told under `load`
    (= next-page :load-project)
    (let [r (after-project :page2 (choose-project! screen))]
     (if (= r :quit) :quit (recur (first r) (second r))))

    (not (contains? pages next-page)) next-page ; an action: end and return it
    (= next-page page) (do (when message (draw! screen page nil nil))
     (recur page nil))

    ; a new page: draw it on the screen
    :else (do (draw! screen next-page nil nil) (recur next-page nil))))))

(defn ^:private run-menu
 "Runs the main menu on a terminal screen and returns what ends it (`:quit` or
 `:goto-projects`). The screen is stopped when it returns."
 []
 (let [factory (DefaultTerminalFactory.)
   ^TerminalScreen screen (.createScreen factory)]
  (.startScreen screen)
  (.setCursorPosition screen nil) ; hide the terminal's own text cursor
  (state/discard-pending! screen) ; keys typed while the program started act on nothing
  (try
   (main-loop screen)
   (finally
    ; leave the alternate screen, then close the terminal itself: that gives back the
    ; settings (echo, line editing) a shell started afterwards needs
    (.stopScreen screen)
    (.close (.getTerminal screen))))))

(defn -main
 "Runs the main menu, then hands the terminal over if the menu ended on an action that
 needs it."
 [& _]
 (when (= (run-menu) :goto-projects)
  (when-not (open-projects/open!) (System/exit 1))))
