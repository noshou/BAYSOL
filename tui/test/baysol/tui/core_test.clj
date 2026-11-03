;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.core-test
 (:require [baysol.tui.core :as core]
  [baysol.tui.support :refer [temp-root]]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(defn ^:private executable!
 "Makes the file `file-name` in `dir`; executable if `executable?`."
 [dir file-name executable?]
 (let [file (io/file dir file-name)]
  (spit file "#!/bin/sh\n")
  (.setExecutable file executable?)
  file))

(defn ^:private stderr-of
 "What `f` prints on *err*, trimmed."
 [f]
 (let [writer (java.io.StringWriter.)]
  (binding [*err* writer] (f))
  (str/trim (str writer))))

(deftest read-system-has-the-four-facts
 (let [system (core/read-system)]
  (is (every? some? (map system [:os :env :home :cwd])))
  (is (string? (:os system)))))

(deftest operating-system-predicates
 (testing "windows?"
  (is (core/windows? {:os "Windows 11"}))
  (is (core/windows? {:os "windows"}))
  (is (not-any? core/windows?
    [{:os "Linux"} {:os "Mac OS X"} {:os "FreeBSD"} {:os ""}])))
 (testing "mac? and linux?"
  (is (core/mac? {:os "Mac OS X"}))
  (is (core/linux? {:os "Linux"}))
  (is (not (core/mac? {:os "Linux"})))
  (is (not (core/linux? {:os "Mac OS X"})))))

(deftest find-executable-looks-on-the-path
 (let [dir (temp-root)
   _ (executable! dir "konsole" true)
   _ (executable! dir "notexec" false)
   _ (executable! dir "wt.exe" true)
   system (fn [os env] {:os os, :env env})
   path {"PATH" (.getPath dir)}]
  (testing "an executable file on the PATH"
   (is (= (.getPath (io/file dir "konsole"))
     (core/find-executable (system "Linux" path) "konsole"))))
  (testing "a missing program, a file that is not executable, no PATH at all"
   (is (nil? (core/find-executable (system "Linux" path) "nope")))
   (is (nil? (core/find-executable (system "Linux" path) "notexec")))
   (is (nil? (core/find-executable (system "Linux" {}) "konsole"))))
  (testing "a path is taken as it is"
   (is (= (.getPath (io/file dir "konsole"))
     (core/find-executable (system "Linux" {"PATH" ""})
      (.getPath (io/file dir "konsole"))))))
  (testing ".exe is tried on Windows only"
   (is (= (.getPath (io/file dir "wt.exe"))
     (core/find-executable (system "Windows 11" path) "wt")))
   (is (nil? (core/find-executable (system "Linux" path) "wt"))))))

(deftest logging-goes-to-stderr-and-returns-nil
 (is (= "BAYSOL warning: a b 3" (stderr-of #(core/warn! "a" "b" 3))))
 (is (= "BAYSOL error: boom" (stderr-of #(core/error! "boom"))))
 (let [results (atom nil)]
  (stderr-of #(reset! results [(core/warn! "x") (core/error! "y")]))
  (is (= [nil nil] @results))))

(deftest launch-process-needs-a-command
 (is (nil? (core/launch-process! [])))
 (is (= "BAYSOL warning: Cannot launch subprocess: no command specified"
   (stderr-of #(core/launch-process! [])))))
