;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The file handling the EDN stores share: reading with a fallback or the unusable rule,
;; the text of a one-key map, and the atomic write.

(ns baysol.tui.edn-store-test
 (:require [baysol.tui.edn-store :as store]
  [baysol.tui.support :as support]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]]))

(def ^:private spec
 {:type ::bad,
  :name "x.edn",
  :expected "a map with a vector",
  :valid? #(vector? (:v % []))})

(defn ^:private thrown
 [f]
 (try (f)
  nil
  (catch clojure.lang.ExceptionInfo e [(ex-message e) (:type (ex-data e))])))

(deftest read-edn-test
 (let [dir (support/temp-root)
   f (io/file dir "a.edn")]
  (spit f "{:a 1}")
  (is (= {:a 1} (store/read-edn f :fallback)))
  (spit f "")
  (is (nil? (store/read-edn f :fallback)))
  (spit f ";; only a comment\n")
  (is (nil? (store/read-edn f :fallback)))
  (spit f "{:a")
  (is (= :fallback (store/read-edn f :fallback)))))

(deftest read-map-test
 (let [dir (support/temp-root)
   f (io/file dir "x.edn")]
  (is (= {} (store/read-map f spec)) "no file")
  (spit f "")
  (is (= {} (store/read-map f spec)) "no content")
  (spit f "{:v [1] :w 2}")
  (is (= {:v [1], :w 2} (store/read-map f spec)))
  (spit f "{:v")
  (is (= ["x.edn is not EDN" ::bad] (thrown #(store/read-map f spec))))
  (spit f "[1 2]")
  (is (= ["x.edn is not a map with a vector" ::bad]
    (thrown #(store/read-map f spec))))
  (spit f "{:v 3}")
  (is (= ["x.edn is not a map with a vector" ::bad]
    (thrown #(store/read-map f spec))))))

(deftest map-text-test
 (is (= "{:solutes\n []}\n" (store/map-text :solutes [] {})))
 (is (= "{:solutes\n [{:a 1}\n  {:b 2}]\n :k \"v\"}\n"
   (store/map-text :solutes ["{:a 1}" "{:b 2}"] {:k "v"}))))

(deftest write-atomic-test
 (let [dir (support/temp-root)
   f (io/file dir "sub" "w.edn")]
  (testing "folders are made and the file written"
   (is (= f (store/write-atomic! f "one")))
   (is (= "one" (slurp f))))
  (testing "an existing file is replaced and no temporary file stays"
   (store/write-atomic! f "two")
   (is (= "two" (slurp f)))
   (is (not (.exists (io/file dir "sub" "w.edn.tmp")))))))

(deftest copy-over-test
 (let [dir (support/temp-root)
   a (io/file dir "a")
   b (io/file dir "b")]
  (spit a "A")
  (spit b "B")
  (store/copy-over! a b)
  (is (= "A" (slurp b)))))

(deftest quarantine-test
 (let [dir (support/temp-root)
   f (io/file dir "a.edn")]
  (testing "no file, nothing done"
   (is (nil? (store/quarantine! f))))
  (testing "the file is renamed to .corrupt, the name is free"
   (spit f "broken (")
   (let [kept (store/quarantine! f)]
    (is (= (io/file dir "a.edn.corrupt") kept))
    (is (= "broken (" (slurp kept)))
    (is (not (.exists f)))))
  (testing "an older .corrupt is replaced"
   (spit f "second")
   (store/quarantine! f)
   (is (= "second" (slurp (io/file dir "a.edn.corrupt")))))))
