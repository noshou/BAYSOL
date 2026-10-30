;; SPDX-License-Identifier: LGPL-3.0-or-later

;; "Open" (goto projects): the program ends and hands the terminal over to a shell in the
;; projects folder. A desktop's file manager is tried too, and a warning is printed if it
;; cannot be started. The terminal is already back to normal when `open!` runs.

(ns baysol.tui.screens.open-projects
 (:require
  [baysol.tui.log :as log]
  [baysol.tui.proj-dir.proj-dir :as proj-dir]
  [baysol.tui.terminal :as terminal]
  [clojure.string :as str])
 (:import (java.util.concurrent TimeUnit)))

;; How long to wait for the file manager's command to fail before assuming it worked, in
;; seconds: a file manager keeps running, so only a quick failure is a failure.
(def ^:private file-manager-wait-s 2)

(defn file-manager-commands
 "The commands to try, in order, to open the folder `dir` in the desktop's file manager on
 the operating system `os` (the `os.name` property); empty for an unknown system."
 [os dir]
 (let [os-clean (str/lower-case (str os))]
  (cond
   (str/includes? os-clean "linux") [["xdg-open" dir] ["gio" "open" dir]]
   (str/includes? os-clean "mac") [["open" dir]]
   (terminal/windows? os-clean) [["explorer" dir]]
   :else [])))

(defn subshell-command
 "The command that starts the user's shell, on the operating system `os` with the
 environment `env`: $SHELL (else /bin/sh) on Linux and macOS, %COMSPEC% (else cmd.exe) on
 Windows."
 [os env]
 (if (terminal/windows? os)
  [(or (get env "COMSPEC") "cmd.exe")]
  [(or (not-empty (get env "SHELL")) "/bin/sh")]))

(defn ^:private open-file-manager!
 "Tries to open the folder `dir` in the file manager. Returns nil if it worked, or a
 short reason if not. The command's output is discarded and it is never killed. On
 Windows its exit code is ignored, because explorer returns 1 even when it works."
 [dir]
 (let [os (System/getProperty "os.name")
   env (System/getenv)
   command (first (filter #(terminal/find-executable (first %) env os)
     (file-manager-commands os (str dir))))]
  (if-not command
   "no file manager command found"
   (try
    (let [process (terminal/launch-process! command)
      finished? (.waitFor process file-manager-wait-s TimeUnit/SECONDS)]
     (when (and finished?
       (not (terminal/windows? os))
       (not (zero? (.exitValue process))))
      (str (first command) " exited with " (.exitValue process))))
    (catch Exception e
     (str "could not start " (first command) ": " (ex-message e)))))))

(defn ^:private run-shell-in!
 "Starts the user's shell in the folder `dir`, with this program's terminal, and waits
 for it. Returns true if it ran."
 [dir]
 (try
  (println (str "BAYSOL: shell in " dir " (type exit to return)"))
  (-> (doto (ProcessBuilder. ^java.util.List
     (subshell-command (System/getProperty "os.name")
      (System/getenv)))
    (.directory dir)
    (.inheritIO))
   .start
   .waitFor)
  true
  (catch Exception e
   (log/error! "could not start a shell:" (ex-message e))
   false)))

(defn open!
 "Hands the terminal over: makes sure the projects folder exists (an error is printed and
 false returned if it cannot be made), tries the file manager, and runs a shell in the
 folder until the user leaves it. Returns true if all went well."
 []
 (try
  (let [dir @proj-dir/path]
   (when-let [reason (open-file-manager! dir)]
    (log/warn! "could not open the file manager:" reason))
   (run-shell-in! dir))
  (catch Exception e
   (log/error! (ex-message e) (pr-str (ex-data e)))
   (when-let [cause (ex-cause e)] (log/error! "caused by:" (ex-message cause)))
   false)))
