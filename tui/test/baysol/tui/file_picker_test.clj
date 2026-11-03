;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The file picker's command lines and the reading of its output; no window is opened.

(ns baysol.tui.file-picker-test
 (:require [baysol.tui.file-picker :as file-picker]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(deftest commands
 (let [linux {:os "Linux", :env {}}
   kde {:os "Linux", :env {"XDG_CURRENT_DESKTOP" "KDE"}}]
  (testing "Linux: zenity first, kdialog first on KDE, both multiple choice"
   (is (= ["zenity" "kdialog"]
     (map first (file-picker/picker-commands linux "/h"))))
   (is (= ["kdialog" "zenity"] (map first (file-picker/picker-commands kde "/h"))))
   (doseq [command (file-picker/picker-commands linux "/h")]
    (is (some #{"--multiple"} command))))
  (testing "the start folder is in the command"
   (is (some #(= "--filename=/home/me/" %)
     (first (file-picker/picker-commands linux "/home/me")))))
  (testing "the sequence picker is for one FASTA or FASTQ file"
   (let [spec (:sequence file-picker/specs)
     cmds (file-picker/picker-commands linux "/h" spec)]
    (is (not (:multiple? spec)))
    (is (= ["zenity" "kdialog"] (map first cmds)))
    (doseq [command cmds]
     (is (not-any? #{"--multiple"} command))
     (is (some #(str/includes? % "*.fasta") command))
     (is (some #(str/includes? % "*.FQ") command)))
    (is (some #(str/includes? % "Sequence files") (first cmds)))
    (is (some #(str/includes? % "fasta")
      (first (file-picker/picker-commands
        {:os "Mac OS X"}
        "/h"
        spec))))
    (is (some #(str/includes? % "$false")
      (first
       (file-picker/picker-commands {:os "Windows 11"} "C:\\Users" spec))))
    (testing "and the structure picker is unchanged"
     (is (= (file-picker/picker-commands linux "/h")
       (file-picker/picker-commands linux
        "/h"
        (:structure file-picker/specs)))))))
  (testing "other systems"
   (is (= "osascript" (ffirst (file-picker/picker-commands {:os "Mac OS X"} "/h"))))
   (is (= "powershell"
     (ffirst (file-picker/picker-commands {:os "Windows 11"} "C:\\Users"))))
   (is (= [] (file-picker/picker-commands {:os "Plan 9"} "/h"))))))

(deftest output
 (is (= ["/a/one.pdb" "/b/two three.cif"]
   (file-picker/parse-output "/a/one.pdb\n/b/two three.cif\n")))
 (is (= ["/a/one.pdb"] (file-picker/parse-output "/a/one.pdb\r\n\n")))
 (is (= [] (file-picker/parse-output "")))
 (is (= [] (file-picker/parse-output nil))))
