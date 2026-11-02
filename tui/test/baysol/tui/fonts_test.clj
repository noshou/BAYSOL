;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Sorting fonts into math and text fonts by what the font files say: synthetic TrueType and
;; OpenType files, built byte by byte (with and without a MATH table, collections, several
;; kinds of name, and corrupt ones), the scan and its cache, the font folders, the registry
;; of Windows, and one scan of the real fonts of the machine.

(ns baysol.tui.fonts-test
 (:require [baysol.tui.fonts :as fonts]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.set :as set]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (java.io File)
  (java.nio.charset Charset)
  (java.util Random)))

;; --- building font files

(defn ^:private be
 "`n` as `size` big-endian bytes."
 [n size]
 (vec (for [k (range (dec size) -1 -1)]
   (unchecked-byte (bit-shift-right n (* 8 k))))))

(defn ^:private ascii [^String s] (vec (.getBytes s "ISO-8859-1")))

(defn ^:private name-record
 "A name-table record: platform, encoding, language, name id and its text."
 [platform language id text]
 {:platform platform,
  :language language,
  :id id,
  :bytes (vec (.getBytes ^String text
    (Charset/forName
     (if (= platform 1) "x-MacRoman" "UTF-16BE"))))})

(defn ^:private name-table
 "The bytes of a `name` table holding `records` (see `name-record`)."
 [records]
 (let [header-size (+ 6 (* 12 (count records)))
   offsets (reductions + 0 (map (comp count :bytes) records))]
  (vec (concat (be 0 2)
    (be (count records) 2)
    (be header-size 2)
    (mapcat (fn [r off]
      (concat (be (:platform r) 2)
       (be 1 2)
       (be (:language r) 2)
       (be (:id r) 2)
       (be (count (:bytes r)) 2)
       (be off 2)))
     records
     offsets)
    (mapcat :bytes records)))))

