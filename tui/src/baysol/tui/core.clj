;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Entry point of the terminal UI (`clojure -M:run` from tui/). In a
;; terminal it runs the main menu. Without one (started from a desktop
;; icon, say) it opens a terminal emulator that runs this same program
;; again, and ends: launching that subprocess is all it does then.

(ns baysol.tui.core
 (:require
  [baysol.tui.log :as log]
  [baysol.tui.screens.main-menu :as main-menu]
  [baysol.tui.terminal :as terminal]))

;; Set in the environment of a terminal this program opened itself, so that the copy
;; running there never opens another one if it still finds no terminal.
(def ^:private in-terminal-var "BAYSOL_IN_TERMINAL")

(defn -main
 "Starts the TUI: here if this is a terminal, otherwise in a terminal emulator it opens."
 [& _args]
 (cond
  (terminal/terminal?)
  (main-menu/-main)

  (System/getenv in-terminal-var)
  (do (log/error!
    "BAYSOL needs a terminal, and none is attached even in the one it opened")
   (System/exit 1))

  :else
  (let [java (str (System/getProperty "java.home") "/bin/java")
    program (terminal/program-command java
     (System/getProperty "java.class.path"))
    terminal-cmd (terminal/open-terminal-cmd (System/getProperty "os.name")
     (System/getenv)
     (System/getProperty "user.dir")
     program)]
   (if terminal-cmd
    (terminal/launch-process! terminal-cmd {in-terminal-var "1"})
    (do (log/error! "BAYSOL needs a terminal: start it from one (over ssh: ssh -t)")
     (System/exit 1))))))
