;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The desktop's own file picker, to choose structure files (`.cif`, `.pdb`), several at
;; once: `zenity` or `kdialog` on Linux, AppleScript on macOS, PowerShell's open dialog on
;; Windows. The program is asked for the paths and prints them, one to a line. Only the
;; Linux commands have been run; the macOS and Windows ones come from the programs'
;; documentation.
;;
;; A picker is a window of its own, so it needs a desktop: without one (no `DISPLAY` or
;; `WAYLAND_DISPLAY` on Linux) or without any of the programs there is a short reason to
;; show instead.

(ns baysol.tui.file-picker
 (:require [baysol.tui.core :as core]
  [clojure.string :as str])
 (:import (java.lang ProcessBuilder$Redirect)))

(def specs
 "What a picker asks for, by kind: `:structure` (the models: several files, `.cif` and
 `.pdb`) and `:sequence` (the buffer's DNA, RNA and protein files: ONE file, FASTA or
 FASTQ)."
 {:structure {:title "Choose models",
   :label "Structure files",
   :exts ["cif" "pdb"],
   :multiple? true},
  :sequence {:title "Choose a sequence file",
   :label "Sequence files",
   :exts ["fasta" "fa" "fna" "faa" "fastq" "fq"],
   :multiple? false}})

(defn ^:private globs
 "The patterns of the extensions of `spec`, in lower and upper case, `*.cif *.CIF`."
 [spec sep]
 (str/join sep
  (mapcat (fn [e] [(str "*." e) (str "*." (str/upper-case e))])
   (:exts spec))))

(defn ^:private zenity-command
 [start-dir spec]
 (-> ["zenity" "--file-selection"]
  (cond-> (:multiple? spec) (conj "--multiple"))
  (into [(str "--title=" (:title spec)) (str "--filename=" start-dir "/")
    "--separator=\n"
    (str "--file-filter=" (:label spec) " | " (globs spec " "))])))

(defn ^:private kdialog-command
 [start-dir spec]
 (-> ["kdialog"]
  (cond-> (:multiple? spec) (into ["--multiple" "--separate-output"]))
  (into ["--title" (:title spec) "--getopenfilename" start-dir
    (str (globs spec " ") "|" (:label spec))])))

(defn ^:private mac-command
 [spec]
 ["osascript"
  "-e"
  (str "set fs to choose file with prompt \""
   (:title spec)
   "\" of type {"
   (str/join ", " (map #(str "\"" % "\"") (:exts spec)))
   "}"
   (when (:multiple? spec) " with multiple selections allowed")
   (when-not (:multiple? spec) "\nset fs to {fs}"))
  "-e" "set out to \"\""
  "-e" "repeat with f in fs"
  "-e" "set out to out & POSIX path of f & linefeed"
  "-e" "end repeat"
  "-e" "return out"])

(defn ^:private windows-command
 [start-dir spec]
 ["powershell" "-NoProfile" "-Command"
  (str "Add-Type -AssemblyName System.Windows.Forms; "
   "$d = New-Object System.Windows.Forms.OpenFileDialog; "
   "$d.Multiselect = "
   (if (:multiple? spec) "$true" "$false")
   "; $d.Title = '"
   (:title spec)
   "'; "
   "$d.Filter = '"
   (:label spec)
   "|"
   (str/join ";" (map #(str "*." %) (:exts spec)))
   "'; "
   "$d.InitialDirectory = '" (str/replace start-dir "'" "''")
   "'; "
   "if ($d.ShowDialog() -eq 'OK') { $d.FileNames -join \"`n\" }")])

(defn picker-commands
 "The commands to try, in order, to pick files starting in the folder `start-dir`, on
 `system`, for the picker `spec` (one of [[specs]], the structure files by default); empty
 for an unknown system. On Linux `kdialog` comes first on a KDE desktop and `zenity` first
 anywhere else."
 ([system start-dir] (picker-commands system start-dir (:structure specs)))
 ([system start-dir spec]
  (cond (core/linux? system)
   (let [kde? (str/includes?
      (str/lower-case (str (get (:env system) "XDG_CURRENT_DESKTOP")))
      "kde")
     both [(zenity-command start-dir spec)
      (kdialog-command start-dir spec)]]
    (if kde? (vec (reverse both)) both))
   (core/mac? system) [(mac-command spec)]
   (core/windows? system) [(windows-command start-dir spec)]
   :else [])))

(defn parse-output
 "The paths in the output `text` of a picker: its non-blank lines, trimmed of the line
 ends only (a name may have spaces)."
 [text]
 (->> (str/split-lines (str text))
  (map #(str/replace % #"[\r\n]+$" ""))
  (remove str/blank?)
  vec))

(defn ^:private display?
 "Whether the desktop of `system` can show a window (on Linux; elsewhere always)."
 [system]
 (or (not (core/linux? system))
  (boolean (or (seq (get (:env system) "DISPLAY"))
    (seq (get (:env system) "WAYLAND_DISPLAY"))))))

(defn ^:private run-command!
 "Runs `command` and returns what it printed on standard output; its input is closed and
 its errors are thrown away, so nothing of it reaches the terminal the TUI draws on. Waits
 for the window to close."
 [command]
 (let [process (-> (doto (ProcessBuilder. ^java.util.List command)
     (.redirectError ProcessBuilder$Redirect/DISCARD))
    .start)]
  (.close (.getOutputStream process))
  (let [out (slurp (.getInputStream process) :encoding "UTF-8")]
   (.waitFor process)
   out)))

(defn pick!
 "Opens the desktop's file picker in the folder `start-dir` and waits for it, for the
 picker `kind` (a key of [[specs]], `:structure` by default). Returns `{:files [path ...]}`
 with what was picked (empty if the window was closed without a choice) or `{:problem
 \"short reason\"}` when no picker could be shown."
 ([start-dir] (pick! start-dir :structure))
 ([start-dir kind]
  (let [system (core/read-system)
    command (first (filter
      #(core/find-executable system (first %))
      (picker-commands system start-dir (get specs kind))))]
   (cond (not (display? system)) {:problem "no desktop: cannot show a picker"}
    (not command) {:problem "no file picker (zenity or kdialog)"}
    :else (try {:files (parse-output (run-command! command))}
     (catch Exception e
      {:problem (str "picker failed: " (ex-message e))}))))))
