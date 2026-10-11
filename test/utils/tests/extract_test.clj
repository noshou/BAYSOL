;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Tests of extract_formfactor.clj on a tiny synthetic xraydb.sqlite: the rows and blobs it
;; writes, the de-duplication of repeated grid energies, and that a failure leaves an
;; existing output untouched. The SQLite pod is fetched on first use.

(ns extract-test
    (:require [babashka.fs :as fs]
        [babashka.pods :as pods]
        [clojure.test :refer [deftest is testing use-fixtures]]
        [helpers :as h])
    (:import (java.nio ByteBuffer ByteOrder)))

;; The tests are skipped (not failed) when the pod cannot be loaded, e.g. offline.
(def ^:private pod-id
    (try (pods/load-pod 'org.babashka/go-sqlite3 "0.3.13") (catch Exception _ nil)))

(def ^:private sqlite? (some? pod-id))

;; Shut the pod down when the tests of this file are done.
(use-fixtures :once
    (fn [run-tests] (run-tests) (when pod-id (pods/unload-pod pod-id))))

(defn- query [db sql] ((requiring-resolve 'pod.babashka.go-sqlite3/query) db [sql]))
(defn- execute!
    [db sql]
    ((requiring-resolve 'pod.babashka.go-sqlite3/execute!) db [sql]))

(defn- make-source
    "A source database at `path`; `waasmaier-scale` is the JSON text of the amplitudes
    (wrong length: the tool must fail)."
    [path waasmaier-scale]
    (execute!
        path
        "CREATE TABLE Waasmaier (atomic_number INTEGER, element TEXT, ion TEXT,
                    offset REAL, scale TEXT, exponents TEXT)")
    (execute! path
        "CREATE TABLE Chantler (element TEXT, energy TEXT, f1 TEXT, f2 TEXT)")
    (execute! path "CREATE TABLE elements (element TEXT, atomic_number INTEGER)")
    (execute! path
        (str "INSERT INTO Waasmaier VALUES (6, 'C', 'C', 0.2156, '"
            waasmaier-scale
            "', '[20.8439, 10.2075, 0.5687, 51.6512, 0.2156]')"))
    (execute! path "INSERT INTO elements VALUES ('C', 6)")
    (execute!
        path
        "INSERT INTO Chantler VALUES ('C', '[1.0, 2.0, 2.0, 3.0]',
                    '[0.1, 0.2, 0.3, 0.4]', '[1.1, 1.2, 1.3, 1.4]')"))

(defn- doubles-of
    "The doubles of a little-endian Float64 blob given as a vector of bytes."
    [bytes*]
    (let [buf (-> (ByteBuffer/wrap (byte-array (map unchecked-byte bytes*)))
                (.order ByteOrder/LITTLE_ENDIAN))]
        (vec (repeatedly (/ (count bytes*) 8) #(.getDouble buf)))))

(defn- extract
    [src dst]
    (h/run-tool (str h/utils-dir "/extract_formfactor.clj") src dst))

(deftest builds-rows
    (when sqlite?
        (testing
            "rows, lower-cased names, de-duplicated grid, blobs of little-endian doubles"
            (let [scratch (h/scratch-dir)]
                (try
                    (make-source (str scratch "/src.sqlite")
                        "[2.31, 1.02, 1.5886, 0.865, 0.2156]")
                    (let [{:keys [status]} (extract (str scratch "/src.sqlite")
                                (str scratch "/out.sqlite3"))
                            out (str scratch "/out.sqlite3")
                            w
                            (first
                                (query
                                    out
                                    "SELECT ion, element, z, c, a1, a5, b1 FROM waasmaier"))
                            c (first (query
                                    out
                                    (str "SELECT element, z, npts, emin, emax, "
                                        "length(energy) AS n, f1 FROM chantler")))]
                        (is (= 0 status))
                        (is (= {:ion "c",
                                    :element "c",
                                    :z 6,
                                    :c 0.2156,
                                    :a1 2.31,
                                    :a5 0.2156,
                                    :b1 20.8439}
                                w))
                        (is (= ["c" 6 3 1.0 3.0 24]
                                ((juxt :element :z :npts :emin :emax :n) c)))
                        (is (= [0.1 0.2 0.4] (doubles-of (:f1 c))))
                        (is
                            (=
                                ["chantler" "provenance" "waasmaier"]
                                (sort
                                    (map
                                        :name
                                        (query
                                            out
                                            "SELECT name FROM sqlite_master
                                                            WHERE type = 'table'"))))))
                    (finally (fs/delete-tree scratch)))))))

(deftest failure-keeps-existing-output
    (when sqlite?
        (testing
            "a bad source leaves the old output byte for byte and no .part file"
            (let [scratch (h/scratch-dir)]
                (try (make-source (str scratch "/good.sqlite")
                        "[2.31, 1.02, 1.5886, 0.865, 0.2156]")
                    (make-source (str scratch "/bad.sqlite") "[1, 2, 3]")
                    (extract (str scratch "/good.sqlite")
                        (str scratch "/keep.sqlite3"))
                    (fs/copy (str scratch "/keep.sqlite3")
                        (str scratch "/keep.copy"))
                    (let [{:keys [status out]} (extract (str scratch "/bad.sqlite")
                                (str scratch
                                    "/keep.sqlite3"))]
                        (is (not= 0 status))
                        (is (h/contains-text? out "expected 5 amplitudes"))
                        (is (= (vec (fs/read-all-bytes (str scratch "/keep.copy")))
                                (vec (fs/read-all-bytes (str scratch
                                            "/keep.sqlite3")))))
                        (is (not (fs/exists? (str scratch "/keep.sqlite3.part")))))
                    (finally (fs/delete-tree scratch)))))))

(deftest missing-atomic-number
    (when sqlite?
        (testing
            "an element with no atomic number is an error, not a dropped element"
            (let [scratch (h/scratch-dir)]
                (try (make-source (str scratch "/z.sqlite")
                        "[2.31, 1.02, 1.5886, 0.865, 0.2156]")
                    (execute! (str scratch "/z.sqlite") "DELETE FROM elements")
                    (let [{:keys [status out]} (extract (str scratch "/z.sqlite")
                                (str scratch "/z.out"))]
                        (is (not= 0 status))
                        (is (h/contains-text? out "no atomic number"))
                        (is (not (fs/exists? (str scratch "/z.out")))))
                    (finally (fs/delete-tree scratch)))))))

(deftest usage
    (when sqlite?
        (testing "no arguments: usage and status 2"
            (is (= 2
                    (:status (h/run-tool (str h/utils-dir
                                "/extract_formfactor.clj"))))))))

(deftest numbers-are-checked
    (when sqlite?
        (testing "anything but plain numbers in a JSON array is an error"
            (let [numbers (requiring-resolve 'extract-formfactor/numbers)]
                (is (= [1.0 2.5 3.0E-4] (numbers "[1, 2.5, 3e-4]" "t")))
                (is (thrown-with-msg? clojure.lang.ExceptionInfo
                        #"t: 'abc' is not a number"
                        (numbers "[1, abc]" "t")))))))
