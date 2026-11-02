;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The projects: which names are allowed, what makes a folder a project, and what making
;; one does, on synthetic projects folders.

(ns baysol.tui.projects-test
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.projects :as projects]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]]))









(deftest what-is-a-project
 (testing "what is a project"
  (let [root (support/temp-root)
    make! (fn [dir-name text]
     (let [d (io/file root dir-name)]
      (.mkdirs d)
      (when text (spit (io/file d "project.edn") text))
      d))]
   (make! "good" (pr-str {:id "good", :created "2026-11-01T00:00:00Z"}))
   (make! "Alpha" (pr-str {:id "Alpha"}))
   (make! "wrong-id" (pr-str {:id "someone-else"}))
   (make! "no-id" (pr-str {:created "x"}))
   (make! "not-edn" "{ nonsense")
   (make! "not-a-map" "[1 2 3]")
   (make! "no-file" nil)
   (make! "empty" "")
   (spit (io/file root "loose-file.txt") "a file is no project")
   (testing "only a folder with a project.edn of its own id is a project, sorted"
    (is (= ["Alpha" "good"] (projects/list-projects root))))
   (testing "every name in the folder is taken, a project or not"
    (is (= #{"good" "Alpha" "wrong-id" "no-id" "not-edn" "not-a-map" "no-file"
       "empty"
       "loose-file.txt"}
      (set (projects/entry-names root)))))
   (testing "reading a project"
    (is (= "good" (:id (projects/read-project (io/file root "good")))))
    (is (nil? (projects/read-project (io/file root "wrong-id"))))
    (is (nil? (projects/read-project (io/file root "not-edn"))))
    (is (nil? (projects/read-project (io/file root "missing")))))))

 (testing "no projects folder is no projects"
  (let [root (io/file (support/temp-root) "nowhere")]
   (is (= [] (projects/list-projects root)))
   (is (= [] (projects/entry-names root))))))









