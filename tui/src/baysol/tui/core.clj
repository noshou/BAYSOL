;; SPDX-License-Identifier: LGPL-3.0-or-later

;; What every other namespace of the TUI uses: saying something on stderr, the facts about
;; the machine this runs on, and starting programs. The pieces that only some use are in
;; the sub-namespaces `baysol.tui.core.app` (BAYSOL itself: version, folders) and
;; `baysol.tui.core.terminal` (opening a terminal emulator); the entry point is
;; `baysol.tui.main`.

(ns baysol.tui.core
 (:require
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (java.lang ProcessBuilder$Redirect)))

;; --- saying something
;; A line on stderr. Every namespace logs through here, so a different logger
;; (clojure.tools.logging, a file) would be a change in this section only.

(defn ^:private say!
 "Prints `level` and the `parts` joined by spaces as one line on stderr; returns nil."
 [level parts]
 (binding [*out* *err*] (println (str "BAYSOL " level ": " (str/join " " parts))))
 nil)

(defn warn!
 "Prints a warning line on stderr; returns nil."
 [& parts]
 (say! "warning" parts))

(defn error!
 "Prints an error line on stderr; returns nil."
 [& parts]
 (say! "error" parts))

;; --- the machine
;; The functions of the TUI that need to know about the machine take one map, as returned
;; by `read-system`, so they stay pure and a test can pass a hand-made one.

(defn read-system
 "The facts about this machine and this run, read once: `:os` (the os.name property),
 `:env` (the environment variables), `:home` (the user's home folder) and `:cwd` (the
 working directory)."
 []
 {:os (System/getProperty "os.name"),
  :env (System/getenv),
  :home (System/getProperty "user.home"),
  :cwd (System/getProperty "user.dir")})

(defn ^:private os-includes?
 "True if the lower-cased operating system of `system` contains `part`."
 [system part]
 (str/includes? (str/lower-case (str (:os system))) part))

(defn windows?
 "True if `system` is a Windows."
 [system]
 (os-includes? system "windows"))

(defn mac?
 "True if `system` is a Mac."
 [system]
 (os-includes? system "mac"))

(defn linux?
 "True if `system` is a Linux."
 [system]
 (os-includes? system "linux"))

(defn find-executable
 "The absolute path of the program `program` (a name looked up on the PATH of `system`,
 or a path) if it is there and executable, else nil. On Windows the extensions .exe,
 .cmd and .bat are tried too."
 [system program]
 (let [extensions (if (windows? system) ["" ".exe" ".cmd" ".bat"] [""])
   dirs (if (str/includes? program java.io.File/separator)
    [nil]
    (str/split (or (get (:env system) "PATH") "")
     (re-pattern java.io.File/pathSeparator)))]
  (some (fn [dir]
    (some (fn [extension]
      (let [file (if dir
         (io/file dir (str program extension))
         (io/file (str program extension)))]
       (when (and (.isFile file) (.canExecute file))
        (.getAbsolutePath file))))
     extensions))
   dirs)))

;; --- starting programs

(defn launch-process!
 "Starts the subprocess `command` (a vector of strings) without waiting for it, and
 returns it; its output is discarded. `env` is a map of environment variables to add to
 it. Returns nil, with a warning, for an empty command."
 ([command] (launch-process! command {}))
 ([command env]
  (if (seq command)
   (let [builder (doto (ProcessBuilder. ^java.util.List command)
      (.redirectOutput ProcessBuilder$Redirect/DISCARD)
      (.redirectError ProcessBuilder$Redirect/DISCARD))]
    (doseq [[k v] env] (.put (.environment builder) k v))
    (.start builder))
   (warn! "Cannot launch subprocess: no command specified"))))

(defn terminal?
 "True if standard input and output are a terminal (JDK 22 or later). The TERM variable
 says nothing about it: programs without a terminal inherit it."
 []
 (boolean (some-> (System/console)
   .isTerminal)))
