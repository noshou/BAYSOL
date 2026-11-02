;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.core.app-test
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.support :as support]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]])
 (:import (java.nio.file Files)
  (java.nio.file.attribute FileAttribute)))

(defn ^:private system
 ([os env] (system os env "/home/u"))
 ([os env home] {:os os, :env env, :home home, :cwd "/work"}))

(defn ^:private path-of [file] (.getPath ^java.io.File file))

(deftest env-dir-takes-an-absolute-path-only
 (is (= "/a/b" (path-of (app/env-dir {:env {"X" "/a/b"}} "X"))))
 (is (= "/a/b" (path-of (app/env-dir {:env {"X" " /a/b "}} "X"))))
 (is (nil? (app/env-dir {:env {"X" "a/b"}} "X")))
 (is (nil? (app/env-dir {:env {"X" " "}} "X")))
 (is (nil? (app/env-dir {:env {}} "X"))))

(deftest the-baysol-folder-on-each-system
 (testing "Linux and everything else: XDG_DATA_HOME, else ~/.local/share"
  (is (= "/home/u/.local/share/baysol"
    (path-of (app/app-root (system "Linux" {})))))
  (is (= "/data/xdg/baysol"
    (path-of (app/app-root (system "Linux" {"XDG_DATA_HOME" "/data/xdg"})))))
  (testing "a relative or blank XDG_DATA_HOME is ignored"
   (is (= "/home/u/.local/share/baysol"
     (path-of (app/app-root (system "Linux" {"XDG_DATA_HOME" "rel"})))))
   (is (= "/home/u/.local/share/baysol"
     (path-of (app/app-root (system "Linux" {"XDG_DATA_HOME" "  "}))))))
  (is (= "/home/u/.local/share/baysol"
    (path-of (app/app-root (system "FreeBSD" {}))))))
 (testing "macOS"
  (is (= "/Users/u/Library/Application Support/baysol"
    (path-of (app/app-root (system "Mac OS X" {} "/Users/u"))))))
 (testing "Windows: %LOCALAPPDATA%, else <home>/AppData/Local"
  (is (= "/win/Local/baysol"
    (path-of (app/app-root
      (system "Windows 11" {"LOCALAPPDATA" "/win/Local"} "/h")))))
  (is (= "/h/AppData/Local/baysol"
    (path-of (app/app-root (system "Windows 11" {} "/h"))))))
 (testing "BAYSOL_HOME wins on every system, when it is absolute"
  (is (= "/srv/baysol"
    (path-of (app/app-root
      (system "Linux"
       {"BAYSOL_HOME" "/srv/baysol", "XDG_DATA_HOME" "/d"})))))
  (is (= "/home/u/.local/share/baysol"
    (path-of (app/app-root (system "Linux" {"BAYSOL_HOME" "rel"})))))))

(deftest the-cache-folder-on-each-system
 (testing
  "Linux follows XDG_CACHE_HOME, ~/.cache by default, a relative one is ignored"
  (is (= "/home/u/.cache/baysol/_cache"
    (path-of (app/cache-root (system "Linux" {})))))
  (is (= "/x/baysol/_cache"
    (path-of (app/cache-root (system "Linux" {"XDG_CACHE_HOME" "/x"})))))
  (is (= "/home/u/.cache/baysol/_cache"
    (path-of (app/cache-root (system "Linux" {"XDG_CACHE_HOME" "rel"}))))))
 (testing "macOS uses Library/Caches"
  (is (= "/home/u/Library/Caches/baysol/_cache"
    (path-of (app/cache-root (system "Mac OS X" {}))))))
 (testing "BAYSOL_CACHE wins, and it is not under the data folder"
  (is (= "/c" (path-of (app/cache-root (system "Linux" {"BAYSOL_CACHE" "/c"})))))))

(deftest projects-are-inside-the-baysol-folder
 (is (= "/srv/baysol/projects"
   (path-of (app/projects-root (io/file "/srv/baysol"))))))

