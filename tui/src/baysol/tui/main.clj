;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Entry point of the terminal UI (`clojure -M:run` from tui/). In a terminal it runs the
;; main menu. Without one (started from a desktop icon, say) it opens a terminal emulator
;; that runs this same program again, and ends: launching that subprocess is all it does
;; then.

(ns baysol.tui.main
 (:require
  [baysol.tui.core :as core]
  [baysol.tui.core.terminal :as terminal]
  [baysol.tui.screens.main-menu :as main-menu]))

;; Set in the environment of a terminal this program opened itself, so that the copy
;; running there never opens another one if it still finds no terminal.
(def ^:private in-terminal-var "BAYSOL_IN_TERMINAL")

(defn program-command
 "The command that runs this program again, with the same Java and classpath."
 [java classpath]
 [java "-cp" classpath "clojure.main" "-m" "baysol.tui.main"])

(defn -main
 "Starts the TUI: here if this is a terminal, otherwise in a terminal emulator it opens."
 [& _args]
 (cond
  (core/terminal?)
  (main-menu/-main)

  (System/getenv in-terminal-var)
  (do (core/error!
    "BAYSOL needs a terminal, and none is attached even in the one it opened")
   (System/exit 1))

  :else
  (let [java (str (System/getProperty "java.home") "/bin/java")
    program (program-command java (System/getProperty "java.class.path"))
    terminal-cmd (terminal/open-terminal-cmd (core/read-system) program)]
   (if terminal-cmd
    (core/launch-process! terminal-cmd {in-terminal-var "1"})
    (do (core/error!
      "BAYSOL needs a terminal: start it from one (over ssh: ssh -t)")
     (System/exit 1))))))
