;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.edn-store
 "The file handling the EDN files of the user share: reading one with a fallback or with the
 \"unusable\" rule (a file that is not what it should be is told, never written over), and
 writing one through a temporary file that replaces it in one step. What a file holds, and
 how it is laid out, is for the namespace that owns it."
 (:require [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (java.nio.file Files StandardCopyOption)))

(set! *warn-on-reflection* true)

(defn read-edn
 "The EDN value in the file `file`, or `fallback` if its text cannot be read or is not EDN
 (the file must exist). An empty or comment-only file is `nil`.

 # Returns
 The value read, or `fallback`.

 # Exceptions
 None."
 [file fallback]
 (try (edn/read-string (slurp file :encoding "UTF-8"))
  (catch Exception _ fallback)))

(defn read-map
 "The map in the file `file`: `{}` for no file or no content. `spec` is `{:type :name
 :expected :valid?}`: `:valid?` is a function of the map that says whether it is the kind
 of map `:expected` (a phrase) describes. A file that is not EDN, or not such a map, throws
 an exception (message `<name> is not EDN` or `<name> is not <expected>`, data `{:type
 <type>}`).

 # Returns
 A map.

 # Exceptions
 `ExceptionInfo` as above, for a file that cannot be used."
 [file {error-type :type, file-name :name, :keys [expected valid?]}]
 (if-not (.isFile (io/file file))
  {}
  (let [value (read-edn file ::bad)]
   (cond (= value ::bad) (throw (ex-info (str file-name " is not EDN")
      {:type error-type}))
    (nil? value) {}
    (and (map? value) (valid? value)) value
    :else (throw (ex-info (str file-name " is not " expected)
      {:type error-type}))))))

(defn map-text
 "The text of an EDN map of one key: `{<key>\\n [<row> <row>...]` with the rows `rows`
 (strings, one for each entry) one to a line, then the other entries `others` (a map, each
 on a line of its own) and the closing brace.

 # Returns
 A string.

 # Exceptions
 None."
 [k rows others]
 (str "{"
  (pr-str k)
  "\n ["
  (str/join "\n  " rows)
  "]"
  (apply str (for [[k v] others] (str "\n " (pr-str k) " " (pr-str v))))
  "}\n"))

(defn write-atomic!
 "Writes `text` to the file `file` through a temporary file (`<name>.tmp`, next to it) that
 replaces it in one step; the folders are made if there are none.

 # Returns
 The file `file`.

 # Exceptions
 `java.io.IOException` if it cannot be written."
 [file text]
 (let [file (io/file file)
   tmp (io/file (.getParentFile (.getAbsoluteFile file))
    (str (.getName file) ".tmp"))]
  (io/make-parents file)
  (spit tmp text :encoding "UTF-8")
  (Files/move (.toPath tmp)
   (.toPath file)
   (into-array StandardCopyOption
    [StandardCopyOption/REPLACE_EXISTING
     StandardCopyOption/ATOMIC_MOVE]))
  file))

(defn copy-over!
 "Copies the file `from` to `to` (Files or paths), over a file that is there.

 # Returns
 The path of `to`.

 # Exceptions
 `java.io.IOException` if it cannot be copied."
 [from to]
 (Files/copy (.toPath (io/file from))
  (.toPath (io/file to))
  (into-array StandardCopyOption [StandardCopyOption/REPLACE_EXISTING])))

(defn quarantine!
 "Renames the file `file` to `<name>.corrupt` in its folder, replacing an older one, so
 that a file that cannot be used is kept and a new one can take its place. Does nothing for
 a file that is not there.

 # Returns
 The `.corrupt` file (a File), or nil if there was no file.

 # Exceptions
 `java.io.IOException` if it cannot be renamed."
 [file]
 (let [file (io/file file)]
  (when (.isFile file)
   (let [kept (io/file (.getParentFile (.getAbsoluteFile file))
      (str (.getName file) ".corrupt"))]
    (Files/move (.toPath file)
     (.toPath kept)
     (into-array StandardCopyOption
      [StandardCopyOption/REPLACE_EXISTING]))
    kept))))
