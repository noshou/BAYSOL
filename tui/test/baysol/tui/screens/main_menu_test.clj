;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The new and load parts of the main menu: the prompt for a project name and the list to
;; pick a project from, run for real on a virtual screen with keys fed to it, and the lines
;; they write on the pages.

(ns baysol.tui.screens.main-menu-test
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.projects :as projects]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.main-menu :as main-menu]
  [baysol.tui.screens.state :as state]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :as support]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyStroke KeyType)))

(def ^:private ask-name! @#'main-menu/ask-name!)
(def ^:private pick-project! @#'main-menu/pick-project!)
(def ^:private open-project! @#'main-menu/open-project!)

(defn ^:private row
 "Row `i` of what is drawn on the virtual screen `vs`."
 [vs i]
 (nth (support/screen-lines vs) i))

(defn ^:private error-row
 "The row under the name prompt (under `new`): the error of the prompt, trimmed."
 [vs]
 (str/trim (subs (row vs 17) 0 49)))

(defn ^:private message-row
 "The row under `new` and `load` of the screen, split into its left and right halves."
 [vs]
 (let [r (row vs 16)] [(subs r 0 50) (str/trimr (subs r 50))]))













(deftest the-name-prompt
 (testing "asking for a name"
  (support/with-data-folder
   [root (support/temp-root)]
   (testing "a good name makes the project and returns its folder"
    (let [vs (support/virtual-screen)]
     (support/feed! vs "My_Project-1" KeyType/Enter)
     (let [dir (ask-name! (:screen vs))]
      (is (= (io/file (app/projects-root root) "My_Project-1") dir))
      (is (some? (projects/read-project dir)))
      (is (= (slurp (settings/settings-file root))
        (slurp (settings/settings-file dir)))))))
   (testing
    "what is typed shows under new, with a cursor, and a key that goes back removes it"
    (let [vs (support/virtual-screen)]
     (support/feed! vs "abx" KeyType/Backspace "c" KeyType/Escape)
     (is (nil? (ask-name! (:screen vs))))
     (is (str/includes? (first (message-row vs)) "name: abc_"))))
   (testing "escape gives up and makes nothing"
    (let [vs (support/virtual-screen)]
     (support/feed! vs "nothing" KeyType/Escape)
     (is (nil? (ask-name! (:screen vs))))
     (is (= ["My_Project-1"]
       (projects/list-projects (app/projects-root root))))))
   (testing "a name with nothing in it is told so, and the prompt stays"
    (let [vs (support/virtual-screen)]
     (support/feed! vs KeyType/Enter KeyType/Escape)
     (is (nil? (ask-name! (:screen vs))))
     (is (= "type a name first!" (error-row vs)))))
   (testing "a name that is not valid is told so, with what is allowed"
    (doseq [[bad message] [["has space" "use only a-z 0-9 . _ -"]
       ["a/b" "use only a-z 0-9 . _ -"]
       ["con" "reserved name, pick another"]
       ["name." "must not end with a dot"]
       [(apply str (repeat 45 "z"))
        "name too long (40 at most)"]]]
     (let [vs (support/virtual-screen)]
      (support/feed! vs bad KeyType/Enter KeyType/Escape)
      (is (nil? (ask-name! (:screen vs))) bad)
      (is (= message (error-row vs)) bad))))
   (testing "a name that is taken is told so, whatever the case"
    (doseq [again ["My_Project-1" "my_project-1" "MY_PROJECT-1"]]
     (let [vs (support/virtual-screen)]
      (support/feed! vs again KeyType/Enter KeyType/Escape)
      (is (nil? (ask-name! (:screen vs))))
      (is (= "that project already exists!" (error-row vs))))))
   (testing "a name held by a broken project folder says so, in full"
    (let [broken (io/file (app/projects-root root) "Held")]
     (io/make-parents (io/file broken "project.edn"))
     (spit (io/file broken "project.edn") "not edn (")
     (let [vs (support/virtual-screen)]
      (support/feed! vs "held" KeyType/Enter KeyType/Escape)
      (is (nil? (ask-name! (:screen vs))))
      (is (str/includes? (str/join "\n" (support/screen-lines vs))
        "that name is taken by a broken project folder!")))))
   (testing "the message goes when the next key is typed, and a second try can work"
    (let [vs (support/virtual-screen)]
     (support/feed! vs
      "bad name"
      KeyType/Enter
      KeyType/Backspace
      KeyType/Backspace
      KeyType/Backspace
      KeyType/Backspace
      KeyType/Backspace
      "ok2"
      KeyType/Enter)
     (let [dir (ask-name! (:screen vs))]
      (is (some? dir))
      (is (= "badok2" (.getName dir))
       "five backspaces took away the space and name, ok2 was typed"))))))

 (testing "a name can be typed with capitals and punctuation"
  (support/with-data-folder [_ (support/temp-root)]
   (let [vs (support/virtual-screen)]
    (support/feed! vs "SASDMJ9_fit.2-a" KeyType/Enter)
    (is (= "SASDMJ9_fit.2-a"
      (.getName (ask-name! (:screen vs))))))))

 (testing "a name with a problem in making it is told"
  (support/with-data-folder
   [root (support/temp-root)]
   (testing "the global settings cannot be used"
    (binding [settings/*regenerate* (constantly false)
      settings/*read* (fn [] [{} []])]
     (let [vs (support/virtual-screen)]
      (support/feed! vs "fine" KeyType/Enter KeyType/Escape)
      (is (nil? (ask-name! (:screen vs))))
      (is (= "global settings unusable!" (error-row vs)))
      (is (empty? (projects/entry-names (app/projects-root
          root))))))))))





;; --- the whole menu, on a virtual screen

(def ^:private main-loop @#'main-menu/main-loop)

;; the release name is written on the main menu, so it says that the main menu is shown
(def ^:private release (app/version-name))

(defn ^:private run-with!
 "Runs the main menu on a virtual screen in the background and gives `step` (a function
 of the screen, that can feed keys and `wait-for` what is drawn) its turn; returns what
 the menu returned, waiting for it up to 10 seconds."
 [step]
 (let [vs (support/virtual-screen)
   result (future (main-loop (:screen vs)))]
  (try (step vs)
   (finally nil))
  (let [r (deref result 10000 :timeout)]
   (when (= r :timeout) (future-cancel result))
   r)))

(defn ^:private wait-for
 "Waits up to 5 seconds for the text `fragment` to be on the screen of `vs`; the screen text
 when it is, or when the time is up."
 [vs fragment]
 (loop [n 0]
  (let [text (support/screen-text vs)]
   (if (or (str/includes? text fragment) (> n 250))
    text
    (do (Thread/sleep 20) (recur (inc n)))))))

















(deftest the-whole-menu
 (testing "the menu quits on escape"
  (is (= :quit (run-with! (fn [vs] (support/feed! vs KeyType/Escape))))))

 (testing "the menu quits when the terminal goes away, instead of waiting for keys"
  (is (= :quit (run-with! (fn [vs] (support/feed! vs KeyType/EOF))))))

 (testing "load with no projects says so under load"
  (support/with-data-folder
   [_ (support/temp-root)]
   (let [seen (atom nil)
     r (run-with! (fn [vs]
       (support/feed! vs \l)
       (reset! seen (wait-for vs "no projects to load!"))
       (support/feed! vs KeyType/Escape)))]
    (is (= :quit r))
    (is (str/includes? @seen "no projects to load!"))
    (let [lines (str/split-lines @seen)]
     (is (str/includes? (subs (nth lines 16) 50) "no projects to load!")
      "under load, on the right")
     (is (str/starts-with? (str/triml (subs (nth lines 16) 0 50)) "")
      "and nothing under new"))))
  (testing "the message goes with the next key, and the menu keeps working"
   (support/with-data-folder
    [_ (support/temp-root)]
    (let [seen (atom nil)
      r (run-with! (fn [vs]
        (support/feed! vs \l)
        (wait-for vs "no projects to load!")
        (support/feed! vs KeyType/ArrowDown)
        (Thread/sleep 300)
        (reset! seen (support/screen-text vs))
        (support/feed! vs KeyType/Escape)))]
     (is (= :quit r))
     (is (not (str/includes? @seen "no projects to load!")))))))

 (testing "load with the enter key says so too"
  (support/with-data-folder
   [_ (support/temp-root)]
   (let [seen (atom nil)
     r (run-with! (fn [vs]
       (support/feed! vs KeyType/ArrowRight KeyType/Enter)
       (reset! seen (wait-for vs "no projects to load!"))
       (support/feed! vs KeyType/Escape)))]
    (is (= :quit r))
    (is (str/includes? @seen "no projects to load!")))))

 (testing "a new project is asked for made and opened"
  (support/with-data-folder
   [root (support/temp-root)]
   (let [seen (atom {})
     r (run-with! (fn [vs]
       (support/feed! vs \n)
       (swap! seen assoc :prompt (wait-for vs "name: _"))
       (support/feed! vs "demo1" KeyType/Enter)
       (swap! seen assoc :menu (wait-for vs "project menu"))
       (support/feed! vs :ctrl-x)
       (swap! seen assoc :back (wait-for vs release))
       (support/feed! vs KeyType/Escape)))]
    (is (= :quit r))
    (is (str/includes? (:prompt @seen) "name: _"))
    (is (str/includes? (:menu @seen) "project menu") "the project menu opened")
    (is (str/includes? (:back @seen) release) "ctrl-x came back to the main menu")
    (let [dir (io/file (app/projects-root root) "demo1")]
     (is (some? (projects/read-project dir)))
     (is (= (slurp (settings/settings-file root))
       (slurp (settings/settings-file dir))))))))

 (testing "a bad name is told and escape gives up"
  (support/with-data-folder
   [root (support/temp-root)]
   (let [seen (atom nil)
     r (run-with! (fn [vs]
       (support/feed! vs \n "bad name" KeyType/Enter)
       (reset! seen (wait-for vs "use only a-z 0-9 . _ -"))
       (support/feed! vs KeyType/Escape)
       (wait-for vs release)
       (support/feed! vs KeyType/Escape)))]
    (is (= :quit r))
    (is (str/includes? @seen "use only a-z 0-9 . _ -"))
    (is (empty? (projects/entry-names (app/projects-root root)))))))

 (testing "a name that exists is told"
  (support/with-data-folder
   [root (support/temp-root)]
   (projects/create! root "taken")
   (let [seen (atom nil)
     r (run-with! (fn [vs]
       (support/feed! vs \n "Taken" KeyType/Enter)
       (reset! seen (wait-for vs "that project already exists!"))
       (support/feed! vs KeyType/Escape KeyType/Escape)))]
    (is (= :quit r))
    (is (str/includes? @seen "that project already exists!"))
    (is (= ["taken"]
      (projects/list-projects (app/projects-root root)))))))

 (testing "a project is loaded from the list"
  (support/with-data-folder
   [root (support/temp-root)]
   (doseq [id ["alpha" "beta"]] (projects/create! root id))
   (let [seen (atom {})
     r (run-with! (fn [vs]
       (support/feed! vs \l)
       (swap! seen assoc :list (wait-for vs "1 of 2 matches"))
       (support/feed! vs KeyType/ArrowDown KeyType/Enter)
       (swap! seen assoc :menu (wait-for vs "project menu"))
       (support/feed! vs :ctrl-x)
       (wait-for vs release)
       (support/feed! vs KeyType/Escape)))]
    (is (= :quit r))
    (is (str/includes? (:list @seen) "alpha"))
    (is (str/includes? (:list @seen) "beta"))
    (is (str/includes? (:menu @seen) "project menu")))))

 (testing "a project can be given up on and escape in its menu quits"
  (support/with-data-folder
   [root (support/temp-root)]
   (projects/create! root "p")
   (testing "escape in the list goes back to the main menu"
    (let [seen (atom nil)
      r (run-with! (fn [vs]
        (support/feed! vs \l)
        (wait-for vs "1 of 1 matches")
        (support/feed! vs KeyType/Escape)
        (reset! seen (wait-for vs release))
        (support/feed! vs KeyType/Escape)))]
     (is (= :quit r))
     (is (str/includes? @seen release))))
   (testing "escape in the project menu quits the program"
    (is (= :quit
      (run-with! (fn [vs]
        (support/feed! vs \l KeyType/Enter)
        (wait-for vs "project menu")
        (support/feed! vs
         KeyType/Escape))))))))

 (testing "settings that cannot be used are told under the menu item"
  (support/with-data-folder
   [_ (support/temp-root)]
   (binding [settings/*regenerate* (constantly false)
     settings/*read* (fn [] [{} []])]
    (let [seen (atom nil)
      r (run-with! (fn [vs]
        (support/feed! vs \n "fine" KeyType/Enter)
        (reset! seen (wait-for vs "global settings unusable!"))
        (support/feed! vs KeyType/Escape KeyType/Escape)))]
     (is (= :quit r))
     (is (str/includes? @seen "global settings unusable!")))))))

(deftest the-project-list
 (testing "picking a project"
  (support/with-data-folder
   [root (support/temp-root)]
   (doseq [id ["alpha" "Beta" "betamax" "gamma"]] (projects/create! root id))
   (let [projects-root (app/projects-root root)
     ids (projects/list-projects projects-root)]
    (testing "the projects are listed in a dropdown, the first highlighted"
     (let [vs (support/virtual-screen)]
      (support/feed! vs KeyType/Escape)
      (is (nil? (pick-project! (:screen vs) ids)))
      (let [text (support/screen-text vs)]
       (is (str/includes? text "> alpha"))
       (is (str/includes? text "Beta"))
       (is (str/includes? text "betamax"))
       (is (str/includes? text "gamma"))
       (is (str/includes? text "1 of 4 matches"))
       (is (str/includes? (second (message-row vs)) "find: _")))))
    (testing "enter picks the highlighted project"
     (let [vs (support/virtual-screen)]
      (support/feed! vs KeyType/Enter)
      (is (= (io/file projects-root "alpha") (pick-project! (:screen vs) ids)))))
    (testing "down and enter pick the next one"
     (let [vs (support/virtual-screen)]
      (support/feed! vs KeyType/ArrowDown KeyType/Enter)
      (is (= (io/file projects-root "Beta") (pick-project! (:screen vs) ids)))))
    (testing "typing narrows the list and shows what was typed"
     (let [vs (support/virtual-screen)]
      (support/feed! vs "bet" KeyType/Escape)
      (pick-project! (:screen vs) ids)
      (let [text (support/screen-text vs)]
       (is (str/includes? text "find: bet_"))
       (is (str/includes? text "> Beta"))
       (is (str/includes? text "1 of 2 matches")))))
    (testing "typing a name and enter picks it"
     (let [vs (support/virtual-screen)]
      (support/feed! vs "gam" KeyType/Enter)
      (is (= (io/file projects-root "gamma") (pick-project! (:screen vs) ids)))))
    (testing "a name that matches nothing cannot be picked"
     (let [vs (support/virtual-screen)]
      (support/feed! vs "zzz" KeyType/Enter KeyType/Escape)
      (is (nil? (pick-project! (:screen vs) ids)))
      (is (str/includes? (support/screen-text vs) "not in the list"))))
    (testing "escape gives up"
     (let [vs (support/virtual-screen)]
      (support/feed! vs "g" KeyType/Escape)
      (is (nil? (pick-project! (:screen vs) ids))))))))

 (testing "opening a project"
  (support/with-data-folder
   [root (support/temp-root)]
   (let [dir (projects/create! root "p")]
    (testing "its menu runs, and ctrl-x or escape end it"
     (let [vs (support/virtual-screen)]
      (support/feed! vs :ctrl-x)
      (is (= :back (open-project! (:screen vs) dir))))
     (let [vs (support/virtual-screen)]
      (support/feed! vs KeyType/Escape)
      (is (= :quit (open-project! (:screen vs) dir)))))
    (testing
     "its settings are checked first: a wiped value is back at the global value"
     (settings/save! root :sampler "N_ADAPT" 450)
     (spit (settings/settings-file dir) (pr-str {:sampler {"N_ADAPT" {:value 0}}}))
     (let [vs (support/virtual-screen)]
      (support/feed! vs :ctrl-x)
      (is (= :back (open-project! (:screen vs) dir)))
      (is (= 450
        (settings/value (get-in (settings/load-project! dir root)
          [:sampler "N_ADAPT"]))))))
    (testing "settings that cannot be used give a message and no menu"
     (binding [settings/*regenerate* (constantly false)
       settings/*read* (fn [] [{} []])]
      (let [vs (support/virtual-screen)]
       (is (= "project settings unusable!" (open-project! (:screen vs) dir)))))))))

 (testing "the dropdown has the room under load to itself"
  (support/with-data-folder
   [root (support/temp-root)]
   (doseq [id ["alpha" "beta"]] (projects/create! root id))
   (let [ids (projects/list-projects (app/projects-root root))
     vs (support/virtual-screen)
     page (:asset (get @#'main-menu/pages :page2))]
    (support/feed! vs KeyType/Escape)
    (pick-project! (:screen vs) ids)
    (let [lines (support/screen-lines vs)
      right (fn [i] (subs (nth lines i) 49))
      left (fn [i] (subs (nth lines i) 0 49))]
     (testing
      "nothing of the art is left right of column 50, from the row under load down"
      (doseq [i (range 17 24)]
       (is (not (re-find #"[╔═║╝╚┌┐└┘│─╴╶╷╵]" (right i)))
        (str "row " i ": " (right i)))))
     (testing "the list is there, and the rows under it are blank"
      (is (str/includes? (right 17) "> alpha"))
      (is (str/includes? (right 18) "beta"))
      (is (str/includes? (right 19) "1 of 2 matches"))
      (doseq [i (range 20 24)] (is (str/blank? (right i)) (str "row " i))))
     (testing "the rows above, and everything left of column 50, are the art"
      (doseq [i (range 0 16)]
       (is (= (str/trimr (nth page i)) (str/trimr (nth lines i)))))
      (doseq [i (range 17 24)]
       (is (= (str/trimr (subs (str (nth page i) (apply str (repeat 80 " "))) 0 49))
         (str/trimr (left i)))
        (str "row " i)))))))
  (testing "the lines of a page keep their width and nothing above the row"
   (let [page (:asset (get @#'main-menu/pages :page2))
     out (main-menu/blank-below-load page)]
    (is (= (count page) (count out)))
    (is (= (subvec page 0 16) (subvec out 0 16)))
    (is (every? #(str/blank? (subs % 49)) (subvec out 16)))))))

(deftest the-pages-and-the-lines-on-them
 (testing "the pages lead to new and load"
  (let [after @#'main-menu/page-after]
   (is (= :new-project (after :page1 KeyType/Enter)))
   (is (= :load-project (after :page2 KeyType/Enter)))
   (is (= :new-project (after :page4 \n))
    "n jumps to new and opens it from any page")
   (is (= :load-project (after :page1 \l)))
   (testing "the other parts are as they were"
    (is (= :goto-projects (after :page1 \o)))
    (is (= :settings (after :page1 \s)))
    (is (= :quit (after :page1 KeyType/Escape))))))

 (testing "lines on the page"
  (let [lines (:asset (get @#'main-menu/pages :page1))
    prompted (main-menu/with-prompt lines "name: abc_")
    told (main-menu/with-message lines "no projects to load!")]
   (testing
    "a prompt goes under new, with exit: esc below it, over a blank left side"
    (is (str/starts-with? (subs (nth prompted 16) 6) "name: abc_"))
    (is (str/starts-with? (subs (nth prompted 17) 6) "exit: esc"))
    (is (= (subvec (vec lines) 0 16) (subvec prompted 0 16)))
    (is (= (subs (nth lines 16) 0 6) (subs (nth prompted 16) 0 6)))
    (testing
     "open and help are blanked left of the fiftieth column, not the right side"
     (doseq [i (range 18 24)]
      (is (str/blank? (subs (nth prompted i) 0 49)) (str "row " i)))
     (is (str/blank? (subs (nth prompted 17) 15 49)))
     (doseq [i (range 17 24)]
      (let [pad #(subs (str % (apply str (repeat 80 " "))) 49 80)]
       (is (= (pad (nth lines i)) (pad (nth prompted i))) (str "row " i))))))
   (testing "a message goes under load, in the right column"
    (is (str/includes? (subs (nth told 16) 50) "no projects to load!"))
    (is (= (subs (nth told 16) 0 50)
      (subs (str (nth lines 16) (apply str (repeat 80 " "))) 0 50))))
   (testing "no message leaves the lines as they are"
    (is (= lines (main-menu/with-message lines nil))))
   (testing "a long message is cut at the width"
    (is (<= (count (nth (main-menu/with-message lines (apply str (repeat 60 "x")))
        16))
      79)))))

 (testing "what is typed as a name"
  (is (= "name: _" (main-menu/typed-name "")))
  (is (= "name: abc_" (main-menu/typed-name "abc")))
  (is (<= (count (main-menu/typed-name (apply str (repeat 60 "x")))) 40))
  (is (str/starts-with? (main-menu/typed-name (apply str (repeat 60 "x")))
    "name: …")))

 (testing "a key for typing keeps its case"
  (is (= \A (state/key->raw (KeyStroke. \A false false))))
  (is (= \a (state/key->raw (KeyStroke. \a false false))))
  (is (= \_ (state/key->raw (KeyStroke. \_ false false))))
  (is (= \space (state/key->raw (KeyStroke. \space false false))))
  (is (= :ctrl-x (state/key->raw (KeyStroke. \x true false))))
  (is (= KeyType/Enter (state/key->raw (KeyStroke. KeyType/Enter))))
  (is (= KeyType/ArrowUp (state/key->raw (KeyStroke. KeyType/ArrowUp))))
  (testing "while a key for the menus is lower case"
   (is (= \a (state/key->input (KeyStroke. \A false false))))))

 (testing "the release name is under the box that says main menu"
  (let [version (app/version-name)]
   (doseq [n (range 1 7)
     :let [page (:asset (get @#'main-menu/pages (keyword (str "page" n))))
      raw (pgld/load-ascii (str "page" n) "main-menu")]]
    (testing (str "page" n)
     (testing "the box keeps its label and its borders"
      (is (str/includes? (nth page 9) "main  menu"))
      (is (= (nth raw 9) (nth page 9)) "the row of the label is not touched")
      (doseq [i [7 8 10 11]] (is (= (nth raw i) (nth page i)) (str "row " i))))
     (testing "the name is under the box, from its left edge"
      (is (= 7 (str/index-of (nth page 12) version)))
      (is (= version (subs (nth page 12) 7 (+ 7 (count version))))))
     (testing "and stops before the box of the keys"
      (is (= (subs (nth raw 12) 42) (subs (nth page 12) 42)))
      (is (= " " (subs (nth page 12) (+ 7 (count version)) (+ 8 (count version))))))
     (testing "the rest of the page is the art"
      (doseq [i (remove #{12} (range (count raw)))]
       (is (= (nth raw i) (nth page i)) (str "row " i)))))))
  (testing "the longest name that `bb fmt` allows fits the room"
   (is (<= 35 (- 42 7))))))