(deftest ensure-dir-makes-folders-and-names-the-one-it-cannot
 (let [root (.toFile (Files/createTempDirectory "baysol-test"
     (make-array FileAttribute 0)))]
  (testing "a folder and the parents it lacks"
   (let [dir (io/file root "x" "y" "z")]
    (is (= dir (app/ensure-dir! dir)))
    (is (.isDirectory dir))))
  (testing "a folder below a file: an exception that names it"
   (spit (io/file root "afile") "x")
   (let [dir (io/file root "afile" "sub")
     e (try (app/ensure-dir! dir) nil (catch Exception e e))]
    (is (some? e))
    (is (= "Could not initialize directory" (ex-message e)))
    (is (= {:path (.getAbsolutePath dir)} (ex-data e)))
    (is (= "Failed to create directory" (ex-message (ex-cause e))))))))

(deftest the-version-name-is-v-version-dash-release
 (is (re-matches #"v\d+\.\d+\.\d+-.+" (app/version-name))))

(deftest clearing-the-cache-empties-it-and-keeps-the-folder
 (let [root (support/temp-root)
   cache (io/file root "baysol" "_cache")
   sys (system "Linux" {} (path-of root))]
  (.mkdirs cache)
  (app/tag-cache! sys cache)
  (io/make-parents (io/file cache "components" "x.cif"))
  (spit (io/file cache "components" "x.cif") "12345")
  (spit (io/file cache "fonts.edn") "{}")
  (is (= (+ 7 (count (slurp (io/file cache "CACHEDIR.TAG"))))
    (app/cache-size cache)))
  (is (= 7 (app/clear-cache! sys cache)) "the bytes freed leave out the marker")
  (is (.isDirectory cache))
  (is (= ["CACHEDIR.TAG"] (vec (.list cache))) "only the marker is left")
  (is (= 0 (app/clear-cache! sys cache)) "an empty cache frees nothing")
  (is (= 0 (app/clear-cache! sys (io/file root "none"))) "a missing one too")))

(deftest clearing-does-not-follow-links-and-refuses-dangerous-folders
 (let [root (support/temp-root)
   cache (io/file root "_cache")
   outside (io/file root "outside")]
  (.mkdirs cache)
  (app/tag-cache! (system "Linux" {} "/home/u") cache)
  (.mkdirs outside)
  (spit (io/file outside "keep") "data")
  (Files/createSymbolicLink (.toPath (io/file cache "link"))
   (.toPath outside)
   (make-array FileAttribute 0))
  (app/clear-cache! (system "Linux" {} "/home/u") cache)
  (is (= ["keep"] (vec (.list outside))) "the link target is untouched")
  (is (= ["CACHEDIR.TAG"] (vec (.list cache))) "only the marker is left"))
 (let [home (support/temp-root)]
  (spit (io/file home "mine") "x")
  (is (thrown? clojure.lang.ExceptionInfo
    (app/clear-cache! (system "Linux" {} (path-of home)) home)))
  (is (.exists (io/file home "mine")))
  (is (thrown? clojure.lang.ExceptionInfo
    (app/clear-cache! (system "Linux" {} "/home/u") (io/file "/"))))))

(deftest only-a-marked-default-or-empty-folder-is-cleared
 (let [root (support/temp-root)
   sys (system "Linux"
    {"BAYSOL_CACHE" (path-of (io/file root "mine"))}
    (path-of root))
   mine (io/file root "mine")]
  (testing
   "a folder BAYSOL_CACHE names that holds other things is not marked, not cleared"
   (.mkdirs mine)
   (spit (io/file mine "thesis.tex") "keep")
   (app/tag-cache! sys mine)
   (is (not (.exists (io/file mine "CACHEDIR.TAG"))))
   (is (thrown-with-msg? clojure.lang.ExceptionInfo
     #"not marked as a BAYSOL cache"
     (app/clear-cache! sys mine)))
   (is (.exists (io/file mine "thesis.tex"))))
  (testing "an empty one is marked when it is made, and then cleared"
   (let [fresh (io/file root "fresh")]
    (.mkdirs fresh)
    (app/tag-cache! sys fresh)
    (is (.exists (io/file fresh "CACHEDIR.TAG")))
    (spit (io/file fresh "a") "x")
    (is (pos? (app/clear-cache! sys fresh)))
    (is (not (.exists (io/file fresh "a"))))))
  (testing
   "the default folder needs no marker (a cache made before markers existed)"
   (let [default (io/file root ".cache" "baysol" "_cache")
     dsys (system "Linux" {} (path-of root))]
    (.mkdirs default)
    (spit (io/file default "fonts.edn") "{}")
    (is (= 2 (app/clear-cache! dsys default)))
    (is (not (.exists (io/file default "fonts.edn"))))))))
