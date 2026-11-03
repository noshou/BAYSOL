;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of dev/harvest_pmv_mean.clj: the mean skips null uncertainties and is rounded to
;; six decimals, the literal between the markers is replaced (and only it), a second
;; replacement changes nothing, and missing markers are an error. The file of the real
;; module is not touched.

(ns harvest-pmv-mean-test
 (:require [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]
  [harvest-pmv-mean :as h]))

(def ^:private module-text
 (str/join "\n"
  ["module M"
   "# BEGIN harvested: nonbio-mean-uncertainty"
   "const NONBIO_MEAN_UNCERTAINTY = 1.0"
   "# END harvested: nonbio-mean-uncertainty"
   "end"
   ""]))

(deftest mean-skips-null-and-rounds
 (testing "only the stated uncertainties count, the result has six decimals"
  (is (= 0.2
    (h/mean-uncertainty
     "{\"a\":[1,2.0,0.1],\"b\":[1,2.0,null],\"c\":[1,2.0,0.3]}")))
  (is (= 0.333333
    (h/mean-uncertainty "{\"a\":[1,2,0],\"b\":[1,2,0],\"c\":[1,2,1]}")))))

(deftest replace-literal-is-idempotent
 (let [once (h/replace-literal module-text 3.044643)]
  (is (str/includes? once "const NONBIO_MEAN_UNCERTAINTY = 3.044643\n# END"))
  (is (str/starts-with? once "module M\n# BEGIN"))
  (is (str/ends-with? once "end\n"))
  (is (= once (h/replace-literal once 3.044643)))))

(deftest replace-literal-needs-the-markers
 (is (thrown? clojure.lang.ExceptionInfo
   (h/replace-literal "const NONBIO_MEAN_UNCERTAINTY = 1.0\n" 2.0)))
 (is (thrown? clojure.lang.ExceptionInfo
   (h/replace-literal
    (str/replace module-text "= 1.0" "= 1.0\nconst X = 1")
    2.0))))
