;; SPDX-License-Identifier: LGPL-3.0-or-later

;; "Open" (goto projects): the program ends and hands the terminal over to a shell in the
;; projects folder. A desktop's file manager is tried too, and a warning is printed if it
;; cannot be started. The terminal is already back to normal when `open!` runs.

(ns baysol.tui.screens.open-projects
 (:require
  [baysol.tui.core :as core]
  [baysol.tui.core.app :as app]
  [baysol.tui.settings :as settings])
 (:import (java.util.concurrent TimeUnit)))

;; How long to wait for the file manager's command to fail before assuming it worked, in
;; seconds: a file manager keeps running, so only a quick failure is a failure.
(def ^:private file-manager-wait-s 2)

(defn file-manager-commands
 "The commands to try, in order, to open the folder `dir` in the desktop's file manager
 on `system`; empty for an unknown system."
 [system dir]
 (cond
  (core/linux? system) [["xdg-open" dir] ["gio" "open" dir]]
  (core/mac? system) [["open" dir]]
  (core/windows? system) [["explorer" dir]]
  :else []))

(defn subshell-command
 "The command that starts the user's shell on `system`: $SHELL (else /bin/sh) on Linux
 and macOS, %COMSPEC% (else cmd.exe) on Windows."
 [system]
 (let [env (:env system)]
  (if (core/windows? system)
   [(or (get env "COMSPEC") "cmd.exe")]
   [(or (not-empty (get env "SHELL")) "/bin/sh")])))

(defn ^:private open-file-manager!
 "Tries to open the folder `dir` in the file manager. Returns nil if it worked, or a
 short reason if not. The command's output is discarded and it is never killed. On
 Windows its exit code is ignored, because explorer returns 1 even when it works."
 [dir]
 (let [system (core/read-system)
   command (first (filter #(core/find-executable system (first %))
     (file-manager-commands system (str dir))))]
  (if-not command
   "no file manager command found"
   (try
    (let [process (core/launch-process! command)
      finished? (.waitFor process file-manager-wait-s TimeUnit/SECONDS)]
     (when (and finished?
       (not (core/windows? system))
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
  (-> (doto (ProcessBuilder. ^java.util.List (subshell-command (core/read-system)))
    (.directory dir)
    (.inheritIO))
   .start
   .waitFor)
  true
  (catch Exception e
   (core/error! "could not start a shell:" (ex-message e))
   false)))

(defn check-settings!
 "Checks the settings of the user in the BAYSOL folder `root`, as every project that is
 opened does: each saved value is checked, and one that is not valid is wiped, back to its
 default. A warning is printed for each wipe (and for a settings file that could not be
 read). True when the settings are usable; false, with an error printed, when they are not
 (the defaults are corrupt and could not be made again)."
 [root]
 (try (let [{:keys [wiped reset?]} (meta (settings/load! root))]
   (when reset?
    (core/warn!
     "settings.edn could not be read; the defaults are used and the old file is"
     "kept as settings.edn.corrupt"))
   (doseq [{:keys [setting value reason]} wiped]
    (core/warn! "the setting"
     setting
     "was"
     (pr-str value)
     "which"
     reason
     "- reset to its default"))
   true)
  (catch Exception e
   (core/error! "the settings cannot be used:" (ex-message e))
   false)))

(defn open!
 "Hands the terminal over: makes sure the projects folder exists (an error is printed and
 false returned if it cannot be made), checks the settings (false if they cannot be used),
 tries the file manager, and runs a shell in the folder until the user leaves it. Returns
 true if all went well."
 []
 (try
  (let [dir @app/projects-dir]
   (and (check-settings! @app/app-dir)
    (do (when-let [reason (open-file-manager! dir)]
      (core/warn! "could not open the file manager:" reason))
     (run-shell-in! dir))))
  (catch Exception e
   (core/error! (ex-message e) (pr-str (ex-data e)))
   (when-let [cause (ex-cause e)] (core/error! "caused by:" (ex-message cause)))
   false)))
