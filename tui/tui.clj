(require '[babashka.pods :as pods])

(pods/load-pod
    ["java" "-jar"
        "tui/lib/pod-babashka-lanterna/pod-babashka-lanterna-0.0.1-standalone.jar"]
    {:transport :socket})

(require '[pod.babashka.lanterna.terminal :as terminal])

(def term (terminal/get-terminal))

; small scaffolding for lanterna
(terminal/start term)
(try (terminal/put-string term "BAYSOL TUI" 2 2)
    (terminal/put-string term "Lanterna is working!" 2 4)
    (terminal/put-string term "Press q to quit." 2 6)
    (terminal/flush term)
    (loop [] (when-not (= "q" (str (terminal/get-key-blocking term))) (recur)))
    (finally (terminal/stop term)))