(deftest making-a-project
 (testing "making a project"
  (let [root (support/temp-root)
    dir (projects/create! root "first")]
   (testing "a folder named by the id, in the projects folder"
    (is (= (io/file (app/projects-root root) "first") dir))
    (is (.isDirectory dir)))
   (testing "a project.edn that names it"
    (let [p (edn/read-string (slurp (io/file dir "project.edn")))]
     (is (= "first" (:id p)))
     (is (string? (:created p)))
     (is (= p (projects/read-project dir)))))
   (testing "an exact copy of the global settings"
    (is (= (slurp (settings/settings-file root))
      (slurp (settings/settings-file dir)))))
   (testing "it is listed"
    (is (= ["first"] (projects/list-projects (app/projects-root root)))))
   (testing "a second project is another folder with the same settings copy"
    (let [other (projects/create! root "second")]
     (is (= ["first" "second"] (projects/list-projects (app/projects-root root))))
     (is (= (slurp (settings/settings-file dir))
       (slurp (settings/settings-file other))))))))

 (testing "the copy has the global settings as they are now"
  (let [root (support/temp-root)]
   (settings/load! root)
   (settings/save! root :sampler "N_ADAPT" 450)
   (settings/save! root :plots "PLOT_COLOUR_MAP" :darkorange)
   (let [dir (projects/create! root "p")
     loaded (settings/load-project! dir root)]
    (is (= (slurp (settings/settings-file root))
      (slurp (settings/settings-file dir))))
    (is (= 450 (settings/value (get-in loaded [:sampler "N_ADAPT"]))))
    (is (= :darkorange
      (settings/value (get-in loaded [:plots "PLOT_COLOUR_MAP"])))))))

 (testing "a name that is not valid or is taken makes nothing"
  (let [root (support/temp-root)
    projects-root (app/projects-root root)]
   (projects/create! root "taken")
   (doseq [bad ["" "has space" "a/b" "con" "name." (apply str (repeat 41 "x"))
      "taken" "TAKEN"]]
    (let [e (try (projects/create! root bad) nil (catch Exception e e))]
     (is (some? e) (pr-str bad))
     (is (= ::projects/invalid-name (:type (ex-data e))) (pr-str bad))
     (is (string? (:reason (ex-data e))))))
   (is (= ["taken"] (vec (projects/entry-names projects-root)))
    "no folder was made")))

 (testing "a project that fails half way is removed"
  (let [root (support/temp-root)]
   (with-redefs [settings/settings-file
     (let [real settings/settings-file]
      (fn [d]
       (if (= "broken" (.getName (io/file d)))
        (io/file d "no" "such" "folder" "settings.edn") ; the copy cannot be written
        (real d))))]
    (is (thrown? Exception (projects/create! root "broken"))))
   (is (not (.exists (io/file (app/projects-root root) "broken"))))
   (testing "and the name is free again"
    (is (nil? (projects/name-problem "broken"
       (projects/entry-names (app/projects-root
         root))))))))

 (testing "a project is refused when the global settings cannot be made"
  (let [root (support/temp-root)]
   (binding [settings/*regenerate* (constantly false)
     settings/*read* (fn [] [{} []])]
    (is (thrown? clojure.lang.ExceptionInfo (projects/create! root "p"))))
   (is (not (.exists (io/file (app/projects-root root) "p")))))))

(deftest project-names
 (testing "good names"
  (doseq [n ["a" "A" "1" "run1" "My_Project" "my-project" "my.project" "x.y.z"
     "2026-11-01"
     "sasdmj9" "SASDMJ9_fit1" (apply str (repeat 40 "a")) "a--b" "a__b"
     "9lives"
     "console" "communicate" "auxiliary" "lpt10" "com10"]]
   (is (nil? (projects/name-problem n [])) n)))

 (testing "bad names"
  (doseq [[n message]
    [["" "type a name first!"] ["   " "type a name first!"]
     [(apply str (repeat 41 "a")) "name too long (40 at most)"]
     [(apply str (repeat 200 "a")) "name too long (40 at most)"]
     ["has space" "use only a-z 0-9 . _ -"]
     ["a/b" "use only a-z 0-9 . _ -"]
     ["a\\b" "use only a-z 0-9 . _ -"]
     ["../up" "use only a-z 0-9 . _ -"]
     [".hidden" "start with a letter or digit"]
     ["-dash" "start with a letter or digit"]
     ["_under" "start with a letter or digit"]
     ["na:me" "use only a-z 0-9 . _ -"]
     ["na*me" "use only a-z 0-9 . _ -"]
     ["na?me" "use only a-z 0-9 . _ -"]
     ["é" "use only a-z 0-9 . _ -"]
     ["name\n" "use only a-z 0-9 . _ -"]
     ["tab\tname" "use only a-z 0-9 . _ -"]
     ["a~b" "use only a-z 0-9 . _ -"]
     [".." "start with a letter or digit"]
     ["." "start with a letter or digit"]
     ["name." "must not end with a dot"]
     ["a.." "must not end with a dot"]
     ["con" "reserved name, pick another"]
     ["CON" "reserved name, pick another"]
     ["Nul" "reserved name, pick another"]
     ["aux" "reserved name, pick another"]
     ["prn" "reserved name, pick another"]
     ["com1" "reserved name, pick another"]
     ["COM9" "reserved name, pick another"]
     ["lpt1" "reserved name, pick another"]
     ["con.txt" "reserved name, pick another"]
     ["nul.x.y" "reserved name, pick another"]]]
   (is (= message (projects/name-problem n [])) (pr-str n))
   (is (<= (count message) 29) "the message fits the main menu")))

 (testing "a name that is taken is refused whatever its case"
  (is (= "that project already exists!" (projects/name-problem "run" ["run"])))
  (is (= "that project already exists!" (projects/name-problem "Run" ["run"])))
  (is (= "that project already exists!"
    (projects/name-problem "RUN" ["Run" "other"])))
  (is (nil? (projects/name-problem "run2" ["run" "other"])))
  (testing "a file or a folder that is no project takes its name too"
   (is (= "that project already exists!"
     (projects/name-problem "notes.txt" ["notes.txt"]))))
  (testing "a bad name is told before it is told to be taken"
   (is (= "must not end with a dot" (projects/name-problem "run." ["run."])))))

 (testing "many names"
  (testing
   "every name of a thousand made-up ones is judged, and a good one is never refused
          for its look alone"
   (let [rng (java.util.Random. 7)
     alphabet (vec "abcXYZ019_-. /\\:é*")
     names (repeatedly
      1000
      #(apply str
       (repeatedly
        (inc (.nextInt rng 12))
        (fn [] (nth alphabet (.nextInt rng (count alphabet)))))))]
    (doseq [n names
      :let [problem (projects/name-problem n [])]]
     (if (re-matches #"[A-Za-z0-9][A-Za-z0-9_.-]*" n)
      (is (or (nil? problem)
        (#{"must not end with a dot" "reserved name, pick another"} problem))
       n)
      (is (some? problem) n))
     (when problem
      (is (<= (count problem) 29) "a message that fits the main menu")))))))
