;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The fonts installed on this machine, sorted into math fonts and text
;; fonts by what the font files themselves say: a font is a math font when
;; it has an OpenType `MATH` table, which is what `unicode-math` (and so
;; LuaLaTeX) needs for a math font. Nothing is guessed from a name.
;;
;; The font files are the fonts the user has installed and, if a TeX installation is found,
;; the fonts of TeX too, joined without repeats:
;; - The system's font folders (`/usr/share/fonts`, `~/.local/share/fonts`,
;;   `/Library/Fonts`, `C:\Windows\Fonts` ...), walked: this needs no program, so it
;;   works on Linux, macOS and Windows alike. The files fontconfig reports (`fc-list`) are
;;   added when that is installed, for font folders that are set up in its configuration
;;   only, and on Windows the files the registry lists.
;; - With TeX (`kpsewhich` or `luaotfload-tool` is on the path): the files the LuaLaTeX
;;   font database lists (`luaotfload-tool`), which include the fonts of TeX's own `texmf`
;;   trees that are not system fonts. If there is no such database, the OpenType and
;;   TrueType fonts in the `texmf` trees (`TEXMFDIST`, `TEXMFLOCAL`, `TEXMFHOME` ...) are
;;   walked instead. Without TeX, none of it is looked for.
;;
;; Each file's header is read for its faces (a `.ttc` or `.otc` holds several), each face's
;; family name, from its `name` table, and its table directory, for `MATH`. Type 1 fonts and
;; anything that is not an OpenType or TrueType file are left out.
;;
;; Reading about six thousand headers takes a fraction of a second, but the result is cached
;; all the same, in a file, with a fingerprint of the files it was made from (their paths,
;; sizes and times): a font installed or removed later changes the fingerprint and the fonts
;; are scanned again.

(ns baysol.tui.fonts
 (:require [baysol.tui.core :as core]
  [baysol.tui.edn-store :as store]
  [clojure.java.io :as io]
  [clojure.java.shell :as shell]
  [clojure.string :as str])
 (:import (java.io File RandomAccessFile)
  (java.nio.charset Charset)))

