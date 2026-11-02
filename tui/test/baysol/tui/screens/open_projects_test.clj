;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.open-projects-test
 (:require [baysol.tui.screens.open-projects :as open-projects]
  [clojure.test :refer [deftest is testing]]))

(deftest file-managers-by-system
 (is (= [["xdg-open" "/p d"] ["gio" "open" "/p d"]]
   (open-projects/file-manager-commands {:os "Linux"} "/p d")))
 (is (= [["open" "/p d"]]
   (open-projects/file-manager-commands {:os "Mac OS X"} "/p d")))
 (is (= [["explorer" "/p d"]]
   (open-projects/file-manager-commands {:os "Windows 11"} "/p d")))
 (is (= [] (open-projects/file-manager-commands {:os "FreeBSD"} "/p d"))))

(deftest the-shell-comes-from-the-environment
 (testing "Linux and macOS: $SHELL, else /bin/sh (an empty one counts as missing)"
  (is (= ["/bin/zsh"]
    (open-projects/subshell-command {:os "Linux", :env {"SHELL" "/bin/zsh"}})))
  (is (= ["/bin/sh"] (open-projects/subshell-command {:os "Linux", :env {}})))
  (is (= ["/bin/sh"]
    (open-projects/subshell-command {:os "Linux", :env {"SHELL" ""}})))
  (is (= ["/bin/zsh"]
    (open-projects/subshell-command {:os "Mac OS X",
      :env {"SHELL" "/bin/zsh"}}))))
 (testing "Windows: %COMSPEC%, else cmd.exe"
  (is (= ["C:\\W\\cmd.exe"]
    (open-projects/subshell-command {:os "Windows 11",
      :env {"COMSPEC" "C:\\W\\cmd.exe"}})))
  (is (= ["cmd.exe"]
    (open-projects/subshell-command {:os "Windows 11", :env {}})))))
