;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The solutes being edited (drafts, removals, what is saved) and the buffer file.

(ns baysol.tui.solutes-test
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.solutes :as solutes]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]]))

(def ^:private nacl
 {:kind :nonbiological, :name "NaCl", :arg "NaCl", :mM 200.0, :sigma-mM 10.0})

(def ^:private tris
 {:kind :nonbiological, :name "tris", :arg "tris", :mM 10.0, :sigma-mM 0.5})

(defn ^:private marks [s] (mapv solutes/mark (:rows s)))

(deftest drafts-and-removals
 (let [s (solutes/initial [nacl tris])]
  (is (= [nil nil] (marks s)))
  (is (not (solutes/dirty? s)))
  (testing "an edit is a draft, set back to what was saved it is none"
   (let [e (solutes/set-field s 0 :mM 150.0)]
    (is (= [\* nil] (marks e)))
    (is (= 150.0 (:mM (solutes/value (first (:rows e))))))
    (is (= [nil nil] (marks (solutes/set-field e 0 :mM 200.0))))
    (is (= [nil nil] (marks (solutes/undo e 0))))))
  (testing "the name is a label: the arg stays"
   (let [row (solutes/value (first (:rows (solutes/set-field s 0 :name "KCl"))))]
    (is (= "KCl" (:name row)))
    (is (= "NaCl" (:arg row)))))
  (testing "a whole solute can be set, and set back"
   (let [e (solutes/set-solute s 0 tris)]
    (is (= tris (solutes/value (first (:rows e)))))
    (is (= [\* nil] (marks e)))
    (is (= [nil nil] (marks (solutes/set-solute e 0 nacl))))))
  (testing "rows can be appended as drafts and the new ones dropped by index"
   (let [a (solutes/append-solutes s [tris tris])]
    (is (= [nil nil \* \*] (marks a)))
    (is (= [nil nil \*] (marks (solutes/drop-new-rows a [2]))))
    (is (= [nil nil] (marks (solutes/drop-new-rows a [2 3]))))
    (is (= [nil nil] (marks (solutes/drop-new-rows s [0 1]))) "saved rows stay")))
  (testing
   "a new row is marked, and goes with undo or remove, with nothing to confirm"
   (let [a (solutes/add-row s)]
    (is (= [nil nil \*] (marks a)))
    (is (= 2 (count (:rows (solutes/undo a 2)))))
    (is (= 2 (count (:rows (solutes/remove-row a 2)))))))
  (testing
   "a saved row is only marked to go; undo brings it back, a draft comes after"
   (let [r (solutes/remove-row (solutes/set-field s 1 :mM 11.0) 1)]
    (is (= [nil \-] (marks r)))
    (is (= [nil \*] (marks (solutes/undo r 1))))
    (is (= [nil nil] (marks (solutes/undo (solutes/undo r 1) 1))))))
  (testing "a save drops the removed rows and keeps the rest as they are"
   (let [r (-> s
      (solutes/remove-row 0)
      (solutes/set-field 1 :mM 11.0))]
    (is (= [(assoc tris :mM 11.0)] (solutes/to-save r)))
    (let [c (solutes/commit r)]
     (is (= [nil] (marks c)))
     (is (not (solutes/dirty? c))))))))

(deftest what-is-missing
 (is (nil? (solutes/problem nacl)))
 (is (= "name needed" (solutes/problem (assoc nacl :name " "))))
 (is (= "mM must be > 0" (solutes/problem (assoc nacl :mM nil))))
 (is (= "mM must be > 0" (solutes/problem (assoc nacl :mM 0.0))))
 (is (= "±mM needed" (solutes/problem (assoc nacl :sigma-mM nil))))
 (is (nil? (solutes/problem (assoc nacl :sigma-mM 0.0))))
 (testing "the first row that stays is told, a removed one is not"
  (let [s (-> (solutes/initial [nacl tris])
     (solutes/add-row)
     (solutes/set-field 2 :name "x"))]
   (is (= [2 "mM must be > 0"] (solutes/problems s)))
   (is (nil? (solutes/problems (solutes/remove-row s 2)))))))

(def ^:private fixture-file (io/file "../test/fixtures/buffer/buffer.edn"))

(def ^:private fixture (:solutes (edn/read-string (slurp fixture-file))))