(def ^:private font-extensions #{"otf" "ttf" "ttc" "otc"})

;; Limits that keep a corrupt file from making the scan read, or allocate, without end.
(def ^:private max-tables 512)
(def ^:private max-faces 256)
(def ^:private max-name-table 4194304)
(def ^:private max-name-records 20000)

;; --- reading a font file

(defn ^:private read-bytes
 "`n` bytes of `raf` from `pos`, or nil if that goes past the end of the file."
 ^bytes [^RandomAccessFile raf pos n]
 (when (and (>= pos 0) (>= n 0) (<= (+ pos n) (.length raf)))
  (let [b (byte-array n)]
   (.seek raf pos)
   (.readFully raf b)
   b)))

(defn ^:private u16
 [^bytes b o]
 (bit-or (bit-shift-left (bit-and (aget b o) 0xFF) 8)
  (bit-and (aget b (inc o)) 0xFF)))

(defn ^:private u32
 [^bytes b o]
 (bit-or (bit-shift-left (long (u16 b o)) 16) (long (u16 b (+ o 2)))))

(defn ^:private tag
 "The four-character tag at `o` of `b`."
 [^bytes b o]
 (String. b (int o) 4 (Charset/forName "ISO-8859-1")))

(defn ^:private table-directory
 "The tables of the face whose header is at `offset` of the file `raf`: `{tag [offset
 length]}`, or nil if there is no TrueType or OpenType header there."
 [^RandomAccessFile raf offset]
 (when-let [head (read-bytes raf offset 12)]
  (let [version (tag head 0)
    n (u16 head 4)]
   (when (and (or (= version "OTTO")
      (= version "true")
      (= version "typ1")
      (= (u32 head 0) 0x00010000))
     (<= 1 n max-tables))
    (when-let [records (read-bytes raf (+ offset 12) (* n 16))]
     (into {}
      (for [k (range n)
        :let [o (* k 16)]]
       [(tag records o) [(u32 records (+ o 8)) (u32 records (+ o 12))]])))))))

(defn ^:private decode
 "The text of the name-table string of `n` bytes at `o` of `b`, as the platform `platform`
 encodes it: UTF-16 for Windows and Unicode, Mac Roman (or Latin-1) for Macintosh."
 [^bytes b o n platform]
 (let [charset (if (= platform 1)
    (try (Charset/forName "x-MacRoman")
     (catch Exception _ (Charset/forName "ISO-8859-1")))
    (Charset/forName "UTF-16BE"))]
  (str/trim (String. b (int o) (int n) charset))))

(defn ^:private family-name
 "The family name in the `name` table (`[offset length]`) of the font file `raf`: the
 typographic family (name 16) if the face has one, else the family (name 1); an English one
 if there is one. nil if there is none or the table cannot be read."
 [^RandomAccessFile raf [offset length]]
 (when (and (pos? length) (<= length max-name-table))
  (when-let [t (read-bytes raf offset length)]
   (when (>= (alength t) 6)
    (let [n-records (u16 t 2)
      strings (u16 t 4)]
     (when (and (<= n-records max-name-records)
       (<= (+ 6 (* n-records 12)) (alength t)))
      (let [records
        (for [k (range n-records)
          :let [o (+ 6 (* k 12))
           platform (u16 t o)
           language (u16 t (+ o 4))
           id (u16 t (+ o 6))
           len (u16 t (+ o 8))
           at (+ strings (u16 t (+ o 10)))]
          :when (and (#{1 16} id) (<= (+ at len) (alength t)) (pos? len))]
         {:id id,
          :platform platform,
          :text (delay (decode t at len platform)),
          :rank (cond (and (= platform 3) (= language 0x409)) 0
           (= platform 3) 1
           (= platform 0) 2
           (and (= platform 1) (zero? language)) 3
           :else 9)})
        best (fn [id]
         (->> records
          (filter #(and (= id (:id %)) (< (:rank %) 9)))
          (sort-by :rank)
          first))]
       (when-let [r (or (best 16) (best 1))]
        (let [s @(:text r)] (when-not (str/blank? s) s))))))))))

(defn faces
 "The faces of the font file `file` (a File): `[{:family name :math? bool} ...]`, one for
 each face that is a TrueType or OpenType font with a family name, `:math?` true when it
 has a `MATH` table. Empty for a file that is not such a font, that is damaged, or cannot
 be read."
 [^File file]
 (try (with-open [raf (RandomAccessFile. file "r")]
   (let [head (read-bytes raf 0 4)
     offsets (cond (nil? head) []
      (= (tag head 0) "ttcf")
      (let [h (read-bytes raf 0 12)
        n (when h (min max-faces (u32 h 8)))
        os (when n (read-bytes raf 12 (* 4 n)))]
       (if os (mapv #(u32 os (* 4 %)) (range n)) []))
      :else [0])]
    (vec (for [offset offsets
       :let [tables (table-directory raf offset)]
       :when tables
       :let [family (some->> (get tables "name")
         (family-name raf))]
       :when family]
      {:family family, :math? (contains? tables "MATH")}))))
  (catch Exception _ [])))

;; --- finding the font files

(defn default-font-dirs
 "The font folders (Files) of the system `system` (see `baysol.tui.core/read-system`), those
 that exist."
 [system]
 (let [home (:home system)
   env #(get (:env system) %)
   dirs (cond (core/windows? system)
    [(io/file (or (env "WINDIR") "C:\\Windows") "Fonts")
     (io/file (or (env "LOCALAPPDATA") (str home "\\AppData\\Local"))
      "Microsoft"
      "Windows"
      "Fonts")]
    (core/mac? system)
    [(io/file "/System/Library/Fonts") (io/file "/Library/Fonts")
     (io/file home "Library" "Fonts")]
    :else [(io/file "/usr/share/fonts")
     (io/file "/usr/local/share/fonts")
     (io/file home ".fonts")
     (io/file home ".local" "share" "fonts")])]
  (filter #(.isDirectory ^File %) dirs)))

(defn font-file?
 "Whether the path `path` is named like a TrueType or OpenType font file."
 [path]
 (contains? font-extensions
  (str/lower-case (or (second (re-find #"\.([^./\\]+)$" path)) ""))))

(defn ^:private program-lines
 "The non-blank lines that the program run as `cmd` prints, or nil if it cannot run or
 fails."
 [& cmd]
 (try (let [{:keys [exit out]} (apply shell/sh cmd)]
   (when (zero? exit) (remove str/blank? (map str/trim (str/split-lines out)))))
  (catch Exception _ nil)))

(def ^:private texmf-variables
 "The kpathsea variables that name the `texmf` trees of a TeX installation."
 ["TEXMFDIST" "TEXMFLOCAL" "TEXMFHOME" "TEXMFMAIN" "TEXMFSYSVAR" "TEXMFVAR"])

(defn tex-installed?
 "Whether a TeX installation is on the path of `system`: `kpsewhich`, or LuaLaTeX's
 `luaotfload-tool`."
 [system]
 (boolean (or (core/find-executable system "kpsewhich")
   (core/find-executable system "luaotfload-tool"))))

(defn tex-font-dirs
 "The folders (Files) of the OpenType and TrueType fonts in the `texmf` trees of the TeX
 installation, those that exist: `fonts/opentype` and `fonts/truetype` under each tree that
 `kpsewhich` names. Empty if there is no `kpsewhich`."
 []
 (let [trees (->> texmf-variables
    (mapcat #(program-lines "kpsewhich" (str "-var-value=" %)))
    (mapcat #(str/split % #"[:;,{}]"))
    (map #(str/replace % #"^!!|/+$|\\+$" ""))
    (remove str/blank?)
    distinct)]
  (->> (for [tree trees
     kind ["opentype" "truetype"]]
    (io/file tree "fonts" kind))
   (filter #(.isDirectory ^File %)))))

(defn ^:private walk-fonts
 "The paths of the font files under the folders `dirs`."
 [dirs]
 (for [dir dirs
   ^File f (file-seq dir)
   :when (and (.isFile f) (font-file? (.getName f)))]
  (.getAbsolutePath f)))

(defn parse-registry-fonts
 "The font files named in the text `output` that `reg query` prints for a registry key of
 installed fonts: each `Name (TrueType)    REG_SZ    file` line gives a file, a path of its
 own for a font that was installed for one user, else a file name in `fonts-dir`. Only the
 names of TrueType and OpenType files are kept."
 [output fonts-dir]
 (vec (for [line (str/split-lines (or output ""))
    :let [[_ value] (re-find #"\s+REG_SZ\s+(.+?)\s*$" line)]
    :when (and value (font-file? value))]
   (if (re-find #"^([A-Za-z]:[\\/]|\\\\|/)" value)
    value
    (str (io/file fonts-dir value))))))

(defn ^:private registry-fonts
 "On Windows, the font files the registry lists as installed, for the machine and for the
 user: some are in folders that are not the system's font folders. Nothing elsewhere, or
 when `reg` cannot run."
 [system]
 (when (core/windows? system)
  (let [fonts-dir (str (io/file (or (get (:env system) "WINDIR") "C:\\Windows")
      "Fonts"))]
   (vec (mapcat (fn [hive]
      (parse-registry-fonts
       (try
        (:out
         (shell/sh
          "reg"
          "query"
          (str
           hive
           "\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts")))
        (catch Exception _ nil))
       fonts-dir))
     ["HKLM" "HKCU"])))))

(defn font-files
 "The font files (Files) of this machine, without repeats: those in the system's font
 folders, those fontconfig lists and, on Windows, those the registry lists; and, when a TeX
 installation is found (`tex-installed?`), those of the LuaLaTeX font database, which lists
 the fonts of the `texmf` trees too. A TeX with no such database (or an empty one) has its
 `texmf` font trees walked instead, which takes longer. A source that is not there adds
 nothing. `system` is as in `default-font-dirs`."
 [system]
 (let [walked (walk-fonts (default-font-dirs system))
   from-fontconfig (program-lines "fc-list" "--format" "%{file}\n")
   tex? (tex-installed? system)
   from-luaotfload (when tex?
    (program-lines "luaotfload-tool" "--no-reload"
     "--list=*" "--fields=fullpath"))
   from-texmf (when (and tex? (empty? (filter font-file? from-luaotfload)))
    (walk-fonts (tex-font-dirs)))]
  (->> (concat walked
    from-fontconfig
    (registry-fonts system)
    from-luaotfload
    from-texmf)
   (filter font-file?)
   distinct
   (map io/file)
   (filter #(.isFile ^File %))
   vec)))

;; --- the scan and its cache

(defn scan
 "Sorts the fonts of the font files `files` into math and text fonts: `{:math [family ...]
 :text [family ...]}`, each sorted without regard to case. A family with a face that has a
 `MATH` table is a math font and not a text font."
 [files]
 (let [all (apply concat (pmap faces files))
   math (into #{} (comp (filter :math?) (map :family)) all)
   text (into #{} (comp (remove :math?) (map :family) (remove math)) all)
   sorted #(vec (sort-by str/lower-case %))]
  {:math (sorted math), :text (sorted text)}))

(defn fingerprint
 "A number that stands for the font files `files` as they are: their paths, sizes and times
 of change. It changes when a font is installed, removed or replaced."
 [files]
 (hash (sort (for [^File f files]
    [(.getAbsolutePath f) (.length f) (.lastModified f)]))))

(defn ^:private read-cache
 "The cache file `cache` (a File) as a map, or nil if there is none or it is not one."
 [^File cache]
 (try (when (.isFile cache)
   (let [m (store/read-edn cache nil)]
    (when (and (map? m)
      (contains? m :fingerprint)
      (vector? (:math m))
      (vector? (:text m)))
     m)))
  (catch Exception _ nil)))

(defn ^:private write-cache!
 "Writes `fonts` to the cache file `cache`; a failure is ignored (the scan is just done
 again next time)."
 [^File cache fonts]
 (try (io/make-parents cache)
  (spit cache (pr-str fonts) :encoding "UTF-8")
  (catch Exception _ nil)))

(defn load-fonts
 "The installed fonts, `{:math [...] :text [...] :fingerprint n}`, from the cache file
 `cache` (a File) when the font files are the ones it was made from, else by scanning them
 (and writing the cache). `files` is a function that gives the font files; the default
 looks on this machine (`font-files`)."
 ([cache] (load-fonts cache #(font-files (core/read-system))))
 ([cache files-fn]
  (let [files (files-fn)
    current (fingerprint files)
    cached (read-cache cache)]
   (if (and cached (= current (:fingerprint cached)))
    cached
    (let [fonts (assoc (scan files) :fingerprint current)]
     (write-cache! cache fonts)
     fonts)))))
