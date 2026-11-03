;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The draft state the tables of the solutes, the custom solutes and the recipes share.

(ns baysol.tui.draft-test
 (:require [baysol.tui.draft :as draft]
  [baysol.tui.limits :as limits]
  [clojure.test :refer [deftest is testing]]))

(defn ^:private marks [s] (mapv draft/mark (:rows s)))

(deftest saved-rows-are-clean
 (let [s (draft/initial [:a :b])]
  (is (= [nil nil] (marks s)))
  (is (= [:a :b] (mapv draft/value (:rows s))))
  (is (not (draft/dirty? s)))
  (is (= {:rows []} (draft/initial [])))))

(deftest drafts-marks-and-undo
 (let [s (-> (draft/initial [:a :b])
    (draft/set-draft 0 :a2)
    (draft/add-draft :c)
    (draft/add-drafts [:d :e]))]
  (is (= [\* nil \* \* \*] (marks s)))
  (is (= [:a2 :b :c :d :e] (mapv draft/value (:rows s))))
  (is (draft/dirty? s))
  (testing "set back to what was saved: no draft"
   (is (= [nil nil] (marks (draft/set-draft (draft/initial [:a :b]) 0 :a)))))
  (testing "undo of a draft, of a new row (it goes)"
   (is (= [nil nil \* \* \*] (marks (draft/undo s 0))))
   (is (= [:a2 :b :d :e] (mapv draft/value (:rows (draft/undo s 2))))))
  (testing "removal of a saved row is a mark, undo brings it back"
   (let [r (draft/remove-row s 1)]
    (is (= [\* \- \* \* \*] (marks r)))
    (is (= [:a2 :c :d :e] (draft/to-save (draft/remove-row s 1)))
     "to-save skips it")
    (is (= [\* nil \* \* \*] (marks (draft/undo r 1))))))
  (testing "removal of a row that was never saved is at once"
   (is (= 4 (count (:rows (draft/remove-row s 2))))))
  (testing "commit drops the removed rows and cleans the others"
   (let [c (draft/commit (draft/remove-row s 1))]
    (is (= [nil nil nil nil] (marks c)))
    (is (= [:a2 :c :d :e] (mapv draft/value (:rows c))))))))

(deftest drop-row-test
 (is (= [:a :c]
   (mapv draft/value (:rows (draft/drop-row (draft/initial [:a :b :c]) 1)))))
 (is (= [:b :c]
   (mapv draft/value (:rows (draft/drop-row (draft/initial [:a :b :c]) 0))))))

(deftest room-test
 (is (draft/room? (draft/initial (range (dec limits/max-rows)))))
 (is (not (draft/room? (draft/initial (range limits/max-rows)))))
 (is (draft/room? {:rows []})))
