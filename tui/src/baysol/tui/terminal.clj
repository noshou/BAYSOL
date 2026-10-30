;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Starting programs and terminal emulators: whether this program has a terminal, which
;; terminal emulator to open when it has none, and the command lines for each system. Used
;; by `core` (to open a terminal) and by the screens (to hand the terminal over).

(ns baysol.tui.terminal
 (:require
  [baysol.tui.log :as log]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (java.lang ProcessBuilder$Redirect)))

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
   (log/warn! "Cannot launch subprocess: no command specified"))))

(defn terminal?
 "True if standard input and output are a terminal (JDK 22 or later). The TERM variable
 says nothing about it: programs without a terminal inherit it."
 []
 (boolean (some-> (System/console)
   .isTerminal)))

(defn windows?
 "True if the `os.name` property `os` is a Windows."
 [os]
 (str/includes? (str/lower-case (str os)) "windows"))

(defn find-executable
 "The absolute path of the program `program` (a name looked up on the PATH of `env`, or a
 path) if it is there and executable, else nil. On Windows the extensions .exe, .cmd
 and .bat are tried too."
 [program env os]
 (let [extensions (if (windows? os) ["" ".exe" ".cmd" ".bat"] [""])
   dirs (if (str/includes? program java.io.File/separator)
    [nil]
    (str/split (or (get env "PATH") "")
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

;; The terminal emulators tried when nothing says which to use, in this order.
(def ^:private generic-terminals
 [
  ;; GNOME
  "ptyxis" "kgx" "gnome-terminal"

  ;; KDE
  "konsole"

  ;; XFCE, MATE
  "xfce4-terminal" "mate-terminal"

  ;; Other desktop environments
  "tilix" "deepin-terminal" "lxterminal" "qterminal" "terminology"
  "cosmic-term" ; COSMIC
  "io.elementary.terminal" ; elementary OS (Pantheon)
  "pantheon-terminal" ; older name of the same

  ;; Popular GTK / Qt / lightweight terminals
  "terminator" "sakura" "roxterm" "lilyterm" "mlterm" "zutty"
  "termite" ; no longer developed, still installed on older systems

  ;; Standalone / Wayland / X11 terminals
  "ghostty" "kitty" "wezterm" "alacritty" "foot" "contour" "rio"
  "xterm" "uxterm" "urxvt" "rxvt" "st"])

;; The terminals that belong to a desktop environment, by the lower-case parts of
;; XDG_CURRENT_DESKTOP (for example "ubuntu:GNOME" gives "ubuntu" and "gnome").
(def ^:private desktop-terminals
 {"kde" ["konsole"],
  "gnome" ["ptyxis" "kgx" "gnome-terminal"],
  "unity" ["gnome-terminal"],
  "x-cinnamon" ["gnome-terminal"],
  "cinnamon" ["gnome-terminal"],
  "xfce" ["xfce4-terminal"],
  "mate" ["mate-terminal"],
  "lxqt" ["qterminal"],
  "lxde" ["lxterminal"],
  "cosmic" ["cosmic-term"],
  "pantheon" ["io.elementary.terminal" "pantheon-terminal"],
  "deepin" ["deepin-terminal"],
  "enlightenment" ["terminology"]})

(defn terminal-candidates
 "The terminal emulators to try on Linux, most wanted first, from the environment `env`:
 the user's own choice ($TERMINAL), the freedesktop default (xdg-terminal-exec), the
 terminals of the current desktop (XDG_CURRENT_DESKTOP), the distribution's default
 (x-terminal-emulator), then every other known terminal."
 [env]
 (let [own (str/trim (str (get env "TERMINAL")))
   desktops (->> (str/split (str (get env "XDG_CURRENT_DESKTOP")) #":")
    (map str/lower-case))]
  (->> (concat (when-not (str/blank? own) [own])
    ["xdg-terminal-exec"]
    (mapcat desktop-terminals desktops)
    ["x-terminal-emulator"]
    generic-terminals)
   distinct
   vec)))

(defn ^:private find-terminal-linux
 "The path of the first installed terminal emulator among `terminal-candidates`, or nil."
 [env]
 (some #(find-executable % env "Linux") (terminal-candidates env)))

;; How a terminal emulator is told to run a command instead of a shell: the arguments that
;; go between its name and the command. `-e` is the convention of xterm and most others
;; follow it, so it is the default. Verified here: konsole (`-e`). The entries below come
;; from the programs' documentation and are untested.
(def ^:private exec-flags
 {"xdg-terminal-exec" [], ; takes the command directly
  "gnome-terminal" ["--"],
  "xfce4-terminal" ["-x"],
  "mate-terminal" ["-x"],
  "terminator" ["-x"],
  "kitty" [],
  "foot" [],
  "wezterm" ["start" "--"]})

(defn terminal-command
 "The command line that opens `terminal` (a name or a path) running `command`, a vector
 of strings: the terminal, its flags for running a command, then the command."
 [terminal command]
 (let [terminal-name (.getName (io/file terminal))]
  (vec (concat [terminal] (get exec-flags terminal-name ["-e"]) command))))

(defn program-command
 "The command that runs this program again, with the same Java and classpath."
 [java classpath]
 [java "-cp" classpath "clojure.main" "-m" "baysol.tui.core"])

(defn in-directory-command
 "The command that runs `command` from the directory `dir` on Linux and macOS: the
 arguments of `sh -c` are passed, not spliced into a string, so no quoting is needed."
 [dir command]
 (into ["sh" "-c" "cd \"$1\" && shift && exec \"$@\"" "sh" dir] command))

(defn shell-quote
 "`s` as one word for a Unix shell: in single quotes, with each single quote inside
 written as '\\''."
 [s]
 (str "'" (str/replace (str s) "'" "'\\''") "'"))

(defn mac-terminal-command
 "The command line that opens Terminal.app on macOS running `command` in `dir`: an
 AppleScript, with the shell line given as an argument of the script."
 [dir command]
 ["osascript"
  "-e" "on run argv"
  "-e" "tell application \"Terminal\" to do script (item 1 of argv)"
  "-e" "tell application \"Terminal\" to activate"
  "-e" "end run"
  (str "cd " (shell-quote dir)
   " && exec " (str/join " " (map shell-quote command)))])

(defn windows-terminal-command
 "The command line that opens a terminal on Windows running `command` in `dir`: Windows
 Terminal (`wt.exe`) when `windows-terminal?` is true, otherwise a new console window
 through `cmd`."
 [windows-terminal? dir command]
 (if windows-terminal?
  (into ["wt.exe" "-d" dir] command)
  (into ["cmd.exe" "/c" "start" "BAYSOL" "/D" dir] command)))

(defn open-terminal-cmd
 "The command line that opens a terminal emulator running `command` (a vector of
 strings) from the directory `dir`, on the operating system `os` (the `os.name`
 property) with the environment `env`; nil, with a warning, if there is none. Linux and
 macOS are tested only as far as the command lines are built (Linux also with a stand-in
 terminal); Windows and macOS have not been run."
 [os env dir command]
 (let [os-clean (-> os
    str/trim
    str/lower-case)]
  (cond
   (str/includes? os-clean "linux")
   (if-let [terminal (find-terminal-linux env)]
    (terminal-command terminal (in-directory-command dir command))
    (log/warn! "No supported Linux terminal emulator found"))

   (str/includes? os-clean "mac")
   (mac-terminal-command dir command)

   (windows? os-clean)
   (windows-terminal-command (boolean (find-executable "wt.exe" env os))
    dir
    command)

   :else
   (log/warn! "Unsupported operating system:" os))))