(defn ^:private sfnt
 "The bytes of one font with the header `version` (a vector of 4 bytes) and `tables`, a
 sequence of `[tag bytes]`, whose offsets count from `base` (where the font starts in its
 file, 0 for a file of one font)."
 [version tables base]
 (let [n (count tables)
   dir-size (+ 12 (* 16 n))
   data-offsets (reductions +
    (+ base dir-size)
    (map (comp #(* 4 (quot (+ % 3) 4)) count second)
     tables))]
  (vec (concat
    version
    (be n 2)
    (be 0 2)
    (be 0 2)
    (be 0 2)
    (mapcat (fn [[tag data] off]
      (concat (ascii tag) (be 0 4) (be off 4) (be (count data) 4)))
     tables
     data-offsets)
    (mapcat (fn [[_ data]]
      (concat data
       (repeat (- (* 4 (quot (+ (count data) 3) 4)) (count data))
        0)))
     tables)))))

(def ^:private ttf-version [0 1 0 0])
(def ^:private otf-version (ascii "OTTO"))

(defn ^:private font-bytes
 "A font file of one face: `{:version v :names [records] :math? bool}`."
 [{:keys [version names math?], :or {version ttf-version}}]
 (sfnt version
  (concat [["cmap" [0 0 0 0]] ["head" (vec (repeat 8 1))]]
   (when names [["name" (name-table names)]])
   (when math? [["MATH" (vec (repeat 12 0))]]))
  0))

(defn ^:private ttc-bytes
 "A collection of the faces `specs` (see `font-bytes`)."
 [specs]
 (let [header (+ 12 (* 4 (count specs)))
   build (fn [base spec]
    (sfnt (:version spec ttf-version)
     (concat [["head" (vec (repeat 8 1))]]
      [["name" (name-table (:names spec))]]
      (when (:math? spec) [["MATH" (vec (repeat 12 0))]]))
     base))
   sizes (map #(count (build 0 %)) specs)
   starts (reductions + header sizes)]
  (vec (concat (ascii "ttcf")
    (be 0x00010000 4)
    (be (count specs) 4)
    (mapcat #(be % 4) (take (count specs) starts))
    (mapcat build starts specs)))))

(defn ^:private write!
 "Writes `content` (a vector) as the file `file-name` in the folder `dir`; the File."
 [^File dir file-name content]
 (let [f (io/file dir file-name)]
  (io/make-parents f)
  (with-open [o (io/output-stream f)] (.write o (byte-array content)))
  f))

(defn ^:private english [family] [(name-record 3 0x409 1 family)])

;; --- reading a font file

(deftest faces-of-a-font-file
 (let [dir (support/temp-root)]
  (testing "a TrueType font without a MATH table, and one with"
   (is (= [{:family "Plain Text", :math? false}]
     (fonts/faces
      (write! dir "plain.ttf" (font-bytes {:names (english "Plain Text")})))))
   (is (= [{:family "Fancy Math", :math? true}]
     (fonts/faces (write! dir
       "math.ttf"
       (font-bytes {:names (english "Fancy Math"),
         :math? true}))))))
  (testing "an OpenType font (OTTO) and a font with the version `true`"
   (is (= [{:family "Open Face", :math? true}]
     (fonts/faces (write! dir
       "o.otf"
       (font-bytes {:version otf-version,
         :names (english "Open Face"),
         :math? true})))))
   (is (= [{:family "Old Mac", :math? false}]
     (fonts/faces (write! dir
       "t.ttf"
       (font-bytes {:version (ascii "true"),
         :names (english "Old Mac")}))))))
  (testing "a math font whose name has no `math` in it is still a math font"
   (is (:math? (first (fonts/faces (write! dir
        "euler.otf"
        (font-bytes {:version otf-version,
          :names (english
           "Neo Euler"),
          :math? true})))))))
  (testing "a font with `Math` in its name and no MATH table is not one"
   (is (not (:math? (first (fonts/faces
        (write! dir
         "fake.otf"
         (font-bytes
          {:version otf-version,
           :names (english "Mathematica Fake")}))))))))
  (testing "a collection gives each face, each with its own table directory"
   (is (= [{:family "Coll Text", :math? false} {:family "Coll Math", :math? true}
      {:family "Coll Third", :math? false}]
     (fonts/faces (write! dir
       "c.ttc"
       (ttc-bytes [{:names (english "Coll Text")}
         {:names (english "Coll Math"),
          :math? true}
         {:names (english "Coll Third")}]))))))
  (testing
   "the typographic family (name 16) is the family, over the family (name 1)"
   (is (= "Libre Franklin"
     (:family (first (fonts/faces
        (write!
         dir
         "lf.otf"
         (font-bytes
          {:names
           [(name-record 3 0x409 1 "Libre Franklin Medium")
            (name-record 3 0x409 16 "Libre Franklin")]}))))))))
  (testing "an English name is chosen over another language, whichever is first"
   (is (= "English Name"
     (:family (first (fonts/faces (write!
         dir
         "l.otf"
         (font-bytes
          {:names
           [(name-record 3 0x407 1 "Deutscher Name")
            (name-record 3 0x409
             1 "English Name")]}))))))))
  (testing "a name in another language only is better than none"
   (is (= "Nur Deutsch"
     (:family (first (fonts/faces (write! dir
         "d.otf"
         (font-bytes
          {:names [(name-record
             3 0x407
             1 "Nur Deutsch")]}))))))))
  (testing "a Macintosh name, and a Unicode one with other letters"
   (is (= "Mac Family"
     (:family (first (fonts/faces (write! dir
         "m.ttf"
         (font-bytes
          {:names [(name-record
             1 0
             1 "Mac Family")]})))))))
   (is (= "Ünïcode Fönt δρ"
     (:family (first (fonts/faces (write! dir
         "u.otf"
         (font-bytes
          {:names (english
            "Ünïcode Fönt δρ")}))))))))
  (testing "a face with no usable family name is left out"
   (is (= [] (fonts/faces (write! dir "n1.ttf" (font-bytes {})))))
   (is (= []
     (fonts/faces (write! dir
       "n2.ttf"
       (font-bytes {:names [(name-record 3 0x409
           2 "Bold")]})))))
   (is (= []
     (fonts/faces
      (write! dir "n3.ttf" (font-bytes {:names (english "   ")}))))))))

(deftest files-that-are-not-fonts-or-are-damaged
 (let [dir (support/temp-root)
   good (font-bytes {:names (english "Good Font"), :math? true})
   at (fn [n] (write! dir (str "f" n ".ttf") n))
   bytes-of (fn [& xs] (vec (map unchecked-byte xs)))]
  (doseq [[what content]
    [["an empty file" []] ["three bytes" (bytes-of 1 2 3)]
     ["text" (ascii "this is not a font at all, just text")]
     ["a WOFF font" (concat (ascii "wOFF") (repeat 100 0))]
     ["a zip file" (concat (ascii "PK") (repeat 100 3))]
     ["a Type 1 font"
      (concat (ascii "%!PS-AdobeFont-1.0: Foo") (repeat 50 32))]
     ["a header with no tables" (concat ttf-version (be 0 2) (repeat 20 0))]
     ["a header with too many tables"
      (concat ttf-version (be 60000 2) (repeat 20 0))]
     ["a table directory cut short"
      (concat ttf-version (be 10 2) (repeat 20 0))]
     ["the header only" (take 12 good)]
     ["half a font" (take (quot (count good) 2) good)]
     ["a collection of no fonts"
      (concat (ascii "ttcf") (be 0x00010000 4) (be 0 4))]
     ["a collection with offsets out of the file"
      (concat (ascii "ttcf")
       (be 0x00010000 4)
       (be 2 4)
       (be 9999 4)
       (be 99999 4))]
     ["a collection that says it has a million fonts"
      (concat (ascii "ttcf") (be 0x00010000 4) (be 1000000 4) (repeat 64 0))]
     ["a collection cut short" (concat (ascii "ttcf") (be 0x00010000 4))]]]
   (is (= [] (fonts/faces (at (vec content)))) what))
  (testing "a name table that points outside the file, or is absurd"
   (let [tables (fn [name-bytes] (sfnt ttf-version [["name" name-bytes]] 0))]
    (is (= []
      (fonts/faces (at (tables (vec (concat (be 0 2)
           (be 1 2)
           (be 6000 2)
           (be 3 2)
           (be 1 2)
           (be 0x409 2)
           (be 1 2)
           (be 20 2)
           (be 0 2)))))))
     "a string past the end")
    (is (= []
      (fonts/faces (at (tables (vec
          (concat (be 0 2) (be 60000 2) (be 6 2)))))))
     "a million records")
    (is (= [] (fonts/faces (at (tables [0 0])))) "a table too short for a header")))
  (testing "a table whose offset or length is outside the file"
   (let [broken (let [b (font-bytes {:names (english "X Font")})]
      ;; set the length of the first table to a huge number
      (vec (concat (take 24 b) (be 2000000000 4) (drop 28 b))))]
    (is (vector? (fonts/faces (at broken))))))
  (testing "a file that does not exist, and a folder"
   (is (= [] (fonts/faces (io/file dir "no-such-file.ttf"))))
   (is (= [] (fonts/faces dir))))))

(deftest reading-damaged-fonts-never-fails
 (let [dir (support/temp-root)
   original (font-bytes
    {:version otf-version, :names (english "Fuzz Font"), :math? true})
   collection (ttc-bytes [{:names (english "A One")}
     {:names (english "B Two"), :math? true}])
   rng (Random. 20261101)
   mutate (fn [content k]
    (reduce (fn [bs _]
      (if (empty? bs)
       bs
       (let [i (.nextInt rng (count bs))]
        (case (.nextInt rng 3)
         0 (assoc bs i (unchecked-byte (.nextInt rng 256)))
         1 (vec (concat (take i bs) (drop (inc i) bs)))
         2 (vec (take i bs))))))
     (vec content)
     (range k)))]
  (dotimes [n 1500]
   (let [source (if (even? n) original collection)
     content (mutate source (inc (.nextInt rng 6)))]
    (when (seq content)
     (let [result (fonts/faces (write! dir "fuzz.bin" content))]
      (is (vector? result))
      (is (every? (fn [f]
         (and (string? (:family f))
          (not (str/blank? (:family f)))
          (boolean? (:math? f))))
        result))))))))

;; --- sorting the fonts

(deftest sorting-fonts-by-the-math-table
 (let [dir (support/temp-root)
   files
   [(write! dir
     "a.otf"
     (font-bytes {:version otf-version, :names (english "Alpha Text")}))
    (write! dir
     "b.otf"
     (font-bytes
      {:version otf-version, :names (english "beta Math"), :math? true}))
    (write! dir
     "c.otf"
     (font-bytes {:version otf-version, :names (english "Gamma Text")}))
    (write! dir
     "d.otf"
     (font-bytes {:version otf-version, :names (english "Alpha Text")}))
    (write! dir
     "e.ttc"
     (ttc-bytes [{:names (english "Mixed")}
       {:names (english "Mixed"), :math? true}]))
    (write! dir "junk.ttf" (ascii "not a font"))]
   result (fonts/scan files)]
  (testing
   "math fonts and text fonts, sorted without regard to case, each family once"
   (is (= ["beta Math" "Mixed"] (:math result)))
   (is (= ["Alpha Text" "Gamma Text"] (:text result))))
  (testing "a family with a math face is a math font only"
   (is (not (some #{"Mixed"} (:text result)))))
  (testing "nothing is in both lists"
   (is (empty? (set/intersection (set (:math result))
      (set (:text result))))))
  (testing "no files, no fonts"
   (is (= {:math [], :text []} (fonts/scan []))))))

(deftest the-fingerprint-follows-the-files
 (let [dir (support/temp-root)
   a (write! dir "a.ttf" (font-bytes {:names (english "A Font")}))
   b (write! dir "b.ttf" (font-bytes {:names (english "B Font")}))
   before (fonts/fingerprint [a b])]
  (is (= before (fonts/fingerprint [a b])) "the same files, the same number")
  (is (= before (fonts/fingerprint [b a])) "in any order")
  (is (not= before (fonts/fingerprint [a])) "a font removed")
  (is (not= before (fonts/fingerprint [a b (write! dir "c.ttf" [1 2 3])]))
   "a font installed")
  (testing "a font replaced by one of another size, or another time"
   (write! dir "b.ttf" (font-bytes {:names (english "B Font Longer Name")}))
   (is (not= before (fonts/fingerprint [a b])))
   (let [again (fonts/fingerprint [a b])]
    (.setLastModified ^File b (+ (.lastModified ^File b) 5000))
    (is (not= again (fonts/fingerprint [a b])))))))

;; --- the cache

(deftest the-cache-is-used-while-the-fonts-are-the-same
 (let [dir (support/temp-root)
   cache (io/file dir "cache" "fonts.edn")
   a (write! dir
    "fonts/a.otf"
    (font-bytes {:version otf-version, :names (english "Alpha")}))
   b (write! dir
    "fonts/b.otf"
    (font-bytes {:version otf-version,
      :names (english "Beta Math"),
      :math? true}))
   scans (atom 0)
   real-scan fonts/scan
   files (atom [a b])
   load! #(with-redefs [fonts/scan (fn [fs] (swap! scans inc) (real-scan fs))]
    (fonts/load-fonts cache (fn [] @files)))]
  (testing "the first time the fonts are scanned and the cache is written"
   (let [r (load!)]
    (is (= {:math ["Beta Math"], :text ["Alpha"]} (select-keys r [:math :text])))
    (is (= 1 @scans))
    (is (.isFile cache))
    (is (= ["Beta Math"] (:math (edn/read-string (slurp cache)))))))
  (testing "the next time they are read from it, with no scan"
   (is (= ["Beta Math"] (:math (load!))))
   (is (= 1 @scans)))
  (testing
   "a font installed makes the fingerprint differ: scanned again, the cache rewritten"
   (let [c (write! dir
      "fonts/c.otf"
      (font-bytes {:version otf-version, :names (english "Gamma")}))]
    (reset! files [a b c])
    (is (= ["Alpha" "Gamma"] (:text (load!))))
    (is (= 2 @scans))
    (is (= ["Alpha" "Gamma"] (:text (edn/read-string (slurp cache)))))
    (is (= ["Alpha" "Gamma"] (:text (load!))))
    (is (= 2 @scans))))
  (testing "a font removed"
   (reset! files [a])
   (is (= [] (:math (load!))))
   (is (= 3 @scans)))
  (testing "a cache that is damaged is scanned over, and mended"
   (doseq [bad ["{ not edn" "" "[1 2]" "{:fingerprint 1}"
      "{:fingerprint 1 :math 5 :text 6}" "nil"]]
    (spit cache bad)
    (let [before @scans
      r (load!)]
     (is (= ["Alpha"] (:text r)) bad)
     (is (= (inc before) @scans) bad)
     (is (= ["Alpha"] (:text (edn/read-string (slurp cache)))) bad))))
  (testing "a cache that cannot be written does not stop the fonts being read"
   (let [blocked (io/file (write! dir "a-file" [1]) "fonts.edn")
     r (with-redefs [fonts/scan real-scan]
      (fonts/load-fonts blocked (fn [] [a b])))]
    (is (= ["Beta Math"] (:math r)))))))

;; --- finding the files

(deftest the-font-folders-of-each-system
 (let [home (support/temp-root)
   _ (.mkdirs (io/file home ".local" "share" "fonts"))
   _ (.mkdirs (io/file home ".fonts"))
   _ (.mkdirs (io/file home "Library" "Fonts"))
   dirs (fn [system]
    (set (map #(.getAbsolutePath ^File %)
      (fonts/default-font-dirs system))))
   linux {:os "Linux", :env {}, :home (str home)}
   mac {:os "Mac OS X", :env {}, :home (str home)}
   windows {:os "Windows 11",
    :env {"WINDIR" (str home), "LOCALAPPDATA" (str home)},
    :home (str home)}]
  (testing "on Linux, the folders under the home that exist"
   (is (contains? (dirs linux) (str (io/file home ".local" "share" "fonts"))))
   (is (contains? (dirs linux) (str (io/file home ".fonts"))))
   (is (not-any? #(str/includes? % "Library") (dirs linux))))
  (testing "on macOS, the user's own folder of fonts"
   (is (contains? (dirs mac) (str (io/file home "Library" "Fonts"))))
   (is (not-any? #(str/includes? % ".fonts") (dirs mac))))
  (testing "on Windows, the folders that exist"
   (.mkdirs (io/file home "Fonts"))
   (is (contains? (dirs windows) (str (io/file home "Fonts")))))
  (testing "a folder that does not exist is left out"
   (is (every? #(.isDirectory (io/file %)) (dirs linux))))))

(deftest what-is-named-like-a-font-file
 (doseq [p ["a.ttf" "a.OTF" "x/y/Z.ttc" "b.otc" "dir.with.dots/c.TTF"
    "C:\\Windows\\Fonts\\arial.ttf"]]
  (is (fonts/font-file? p) p))
 (doseq [p ["a.pfb" "a.t1" "a.woff" "a.woff2" "a.txt" "ttf" "a.ttf.bak" "a" ""
    "x.otf/readme"]]
  (is (not (fonts/font-file? p)) p)))

(deftest font-files-gathers-the-folders-without-repeats
 (let [home (support/temp-root)
   a (write! home
    ".fonts/one.otf"
    (font-bytes {:version otf-version, :names (english "One")}))
   b (write! home
    ".local/share/fonts/sub/two.ttf"
    (font-bytes {:names (english "Two")}))
   _ (write! home ".fonts/readme.txt" (ascii "no"))
   _ (write! home ".fonts/old.pfb" (ascii "no"))
   found (fonts/font-files {:os "Linux", :env {"PATH" ""}, :home (str home)})
   paths (map #(.getAbsolutePath ^File %) found)]
  (testing "the font files of the folders, those of other kinds left out"
   (is (some #{(.getAbsolutePath a)} paths))
   (is (some #{(.getAbsolutePath b)} paths))
   (is (not-any? #(str/ends-with? % ".txt") paths))
   (is (not-any? #(str/ends-with? % ".pfb") paths)))
  (testing "each file once, however many places list it"
   (is (= (count paths) (count (distinct paths)))))))

(deftest the-registry-of-windows
 (let
  [output
   (str
    "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts\r\n"
    "    Arial (TrueType)    REG_SZ    arial.ttf\r\n"
    "    Cambria & Cambria Math (TrueType)    REG_SZ    cambria.ttc\r\n"
    "    Segoe UI Variable (TrueType)    REG_SZ    SegUIVar.ttf\r\n"
    "    Mine (TrueType)    REG_SZ    "
    "C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\mine.otf\r\n"
    "    Network (TrueType)    REG_SZ    \\\\server\\share\\net.ttf\r\n"
    "    Old (Type 1)    REG_SZ    old.pfb\r\n"
    "    Count    REG_DWORD    0x00000003\r\n"
    "    Empty (TrueType)    REG_SZ    \r\n"
    "\r\n")
   parsed (fonts/parse-registry-fonts output "C:\\Windows\\Fonts")]
  (is (= 5 (count parsed)))
  (testing "a file name is in the fonts folder, a path stays as it is"
   (is (some #(str/ends-with? % "arial.ttf") parsed))
   (is (some #(str/ends-with? % "cambria.ttc") parsed))
   (is (some #{"C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\mine.otf"}
     parsed))
   (is (some #{"\\\\server\\share\\net.ttf"} parsed)))
  (testing "other kinds of font, and values that are not strings, are left out"
   (is (not-any? #(str/includes? % "old.pfb") parsed))
   (is (not-any? #(str/includes? % "0x") parsed)))
  (testing "no output, or nonsense, gives nothing"
   (is (= [] (fonts/parse-registry-fonts nil "C:\\Fonts")))
   (is (= [] (fonts/parse-registry-fonts "" "C:\\Fonts")))
   (is (= []
     (fonts/parse-registry-fonts "ERROR: The system cannot find the key"
      "C:\\Fonts"))))))

(deftest tex-is-found-on-the-path
 (let [bin (support/temp-root)
   program (let [f (io/file bin "kpsewhich")]
    (spit f "#!/bin/sh\n")
    (.setExecutable f true)
    f)]
  (is (true? (fonts/tex-installed?
     {:os "Linux", :env {"PATH" (str bin)}, :home "/"})))
  (is (false? (fonts/tex-installed?
     {:os "Linux", :env {"PATH" (str (support/temp-root))}, :home "/"})))
  (is (false? (fonts/tex-installed? {:os "Linux", :env {}, :home "/"})))
  (is (some? program))))

;; --- the real fonts of the machine

(deftest the-real-fonts-are-sorted
 (let [cache (io/file (support/temp-root) "fonts.edn")
   r (fonts/load-fonts cache)
   math (set (:math r))
   text (set (:text r))]
  (testing "the lists partition the families: sorted, no repeats, nothing in both"
   (is (= (:math r) (vec (sort-by str/lower-case (:math r)))))
   (is (= (:text r) (vec (sort-by str/lower-case (:text r)))))
   (is (= (count (:math r)) (count math)))
   (is (= (count (:text r)) (count text)))
   (is (empty? (set/intersection math text))))
  (testing "every name is a real name"
   (is (every? #(and (string? %) (not (str/blank? %)))
     (concat (:math r) (:text r)))))
  (testing "a second load comes from the cache and is the same"
   (let [t0 (System/nanoTime)
     again (fonts/load-fonts cache)
     ms (/ (- (System/nanoTime) t0) 1e6)]
    (is (= (select-keys r [:math :text]) (select-keys again [:math :text])))
    (is (< ms 3000) "reading the font files' list again is quick")))))
