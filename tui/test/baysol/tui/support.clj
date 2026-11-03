;; SPDX-License-Identifier: LGPL-3.0-or-later

;; What the tests of the screens share: a screen on a virtual terminal that keys can be fed
;; to before the code that reads them runs, and a way to read back what was drawn, so the
;; real menus run without a terminal. Also a data folder to stand in for the user's own.

(ns baysol.tui.support
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.projects :as projects]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TerminalSize TextColor$ANSI)
  (com.googlecode.lanterna.input KeyStroke KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)
  (com.googlecode.lanterna.terminal.virtual DefaultVirtualTerminal)
  (java.nio.file Files)
  (java.nio.file.attribute FileAttribute)))

;; The keys and the background colour nearly every screen test uses.
(def background TextColor$ANSI/DEFAULT)
(def enter KeyType/Enter)
(def esc KeyType/Escape)
(def down KeyType/ArrowDown)
(def up KeyType/ArrowUp)
(def eof KeyType/EOF)

(defn has?
 "Whether the text `text` contains `s`."
 [text s]
 (str/includes? text s))

(defn keys-of
 "The keys of `inputs`: a string is each of its characters, anything else one key."
 [inputs]
 (mapcat #(if (string? %) (seq %) [%]) inputs))

(def ^:private temp-roots (atom []))

(defn ^:private delete-tree!
 "Deletes the folder or file `f` and everything under it."
 [^java.io.File f]
 (doseq [c (reverse (file-seq f))]
  (.delete ^java.io.File c)))

;; The folders `temp-root` made go when the JVM does, so a test run leaves none behind.
(.addShutdownHook (Runtime/getRuntime)
 (Thread. ^Runnable (fn [] (run! delete-tree! @temp-roots))))

(defn temp-root
 "A new empty folder (a File), deleted with its contents when the test JVM exits."
 []
 (let [dir (.toFile (Files/createTempDirectory "baysol-test"
     (make-array FileAttribute 0)))]
  (swap! temp-roots conj dir)
  dir))

(defmacro with-data-folder
 "Runs `body` with the BAYSOL folder and its projects folder in a new temporary folder,
 `(with-data-folder [root (temp-root)] ...)`: `root` (a File) is bound to it, so nothing
 touches the user's own data."
 [[root folder] & body]
 `(let [~root ~folder]
  (with-redefs [app/app-dir (delay ~root)
    app/cache-dir (delay (doto (io/file ~root "cache")
      (.mkdirs)))
    app/projects-dir (delay (doto (app/projects-root ~root)
      (.mkdirs)))]
   ~@body)))

(defn virtual-screen
 "A started screen on a virtual terminal of 80 columns by 24 rows:
 `{:terminal t :screen s}`."
 []
 (let [t (DefaultVirtualTerminal. (TerminalSize. 80 24))
   s (TerminalScreen. t)]
  (.startScreen s)
  {:terminal t, :screen s}))

(defn stroke
 "The Lanterna key of `k`: a character, a `KeyType` (Enter, Escape, an arrow ...) or
 `:ctrl-<letter>`."
 ^KeyStroke [k]
 (cond (char? k) (KeyStroke. ^Character k false false)
  (keyword? k) (KeyStroke. ^Character (.charAt (subs (name k) 5) 0) true false)
  :else (KeyStroke. ^KeyType k)))

(defn feed!
 "Queues keys for the screen of `vs` to read, in order. A string is each of its characters."
 [{:keys [^DefaultVirtualTerminal terminal]} & inputs]
 (doseq [k inputs
   c (if (string? k) (seq k) [k])]
  (.addInput terminal (stroke c))))

(defn screen-lines
 "What is drawn on the screen of `vs`, as a vector of its 24 rows of text."
 [{:keys [^TerminalScreen screen]}]
 (vec (for [row (range 24)]
   (apply str
    (for [col (range 80)]
     (.getCharacter (.getFrontCharacter screen col row)))))))

(defn screen-text
 "What is drawn on the screen of `vs` as one text of its rows."
 [vs]
 (str/join "\n" (screen-lines vs)))

(defn in-project
 "Calls `f` with a temporary BAYSOL folder (a File) and a new project `demo` in it
 (its folder), `(in-project (fn [root dir] ...))`."
 [f]
 (with-data-folder [root (temp-root)] (f root (projects/create! root "demo"))))

(defn run-keys!
 "Runs `(show! screen)` in a future on a new virtual screen with `inputs` fed (a
 sequential input is its keys); returns what it returned and the text the screen ended
 on. A screen still waiting after 20 seconds is given escapes and the result is
 `:timeout`."
 [show! & inputs]
 (let [vs (virtual-screen)
   f (future (show! (:screen vs)))]
  (apply feed! vs (mapcat #(if (sequential? %) % [%]) inputs))
  (let [r (deref f 20000 :timeout)]
   (when (= r :timeout)
    (feed! vs esc esc esc esc eof)
    (deref f 3000 nil))
   [r (screen-text vs)])))
