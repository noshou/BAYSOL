;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The project menu and the menu of the settings of a project: what maps
;; where, read against the art (where the cursor is, which arrows the footer
;; shows), and the menus run for real on a virtual screen with keys fed to it.

(ns baysol.tui.screens.project-menu-test
 (:require [baysol.tui.projects :as projects]
  [clojure.java.io :as io]
  [baysol.tui.runs :as runs]
  [baysol.tui.screens.project-menu :as project-menu]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :as support :refer [background]]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))


(def ^:private keys-of
 {:up KeyType/ArrowUp,
  :down KeyType/ArrowDown,
  :left KeyType/ArrowLeft,
  :right KeyType/ArrowRight,
  :enter KeyType/Enter})

;; the grid of the project menu, page by page: [row column] of the cursor box, 3 x 2
(def ^:private grid
 {:page1 [0 0],
  :page2 [0 1],
  :page3 [1 0],
  :page4 [1 1],
  :page5 [2 0],
  :page6 [2 1]})

(defn ^:private lines-of [page] (get-in project-menu/pages [page :asset]))

(defn ^:private arrows
 "The arrows the footer of the page shows beside `move:`, as a set of directions."
 [lines]
 (let [move-line (first (keep-indexed #(when (str/includes? %2 "move:") %1) lines))
   at #(nth lines % "")]
  (cond-> #{}
   (str/includes? (at (dec move-line)) "↑") (conj :up)
   (str/includes? (at (inc move-line)) "↓") (conj :down)
   (str/includes? (at move-line) "←") (conj :left)
   (str/includes? (at move-line) "→") (conj :right))))

(defn ^:private cursor
 "Where the cursor box is on the page `lines`: `[row column]` of the 3 x 2 grid."
 [lines]
 (let [i (first (keep-indexed #(when (str/includes? %2 "│ > │") %1) lines))
   column (str/index-of (nth lines i) "│ > │")]
  [(case i
    14 0
    18 1
    22 2
    nil) (if (< column 20) 0 1)]))

(defn ^:private direction-of
 "The directions that lead from grid place `from` to a neighbour, with that neighbour."
 [[row column] direction]
 (case direction
  :up [(dec row) column]
  :down [(inc row) column]
  :left [row (dec column)]
  :right [row (inc column)]))











(deftest the-project-menu-pages-and-keys
 (testing "the cursor of every page is on its own place of the grid"
  (is (= grid (into {} (for [page (keys grid)] [page (cursor (lines-of page))])))))

 (testing "every page leads to its neighbour in the grid"
  (let [page-at (into {} (map (fn [[page p]] [p page]) grid))]
   (doseq [[page here] grid
     direction [:up :down :left :right]
     :let [there (direction-of here direction)
      expected (page-at there)]]
    (is (= (or expected page)
      (project-menu/page-after page (keys-of direction)))
     (str page " " direction)))))

 (testing "the arrows of the footers are the links except where the art is wrong"
  (let [links (fn [page]
     (set (filter #(not= page (project-menu/page-after page (keys-of %)))
       [:up :down :left :right])))]
   (doseq [page [:page2 :page3 :page4 :page5 :page6]]
    (is (= (links page) (arrows (lines-of page))) (str page)))
   (testing
    "the footer of the models page (top left) shows an up arrow where it has no
           neighbour, and no down one; the table follows the grid. If the art is fixed
           this should be #{:right :down}"
    (is (= #{:right :down} (links :page1)))
    (is (= #{:up :right} (arrows (lines-of :page1)))))))

 (testing "enter opens models, settings, data and logs and the rest stay"
  (is (= :models (project-menu/page-after :page1 KeyType/Enter)))
  (is (= :data (project-menu/page-after :page2 KeyType/Enter)))
  (is (= :logs (project-menu/page-after :page4 KeyType/Enter)))
  (is (= :buffer (project-menu/page-after :page3 KeyType/Enter)))
  (is (= :settings (project-menu/page-after :page5 KeyType/Enter)))
  (doseq [page [:page6]]
   (is (= page (project-menu/page-after page KeyType/Enter))
    (str page " is a no-op"))))

 (testing "hotkeys and the other keys"
  (doseq [page (keys grid)]
   (is (= :models (project-menu/page-after page \m)))
   (is (= :data (project-menu/page-after page \d)))
   (is (= :buffer (project-menu/page-after page \b)))
   (is (= :logs (project-menu/page-after page \g)))
   (is (= :settings (project-menu/page-after page \s)))
   (is (= :page6 (project-menu/page-after page \r)))
   (is (= :back (project-menu/page-after page :ctrl-x)))
   (is (= :quit (project-menu/page-after page KeyType/Escape)))
   (is (= :quit (project-menu/page-after page KeyType/EOF)))
   (is (every? #(= page (project-menu/page-after page %))
     [:ctrl-w :ctrl-m \x \q KeyType/Backspace]))))

 (testing "every page says project menu"
  (doseq [page (keys grid)]
   (is (some #(str/includes? % "project menu") (lines-of page)))
   (is (some #(str/includes? % "main menu: ctrl+x") (lines-of page)))
   (is (= 24 (count (lines-of page))) (str page " is 24 lines")))))

;; --- the menu of the settings of a project

(def ^:private settings-links
 {:page1 {:right :page4, :down :page2, :enter :output},
  :page2 {:up :page1, :right :page3, :enter :sampler},
  :page3 {:up :page4, :left :page2, :enter :plots},
  :page4 {:left :page1, :down :page3, :enter :model}})



;; --- running them

(defn ^:private project!
 "A project `id` in the BAYSOL folder `root`: its folder."
 [root id]
 (projects/create! root id))



(deftest the-project-menus-run
 (testing "the project settings menu leads where the global one does"
  (doseq [[page expected] settings-links
    direction [:up :down :left :right :enter]]
   (is (= (get expected direction page)
     (settings-menu/page-after settings-menu/project-pages
      page
      (keys-of direction)))
    (str page " " direction)))
  (doseq [page (keys settings-links)]
   (is (= :back
     (settings-menu/page-after settings-menu/project-pages page :ctrl-x)))
   (is
    (=
     :quit
     (settings-menu/page-after settings-menu/project-pages page KeyType/Escape))))
  (testing "its art is its own, and says so"
   (doseq [[page {:keys [asset]}] settings-menu/project-pages]
    (is (some #(str/includes? % "project settings") asset) (str page)))
   (is (not-any? #(str/includes? % "project settings")
     (mapcat :asset (vals settings-menu/pages))))))

 (testing "the project menu runs"
  (support/with-data-folder
   [root (support/temp-root)]
   (let [dir (project! root "demo")]
    (testing "ctrl-x goes back to the main menu"
     (let [vs (support/virtual-screen)]
      (support/feed! vs :ctrl-x)
      (is (= :back (project-menu/show! (:screen vs) background dir)))
      (is (some #(str/includes? % "project menu") (support/screen-lines vs)))))
    (testing "escape quits the program"
     (let [vs (support/virtual-screen)]
      (support/feed! vs KeyType/Escape)
      (is (= :quit (project-menu/show! (:screen vs) background dir)))))
    (testing
     "the parts that do nothing yet and the notes: the menu is still there to leave"
     (let [vs (support/virtual-screen)]
      (support/feed! vs
       "rgd"
       KeyType/Enter
       KeyType/ArrowDown
       KeyType/Enter
       :ctrl-x)
      (is (= :back (project-menu/show! (:screen vs) background dir)))))
    (testing
     "buffer opens the buffer landing; ctrl-x there comes back to the project menu"
     (let [vs (support/virtual-screen)]
      (support/feed! vs \b :ctrl-x :ctrl-x)
      (is (= :back (project-menu/show! (:screen vs) background dir)))
      (is (some #(str/includes? % "project menu") (support/screen-lines vs))))
     (let [vs (support/virtual-screen)]
      (support/feed! vs KeyType/ArrowDown KeyType/Enter KeyType/EOF)
      (project-menu/show! (:screen vs) background dir)
      (is (some #(str/includes? % "buffer · demo") (support/screen-lines vs))
       "Enter on buffer shows the landing, not the table"))
     (let [vs (support/virtual-screen)]
      (support/feed! vs \b KeyType/Escape)
      (is (= :quit (project-menu/show! (:screen vs) background dir)))))
    (testing "logs and data with no runs say so, and the note goes at the next key"
     (doseq [[k folder] [[\g "logs"] [\d "data"]]]
      (is (not (.exists (io/file dir folder))) "a new project has no logs or data")
      (let [vs (support/virtual-screen)]
       (support/feed! vs k)
       (let [f (future (project-menu/show! (:screen vs) background dir))]
        (Thread/sleep 300)
        (is (str/includes? (support/screen-text vs) "no runs exist!") folder)
        (support/feed! vs :ctrl-x)
        (is (= :back (deref f 2000 :timeout)))))))
    (testing "with runs, data and logs open a dropdown of them; escape closes it"
     (let [{:keys [id]} (runs/record-run! dir
        {:models ["m"],
         :output-dir (support/temp-root)})]
      (doseq [k [\d \g]]
       (let [vs (support/virtual-screen)]
        (support/feed! vs k)
        (let [f (future (project-menu/show! (:screen vs) background dir))]
         (Thread/sleep 300)
         (is (str/includes? (support/screen-text vs) "find:") (str k))
         (is (str/includes? (support/screen-text vs)
           (subs id 0 (min 19 (count id))))
          (str k))
         (support/feed! vs KeyType/Escape)
         (Thread/sleep 200)
         (is (not (str/includes? (support/screen-text vs) "find:")) (str k))
         (support/feed! vs :ctrl-x)
         (is (= :back (deref f 2000 :timeout))))))))
    (testing "arrows move the cursor: the page shown has the cursor where it went"
     (let [vs (support/virtual-screen)]
      (support/feed! vs
       KeyType/ArrowDown
       KeyType/ArrowRight
       KeyType/ArrowDown
       :ctrl-x)
      (project-menu/show! (:screen vs) background dir)
      (let [art (:asset (get project-menu/pages :page6))]
       (is (= (map str/trimr art)
         (map str/trimr (take (count art) (support/screen-lines vs))))
        "ends on the run page, bottom right")))))))

 (testing "the settings of a project open from its menu"
  (support/with-data-folder
   [root (support/temp-root)]
   (settings/load! root)
   (settings/save! root :sampler "N_ADAPT" 450)
   (let [dir (project! root "demo")]
    (testing "s opens the project settings menu, which says so; ctrl-x comes back"
     (let [vs (support/virtual-screen)]
      (support/feed! vs \s :ctrl-x :ctrl-x)
      (is (= :back (project-menu/show! (:screen vs) background dir)))))
    (testing
     "the sampler sheet shows the value the project started with; ctrl-x, ctrl-x, esc"
     (let [vs (support/virtual-screen)]
      (support/feed! vs \s \a)
      (future (Thread/sleep 400) (support/feed! vs :ctrl-x :ctrl-x KeyType/Escape))
      (is (= :quit (project-menu/show! (:screen vs) background dir)))))
    (testing
     "a value edited in the project is saved in the project, not in the global file"
     (let [vs (support/virtual-screen)
       global-before (slurp (settings/settings-file root))]
      (support/feed! vs \s \a KeyType/Enter)
      (support/feed! vs
       KeyType/Backspace
       KeyType/Backspace
       KeyType/Backspace
       "600" KeyType/Enter
       :ctrl-w :ctrl-x
       :ctrl-x KeyType/Escape)
      (is (= :quit (project-menu/show! (:screen vs) background dir)))
      (is (= 600
        (settings/value (get-in (settings/load-project! dir root)
          [:sampler "N_ADAPT"]))))
      (is (= 450
        (settings/value (get-in (settings/load! root) [:sampler "N_ADAPT"]))))
      (is (= global-before (slurp (settings/settings-file root))))))))))

(deftest a-project-whose-settings-were-unreadable-says-so-once
 (support/with-data-folder
  [root (support/temp-root)]
  (let [dir (projects/create! root "demo")
    file (settings/settings-file dir)
    show (fn [& ks]
     (let [vs (support/virtual-screen)
       f (future (project-menu/show! (:screen vs) background dir))]
      (apply support/feed! vs ks)
      [(deref f 5000 :timeout) (support/screen-text vs)]))]
   (testing "a project with readable settings opens with no note"
    (let [[r text] (show :ctrl-x)]
     (is (= :back r))
     (is (not (str/includes? text "unreadable")))))
   (spit file "{:output (")
   (testing "the box says what happened; a key closes it and the menu is there"
    (let [[r text] (show KeyType/EOF)]
     (is (= :quit r))
     (is (str/includes? text "settings.edn was unreadable"))
     (is (str/includes? text "old file kept as settings.edn.corrupt")))
    (is (= "{:output (" (slurp (io/file dir "settings.edn.corrupt")))
     "the old file is kept")
    (is (str/includes? (slurp file) ":output") "and the settings are the new ones"))
   (testing "any key closes the box, and the menu is there"
    (spit file "{:output (")
    (is (= :back (first (show :ctrl-x :ctrl-x)))))
   (testing "it is said once: the file was replaced"
    (let [[r text] (show :ctrl-x)]
     (is (= :back r))
     (is (not (str/includes? text "unreadable"))))))))