(deftest every-kind-is-valid
 (is (= #{:nonbiological :polymer :dna :rna :protein :custom-nonbio :custom-polymer}
   (set (map :kind fixture)))
  "the fixture has a row of every kind")
 (is (= 11 (count fixture)))
 (doseq [row fixture]
  (is (nil? (buffer/row-problem row)) (str (:name row))))
 (testing "what each kind needs, as the Julia loader wants it"
  (let [row (fn [n] (nth fixture n))]
   (is (= "unknown :kind" (buffer/row-problem (assoc nacl :kind :other))))
   (is (= "a row is not a map" (buffer/row-problem 1)))
   (is (= ":mM must be above 0" (buffer/row-problem (assoc nacl :mM 0.0))))
   (is (= ":mM must be above 0" (buffer/row-problem (dissoc nacl :mM))))
   (is (= ":sigma-mM must be 0 or more"
     (buffer/row-problem (assoc nacl :sigma-mM -1.0))))
   (is (= ":sigma-mM must be 0 or more"
     (buffer/row-problem (assoc nacl :sigma-mM nil))))
   (is (nil? (buffer/row-problem (assoc nacl :sigma-mM 0))))
   (testing ":arg for the kinds that have one"
    (doseq [n [0 1 2 3 4 5 6]]
     (is (= ":arg must be a name" (buffer/row-problem (assoc (row n) :arg " "))))
     (is (= ":arg must be a name" (buffer/row-problem (dissoc (row n) :arg))))))
   (testing "a custom non-biological row"
    (is (= ":z must be an integer" (buffer/row-problem (assoc (row 7) :z 1.5))))
    (is (= ":z must be an integer" (buffer/row-problem (assoc (row 7) :z nil))))
    (is (= ":pmv must be a number" (buffer/row-problem (assoc (row 7) :pmv "1"))))
    (is (= ":custom must be a name" (buffer/row-problem (dissoc (row 7) :custom))))
    (is (= ":sigma-pmv must be a number or nil"
      (buffer/row-problem (dissoc (row 7) :sigma-pmv))))
    (is (nil? (buffer/row-problem (assoc (row 7) :sigma-pmv nil)))))
   (testing "a custom polymer row"
    (let [p (row 10)]
     (is (= ":units needs 1 to 4" (buffer/row-problem (assoc p :units []))))
     (is (= ":units needs 1 to 4"
       (buffer/row-problem (assoc p
         :units (vec (repeat 5 (first (:units p))))
         :counts (vec (repeat 5 1.0))))))
     (is (= ":counts needs one per unit"
       (buffer/row-problem (assoc p :counts [1.0]))))
     (is (= ":counts must be numbers" (buffer/row-problem (assoc p :counts nil))))
     (is (= "unit :z must be an integer"
       (buffer/row-problem (assoc-in p [:units 0 :z] 1.5))))
     (is (= "unit :slope must be a number"
       (buffer/row-problem (assoc-in p [:units 0 :slope] nil))))
     (is (= "unit :sigma must be a number or nil"
       (buffer/row-problem (update-in p [:units 0] dissoc :sigma))))
     (is (= ":z-ends must be an integer"
       (buffer/row-problem (assoc p :z-ends nil))))
     (is (= ":pmv-ends must be a number"
       (buffer/row-problem (assoc p :pmv-ends nil))))
     (is (= ":sigma-ends must be a number or nil"
       (buffer/row-problem (dissoc p :sigma-ends))))))))
 (testing "a row that is not complete is told at save"
  (is (= "row incomplete" (solutes/problem (assoc nacl :arg ""))))
  (is (= "name needed" (solutes/problem (assoc nacl :name ""))))))

(deftest the-fixture-round-trips
 (support/with-data-folder
  [_root (support/temp-root)]
  (let [dir (support/temp-root)
    file (buffer/buffer-file dir)]
   (io/copy fixture-file file)
   (testing "the buffer reader reads the fixture, comments and all"
    (is (= fixture (buffer/read-solutes dir))))
   (testing "written and read back, it equals itself"
    (buffer/write-solutes! dir fixture)
    (is (= fixture (buffer/read-solutes dir)))
    (is (= fixture (:solutes (edn/read-string (slurp file))))))
   (testing "the state keeps and saves every kind as it is"
    (let [s (solutes/initial (buffer/read-solutes dir))]
     (is (= fixture (solutes/to-save s)))
     (is (nil? (solutes/problems s)))))
   (testing
    "a row the loader would refuse makes the file unusable, and is not written"
    (let [text (slurp file)
      broken (assoc-in fixture [10 :counts] [1.0])]
     (is (thrown? clojure.lang.ExceptionInfo (buffer/write-solutes! dir broken)))
     (is (= text (slurp file)) "the file was left alone")
     (spit file (pr-str {:solutes broken}))
     (is (thrown? clojure.lang.ExceptionInfo (buffer/read-solutes dir)))
     (is (thrown? clojure.lang.ExceptionInfo (buffer/write-solutes! dir [nacl])))
     (is (= (pr-str {:solutes broken}) (slurp file))))))))

(deftest the-buffer-file
 (support/with-data-folder
  [_root (support/temp-root)]
  (let [dir (support/temp-root)
    file (buffer/buffer-file dir)]
   (testing "no file, an empty one or one with only a comment: no solutes"
    (is (= [] (buffer/read-solutes dir)))
    (spit file "")
    (is (= [] (buffer/read-solutes dir)))
    (spit file ";; nothing yet\n")
    (is (= [] (buffer/read-solutes dir))))
   (testing "written, then read back, and other keys stay"
    (spit file "{:solutes [] :ph 7.5}")
    (buffer/write-solutes! dir [nacl tris])
    (is (= [nacl tris] (buffer/read-solutes dir)))
    (is (= 7.5 (:ph (edn/read-string (slurp file))))))
   (testing "no temporary file is left"
    (is (not (.exists (io/file dir "buffer.edn.tmp")))))
   (testing "a file that cannot be used is told and never written over"
    (doseq [text ["{:solutes" "[1 2]" "{:solutes 3}" "{:solutes [1]}"]]
     (spit file text)
     (is (thrown? clojure.lang.ExceptionInfo (buffer/read-solutes dir)))
     (is (thrown? clojure.lang.ExceptionInfo (buffer/write-solutes! dir [nacl])))
     (is (= text (slurp file))))))))
