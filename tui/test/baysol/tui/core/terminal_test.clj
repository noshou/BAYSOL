;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.core.terminal-test
 (:require [baysol.tui.core.terminal :as terminal]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (java.nio.file Files)
  (java.nio.file.attribute FileAttribute)))

(defn ^:private system [os env] {:os os, :env env, :home "/home/u", :cwd "/work"})

(defn ^:private bin-with
 "A new folder (a File) holding an executable file for each of `names`."
 [& names]
 (let [dir (.toFile (Files/createTempDirectory "baysol-test"
     (make-array FileAttribute 0)))]
  (doseq [n names]
   (let [file (io/file dir n)]
    (spit file "#!/bin/sh\n")
    (.setExecutable file true)))
  dir))

(deftest candidates-are-ordered-by-who-chose-them
 (testing
  "the user's $TERMINAL first, then xdg-terminal-exec, the desktop's, the default"
  (is (= ["kitty" "xdg-terminal-exec" "konsole" "x-terminal-emulator" "ptyxis"]
    (take 5
     (terminal/terminal-candidates
      (system "Linux"
       {"TERMINAL" "kitty", "XDG_CURRENT_DESKTOP" "KDE"}))))))
 (testing "ubuntu:GNOME is read as the desktop GNOME"
  (is (= ["xdg-terminal-exec" "ptyxis" "kgx" "gnome-terminal" "x-terminal-emulator"]
    (take 5
     (terminal/terminal-candidates
      (system "Linux" {"XDG_CURRENT_DESKTOP" "ubuntu:GNOME"}))))))
 (testing "XFCE"
  (is (= ["xdg-terminal-exec" "xfce4-terminal" "x-terminal-emulator"]
    (take 3
     (terminal/terminal-candidates
      (system "Linux" {"XDG_CURRENT_DESKTOP" "XFCE"}))))))
 (testing "a blank $TERMINAL and no desktop"
  (is (= ["xdg-terminal-exec" "x-terminal-emulator" "ptyxis"]
    (take 3
     (terminal/terminal-candidates (system "Linux" {"TERMINAL" "  "}))))))
 (testing "the user's choice and a desktop that has a terminal of its own"
  (is (= ["xterm" "xdg-terminal-exec" "gnome-terminal" "x-terminal-emulator"]
    (take 4
     (terminal/terminal-candidates
      (system "Linux"
       {"TERMINAL" "xterm",
        "XDG_CURRENT_DESKTOP" "X-Cinnamon"}))))))
 (testing "no name twice"
  (let [candidates (terminal/terminal-candidates
     (system "Linux"
      {"TERMINAL" "konsole", "XDG_CURRENT_DESKTOP" "KDE"}))]
   (is (= (count candidates) (count (distinct candidates)))))))

(deftest terminals-take-a-command-in-their-own-way
 (is (= ["konsole" "-e" "prog" "a b"]
   (terminal/terminal-command "konsole" ["prog" "a b"])))
 (is (= ["/usr/bin/gnome-terminal" "--" "prog"]
   (terminal/terminal-command "/usr/bin/gnome-terminal" ["prog"])))
 (is (= ["xfce4-terminal" "-x" "prog"]
   (terminal/terminal-command "xfce4-terminal" ["prog"])))
 (is (= ["xdg-terminal-exec" "prog"]
   (terminal/terminal-command "xdg-terminal-exec" ["prog"])))
 (is (= ["kitty" "prog"] (terminal/terminal-command "kitty" ["prog"])))
 (is (= ["wezterm" "start" "--" "prog"]
   (terminal/terminal-command "wezterm" ["prog"])))
 (testing "-e is the default"
  (is (= ["alacritty" "-e" "prog"]
    (terminal/terminal-command "alacritty" ["prog"])))))

(deftest a-command-is-run-in-a-directory-without-quoting
 (is (= ["sh" "-c" "cd \"$1\" && shift && exec \"$@\"" "sh" "/d e" "java" "-cp"
    "a:b"]
   (terminal/in-directory-command "/d e" ["java" "-cp" "a:b"]))))

(deftest shell-quote-wraps-one-word
 (is (= "'a b'" (terminal/shell-quote "a b")))
 (is (= "''" (terminal/shell-quote "")))
 (is (= "'it'\\''s'" (terminal/shell-quote "it's")))
 (is (= "'a'\\''b'\\''c'" (terminal/shell-quote "a'b'c"))))

(deftest macos-and-windows-command-lines
 (is (= ["osascript"
    "-e" "on run argv"
    "-e" "tell application \"Terminal\" to do script (item 1 of argv)"
    "-e" "tell application \"Terminal\" to activate"
    "-e" "end run"
    "cd '/Users/u/my dir' && exec '/jdk/bin/java' '-cp' 'a:b' 'clojure.main'"]
   (terminal/mac-terminal-command "/Users/u/my dir"
    ["/jdk/bin/java" "-cp" "a:b"
     "clojure.main"])))
 (is (= ["wt.exe" "-d" "C:\\proj" "java" "-cp" "x"]
   (terminal/windows-terminal-command true "C:\\proj" ["java" "-cp" "x"])))
 (is (= ["cmd.exe" "/c" "start" "BAYSOL" "/D" "C:\\proj" "java" "-cp" "x"]
   (terminal/windows-terminal-command false "C:\\proj" ["java" "-cp" "x"]))))

(deftest open-terminal-cmd-per-system
 (testing
  "Linux: the first installed candidate, running the command in the directory"
  (let [bin (bin-with "konsole" "kitty")]
   (is (= [(.getPath (io/file bin "konsole")) "-e"
      "sh" "-c" "cd \"$1\" && shift && exec \"$@\"" "sh" "/work" "prog"]
     (terminal/open-terminal-cmd (system "Linux" {"PATH" (.getPath bin)})
      ["prog"])))
   (testing "$TERMINAL wins"
    (is (= [(.getPath (io/file bin "kitty"))
       "sh" "-c" "cd \"$1\" && shift && exec \"$@\"" "sh" "/work" "prog"]
      (terminal/open-terminal-cmd
       (system "Linux" {"PATH" (.getPath bin), "TERMINAL" "kitty"})
       ["prog"]))))))
 (testing "Linux without any terminal: nil and a warning"
  (let [writer (java.io.StringWriter.)]
   (binding [*err* writer]
    (is (nil? (terminal/open-terminal-cmd (system "Linux" {"PATH" ""}) ["prog"]))))
   (is (str/includes? (str writer) "No supported Linux terminal emulator found"))))
 (testing "macOS"
  (is (= "osascript"
    (first (terminal/open-terminal-cmd (system "Mac OS X" {}) ["java"])))))
 (testing "Windows: Windows Terminal if it is installed, else cmd"
  (let [bin (bin-with "wt.exe")]
   (is (= ["wt.exe" "-d" "/work" "java"]
     (terminal/open-terminal-cmd (system "Windows 11" {"PATH" (.getPath bin)})
      ["java"])))
   (is (= ["cmd.exe" "/c" "start" "BAYSOL" "/D" "/work" "java"]
     (terminal/open-terminal-cmd (system "Windows 11" {"PATH" ""})
      ["java"])))))
 (testing "an unknown system: nil and a warning"
  (let [writer (java.io.StringWriter.)]
   (binding [*err* writer]
    (is (nil? (terminal/open-terminal-cmd (system "Plan 9" {}) ["x"]))))
   (is (str/includes? (str writer) "Unsupported operating system: Plan 9")))))
