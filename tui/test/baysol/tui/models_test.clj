;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The models of a project: which files count, what a path must be, that adding copies and
;; never moves or overwrites, that deleting is limited to the models, and the hints.

(ns baysol.tui.models-test
 (:require [baysol.tui.models :as models]
  [baysol.tui.support :as support]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(defn ^:private file!
 "A file `fname` with `text` in the folder `dir`; returns its absolute path."
 [dir fname text]
 (let [f (io/file dir fname)]
  (io/make-parents f)
  (spit f text)
  (.getAbsolutePath f)))

(deftest accepted-files
 (is (every? models/accepted? ["a.cif" "a.pdb" "A.PDB" "x.y.Cif"]))
 (is (not-any? models/accepted? ["a.txt" "pdb" "a.pdbx" "a." ""])))

(deftest paths
 (let [src (support/temp-root)
   pdb (file! src "one.pdb" "ATOM")]
  (testing "a good path has no problem"
   (is (nil? (models/path-problem pdb []))))
  (testing "each problem is told"
   (is (= "type a path first!" (models/path-problem "  " [])))
   (is (= "use a full absolute path" (models/path-problem "one.pdb" [])))
   (is (= "no such file" (models/path-problem (str src "/none.pdb") [])))
   (is (= "that is a folder, not a file" (models/path-problem (str src) [])))
   (is (= "only .cif and .pdb files"
     (models/path-problem (file! src "n.txt" "x") [])))
   (is (= "a model with that name exists" (models/path-problem pdb ["ONE.pdb"])))
   (is (every? #(<= (count %) 42)
     ["use a full absolute path" "that is a folder, not a file"
      "a model with that name exists" "could not copy the file!"])))))

(deftest add-copies-and-never-moves
 (let [src (support/temp-root)
   project (support/temp-root)
   pdb (file! src "one.pdb" "ATOM")]
  (is (empty? (models/list-models project)) "no models/ folder: no models")
  (let [copy (models/add-model! project pdb)]
   (is (= "ATOM" (slurp copy)))
   (is (= (io/file project "models" "one.pdb") copy)))
  (is (.isFile (io/file pdb)) "the original is still there")
  (is (= ["one.pdb"] (models/list-models project)))
  (testing "a model is never overwritten"
   (spit pdb "CHANGED")
   (is (thrown? Exception (models/add-model! project pdb)))
   (is (= "ATOM" (slurp (io/file project "models" "one.pdb")))))))

(deftest adding-several
 (let [src (support/temp-root)
   project (support/temp-root)
   a (file! src "a.pdb" "A")
   b (file! src "sub/b.cif" "B")
   dup (file! src "sub/a.pdb" "other")
   txt (file! src "c.txt" "C")
   {:keys [copied skipped]} (models/add-models! project
    [a b dup txt
     (str src "/none.pdb")])]
  (is (= ["a.pdb" "b.cif"] copied))
  (is (= [dup txt (str src "/none.pdb")] (map first skipped)))
  (is (= ["a model with that name exists" "only .cif and .pdb files" "no such file"]
    (map second skipped)))
  (is (= "A" (slurp (io/file project "models" "a.pdb")))
   "the first one of a name wins")
  (is (every? #(.isFile (io/file %)) [a b dup txt]) "nothing was moved")
  (is (= {:copied [], :skipped []} (models/add-models! project [])))))

(deftest only-models-are-listed
 (let [project (support/temp-root)]
  (file! (models/models-dir project) "b.CIF" "x")
  (file! (models/models-dir project) "A.pdb" "x")
  (file! (models/models-dir project) "notes.txt" "x")
  (.mkdirs (io/file project "models" "dir.pdb"))
  (is (= ["A.pdb" "b.CIF"] (models/list-models project)))))

(deftest deleting
 (let [project (support/temp-root)
   outside (file! (support/temp-root) "keep.pdb" "x")]
  (file! (models/models-dir project) "a.pdb" "x")
  (file! (models/models-dir project) "b.cif" "x")
  (testing "only a model, by its plain name"
   (is (not (models/delete-model! project "../../nothing.pdb")))
   (is (not (models/delete-model! project (str "../" outside))))
   (is (not (models/delete-model! project "missing.pdb")))
   (is (.isFile (io/file outside))))
  (testing "a deleted model is gone, the others stay"
   (is (models/delete-model! project "a.pdb"))
   (is (= ["b.cif"] (models/list-models project))))
  (testing "deleting them all is the same as having had none"
   (is (models/delete-model! project "b.cif"))
   (is (= [] (models/list-models project)))
   (is (= [] (models/list-models (support/temp-root)))))))

(deftest hints-and-completion
 (let [dir (support/temp-root)]
  (.mkdirs (io/file dir "Sub"))
  (.mkdirs (io/file dir ".hidden"))
  (file! dir "alpha.pdb" "x")
  (file! dir "Beta.cif" "x")
  (file! dir "notes.txt" "x")
  (let [d (str dir "/")]
   (testing "folders first, then models, no other files, no dot names"
    (is (= ["Sub/" "alpha.pdb" "Beta.cif"] (models/hints d))))
   (testing "narrowed by what is typed, case does not matter"
    (is (= ["alpha.pdb"] (models/hints (str d "AL"))))
    (is (= ["Sub/"] (models/hints (str d "su"))))
    (is (= [".hidden/"] (models/hints (str d "."))))
    (is (= [] (models/hints (str d "zzz")))))
   (testing "no hints without an absolute path in a folder that exists"
    (is (= [] (models/hints "")))
    (is (= [] (models/hints "alpha")))
    (is (= [] (models/hints "/no/such/folder/x"))))
   (testing "hints-for takes any predicate on the file name"
    (is (= ["Sub/" "notes.txt"]
      (models/hints-for d #(str/ends-with? % ".txt"))))
    (is (= ["Sub/"] (models/hints-for d (constantly false))))
    (is (= (models/hints d) (models/hints-for d models/accepted?))))
   (testing "completion replaces the last part"
    (is (= (str d "alpha.pdb") (models/complete (str d "al") "alpha.pdb")))
    (is (= (str d "Sub/") (models/complete d "Sub/")))
    (is (str/starts-with? (models/complete (str d "al") "alpha.pdb") (str dir)))))))
