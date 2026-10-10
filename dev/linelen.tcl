#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# The line-length rule of the code (every line at
# most 92 characters) and the tools for applying it.
#
#     tclsh dev/linelen.tcl --check [PATH ...]
#     tclsh dev/linelen.tcl --snapshot DIR
#     tclsh dev/linelen.tcl --verify DIR [PATH ...]
#     tclsh dev/linelen.tcl --reflow [PATH ...]
#
#   --check      lists every line over 92 characters (file:line: length) in the code
#                files under PATH (files or directories, default the whole
#                repository) and exits 1 if there is one. Characters are counted,
#                not bytes. The precommit step `line-length` runs this and refuses
#                the commit.
#   --snapshot   copies every checked code file into DIR (keeping the relative
#                paths), the state to compare against.
#   --verify     after the long lines were split: every checked file (under PATH,
#                default all) that differs from its copy in DIR must have the same
#                code. Julia files are compared as syntax trees (comments and line
#                breaks do not count, the whitespace inside string and docstring
#                literals is normalized), Tcl files by their words after joining
#                backslash-continued lines. Exits 1 on the first difference.
#
#   --reflow     re-wraps the comment blocks and docstring paragraphs of Julia and
#                Tcl files under PATH that contain a line over the limit, balanced
#                (all lines about equally long, no stray last word). Code, lists,
#                tables, code blocks and indented text are left alone.
#
# Checked: code only (.jl .tcl .test .scss .yml), not Markdown,
# data (json, tsv, toml, txt) or generated CSS. Needs Tcl 9;
# --verify needs `julia` on the PATH (or JULIA=/path/to/julia).

source [file join [file dirname [info script]] .. test utils common.tcl]
set SCRIPT [info script]

namespace eval linelen {
    namespace path ::util

    variable LIMIT 92
    variable EXTENSIONS {.jl .tcl .test .scss .yml}
    variable SKIP_DIRS {.git build _cache sources manuscript .CondaPkg node_modules}

    # Every checked code file under $path (a file
    # or a directory), as paths relative to $ROOT.
    proc files {path} {
        global ROOT
        variable EXTENSIONS
        variable SKIP_DIRS
        set path [file normalize $path]
        if {[file isfile $path]} {
            return [expr {
                [file extension $path] in $EXTENSIONS ? [list [relative $path]] : {}
            }]
        }
        set out {}
        foreach entry [lsort [glob -nocomplain -directory $path -types {f d} *]] {
            if {[file isdirectory $entry]} {
                if {[file tail $entry] ni $SKIP_DIRS} {
                    lappend out {*}[files $entry]
                }
            } elseif {[file extension $entry] in $EXTENSIONS} {
                lappend out [relative $entry]
            }
        }
        return $out
    }

    proc relative {path} {
        global ROOT
        set root_length [string length [file normalize $ROOT]]
        return [string range [file normalize $path] $root_length+1 end]
    }

    proc read_utf8 {path} {
        set ch [open $path r]
        fconfigure $ch -encoding utf-8
        set text [read $ch]
        close $ch
        return $text
    }

    # The lines over the limit among the files, as {file line length text} entries.
    proc long_lines {files} {
        global ROOT
        variable LIMIT
        set out {}
        foreach f $files {
            set i 0
            foreach line [split [read_utf8 [file join $ROOT $f]] "\n"] {
                incr i
                set n [string length [string trimright $line "\r"]]
                if {$n > $LIMIT} {
                    lappend out [list $f $i $n $line]
                }
            }
        }
        return $out
    }

    # The lines with a tab character among the files, as {file line} entries (indent with 4
    # spaces).
    proc tab_lines {files} {
        global ROOT
        set out {}
        foreach f $files {
            set i 0
            foreach line [split [read_utf8 [file join $ROOT $f]] "\n"] {
                incr i
                if {[string first "\t" $line] >= 0} {
                    lappend out [list $f $i]
                }
            }
        }
        return $out
    }

    proc check {paths} {
        global ROOT
        if {![llength $paths]} {
            set paths [list $ROOT]
        }
        set files {}
        foreach p $paths {
            lappend files {*}[files $p]
        }
        set long [long_lines $files]
        foreach e $long {
            lassign $e f i n line
            puts "$f:$i: $n characters"
        }
        set tabs [tab_lines $files]
        foreach e $tabs {
            lassign $e f i
            puts "$f:$i: tab character (indent with 4 spaces)"
        }
        if {[llength $tabs]} {
            puts stderr "linelen.tcl: [llength $tabs] line(s) with a tab character"
            set tab_failed 1
        }
        if {[info exists tab_failed] && ![llength $long]} {
            exit 1
        }
        if {[llength $long]} {
            set nfiles [llength [lsort -unique [lmap e $long {lindex $e 0}]]]
            puts stderr "linelen.tcl: [llength $long] line(s) over 92 characters in\
                $nfiles file(s)"
            exit 1
        }
        puts "layout: [llength $files] code files, no\
            line over 92 characters, no tab character"
    }

    proc snapshot {dir} {
        global ROOT
        foreach f [files $ROOT] {
            set to [file join $dir $f]
            file mkdir [file dirname $to]
            file copy -force [file join $ROOT $f] $to
        }
        puts "snapshot of [llength [files $ROOT]] files in $dir"
    }

    # Tcl words of a script after joining continued lines and dropping
    # comments and blank lines: what a split of long lines must leave alone.
    proc tcl_words {text} {
        set text [regsub -all {\\\n[ \t]*} $text " "]
        set text [regsub -all {\{\s+} $text "\{"]
        set text [regsub -all {\s+\}} $text "\}"]
        set out {}
        foreach line [split $text "\n"] {
            set line [string trim $line]
            if {$line eq "" || [string index $line 0] eq "#"} {
                continue
            }
            lappend out {*}[regexp -all -inline {\S+} $line]
        }
        return $out
    }

    proc verify {dir paths} {
        global ROOT
        set changed 0
        set bad 0
        set jl {}
        if {![llength $paths]} {
            set paths [list $ROOT]
        }
        set all {}
        foreach p $paths {
            lappend all {*}[files $p]
        }
        foreach f $all {
            set old [file join $dir $f]
            if {![file exists $old]} {
                continue
            }
            set a [read_utf8 $old]
            set b [read_utf8 [file join $ROOT $f]]
            if {$a eq $b} {
                continue
            }
            incr changed
            switch -- [file extension $f] {
                .jl {lappend jl $f}
                .tcl - .test - .yml - .scss {
                    if {[tcl_words $a] ne [tcl_words $b]} {
                        puts "DIFFERENT CODE: $f"
                        incr bad
                    }
                }
            }
        }
        if {[llength $jl]} {
            if {[catch {find_julia} julia]} {
                fail linelen.tcl $julia
            }
            set cmd [list $julia --startup-file=no \
                [file join $ROOT test utils ast_same.jl] $dir $ROOT {*}$jl]
            if {[catch {exec {*}$cmd <@stdin >@stdout 2>@stderr}]} {
                incr bad
            }
        }
        puts "verify: $changed changed file(s) ([llength $jl] Julia),\
            [expr {$bad ? "DIFFERENCES FOUND" : "same code"}]"
        if {$bad} {
            exit 1
        }
    }


    # Words of a paragraph: backtick code spans and the target of a
    # Markdown link `[text](target)` stay in one piece (a space inside
    # them is not a break). With an odd number of backticks plain words.
    proc words {text} {
        if {[regexp -all {`} $text] % 2} {
            return [regexp -all -inline {\S+} $text]
        }
        set out {}
        set cur ""
        set code 0
        set link 0
        set prev ""
        foreach c [split $text ""] {
            if {$c eq "`"} {
                set code [expr {!$code}]
            } elseif {!$code} {
                if {$c eq "(" && $prev eq "\]"} {
                    set link 1
                } elseif {$c eq ")" && $link} {
                    set link 0
                }
            }
            if {[string is space $c] && !$code && !$link} {
                if {$cur ne ""} {
                    lappend out $cur
                    set cur ""
                }
            } else {
                append cur $c
            }
            set prev $c
        }
        if {$cur ne ""} {
            lappend out $cur
        }
        return $out
    }

    # Greedy wrap of $words to lines of at most $w
    # characters after a prefix of $plen characters.
    proc greedy {words w} {
        set lines {}
        set cur ""
        foreach word $words {
            if {$cur eq ""} {
                set cur $word
            } elseif {[string length $cur] + 1 + [string length $word] <= $w} {
                append cur " " $word
            } else {
                lappend lines $cur
                set cur $word
            }
        }
        if {$cur ne ""} {
            lappend lines $cur
        }
        return $lines
    }

    # A line may not start with a token that Markdown
    # would read as a list, heading, quote or table.
    proc bad_start {line} {
        return [regexp {^(?:[-*+#>|=]|\d+[.)])(?:\s|$)|^```} $line]
    }

    # $words wrapped balanced into lines of at most $width characters: as few lines
    # as greedy needs, at the smallest width that still gives that many lines.
    proc balanced {words width} {
        set k [llength [greedy $words $width]]
        if {$k <= 1} {
            return [greedy $words $width]
        }
        set longest 0
        foreach w $words {
            set longest [expr {max($longest, [string length $w])}]
        }
        set lo [expr {max($longest, [string length [join $words " "]] / $k)}]
        for {set w $lo} {$w <= $width} {incr w} {
            set lines [greedy $words $w]
            if {[llength $lines] <= $k} {
                set ok 1
                foreach l [lrange $lines 1 end] {
                    if {[bad_start $l]} {
                        set ok 0
                    }
                }
                if {$ok} {
                    return $lines
                }
            }
        }
        return [greedy $words $width]
    }

    # Is this comment text the start of a list item, a
    # table row, an aligned column or other structure?
    proc structured {text} {
        return [regexp {^(?:[-*+]\s|\d+[.)]\s|\||```|[A-Za-z_0-9`]+\s*(?:=|:)\s*$)} $text]
    }

    # Re-wraps the paragraphs of $lines (a list of file
    # lines) that contain a long line; returns the new lines.
    proc reflow_lines {lines ext} {
        variable LIMIT
        set out {}
        set n [llength $lines]
        set i 0
        set in_doc 0
        while {$i < $n} {
            set line [lindex $lines $i]
            # docstring state (Julia): a line that is exactly """ opens or closes one
            if {$ext eq ".jl" && [string trim $line] eq "\"\"\""} {
                set in_doc [expr {!$in_doc}]
                lappend out $line
                incr i
                continue
            }
            if {
                $ext eq ".jl" && !$in_doc && [regexp {^("|""")} $line]
                && [regexp {^"[^"]*"$} $line] && [string length $line] > $LIMIT
            } {
                # a one-line docstring that is too long becomes a block docstring
                set text [string range $line 1 end-1]
                lappend out {"""}
                foreach l [balanced [words $text] $LIMIT] {
                    lappend out $l
                }
                lappend out {"""}
                incr i
                continue
            }
            # a list item in a docstring ("- text" with
            # its indented continuation lines), too long
            if {
                $ext eq ".jl" && $in_doc
                && [regexp {^(\s*)([-*]\s+|\d+[.)]\s+)(\S.*)$} $line -> ind mark text]
            } {
                set parts [list $text]
                set hang ""
                set j [expr {$i + 1}]
                while {$j < $n} {
                    set nxt [lindex $lines $j]
                    if {
                        [string trim $nxt] eq ""
                        || [regexp {^\s*([-*]\s|\d+[.)]\s|```|#|@|\||")} $nxt]
                        || ![regexp {^(\s+)(\S.*)$} $nxt -> h2 t2]
                    } {
                        break
                    }
                    if {$hang eq ""} {
                        set hang $h2
                    }
                    lappend parts $t2
                    incr j
                }
                set long 0
                if {[string length $line] > $LIMIT} {
                    set long 1
                }
                for {set k 1} {$k < [llength $parts]} {incr k} {
                    if {[string length $hang[lindex $parts $k]] > $LIMIT} {
                        set long 1
                    }
                }
                if {$long} {
                    if {$hang eq ""} {
                        set mark_width [string length $ind$mark]
                        set hang [string repeat " " [expr {max($mark_width, 4)}]]
                    }
                    set first $ind$mark
                    set lead [string length $first]
                    set w1 $LIMIT
                    set ws [words [join $parts " "]]
                    # balanced over the narrower of the two widths
                    set wd [expr {$LIMIT - max($lead, [string length $hang])}]
                    set bl [balanced $ws $wd]
                    lappend out $first[lindex $bl 0]
                    foreach l [lrange $bl 1 end] {
                        lappend out $hang$l
                    }
                } else {
                    for {set k $i} {$k < $j} {incr k} {
                        lappend out [lindex $lines $k]
                    }
                }
                set i $j
                continue
            }
            # a trailing comment that makes a code line
            # too long moves above the line (Julia)
            if {
                $ext eq ".jl" && !$in_doc && [string length $line] > $LIMIT
                && [regexp {^(\s*)([^#\s][^#]*?)\s+# (\S.*)$} $line -> ind code cmt]
                && [expr {[regexp -all {"} $code] % 2}] == 0 && ![regexp {^\s*"} $code]
            } {
                set w [expr {$LIMIT - [string length $ind] - 2}]
                foreach l [balanced [words $cmt] $w] {
                    lappend out "$ind# $l"
                }
                lappend out $ind$code
                incr i
                continue
            }
            # a paragraph: comment lines `# text` with one indent, or plain docstring lines
            set para {}
            set prefix ""
            if {[regexp {^(\s*#) (\S.*)$} $line -> pre text] && $ext in {.jl .tcl .test}} {
                set j $i
                while {
                    $j < $n
                    && [regexp {^(\s*#) (\S.*)$} [lindex $lines $j] -> p2 t2]
                    && $p2 eq $pre && ![structured $t2] && ![regexp {^#+\s*[-=─]{3}} $t2]
                } {
                    lappend para $t2
                    incr j
                }
                set prefix "$pre "
            } elseif {
                $ext eq ".jl" && $in_doc && [regexp {^\S} $line] && ![structured $line]
                && ![regexp {^[@#!]} $line]
            } {
                set j $i
                while {
                    $j < $n && [regexp {^\S} [lindex $lines $j]]
                    && ![structured [lindex $lines $j]]
                    && ![regexp {^[@#!"]} [lindex $lines $j]]
                } {
                    lappend para [lindex $lines $j]
                    incr j
                }
            } else {
                lappend out $line
                incr i
                continue
            }
            if {![llength $para]} {
                lappend out $line
                incr i
                continue
            }
            set long 0
            foreach t $para {
                if {[string length $prefix$t] > $LIMIT} {
                    set long 1
                }
            }
            if {!$long} {
                foreach t $para {
                    lappend out $prefix$t
                }
            } else {
                set w [expr {$LIMIT - [string length $prefix]}]
                foreach l [balanced [words [join $para " "]] $w] {
                    lappend out $prefix$l
                }
            }
            set i $j
        }
        return $out
    }

    proc reflow {paths} {
        global ROOT
        if {![llength $paths]} {
            set paths [list $ROOT]
        }
        set n 0
        foreach p $paths {
            foreach f [files $p] {
                set ext [file extension $f]
                if {$ext ni {.jl .tcl .test}} {
                    continue
                }
                set path [file join $ROOT $f]
                set old [split [read_utf8 $path] "\n"]
                set new [reflow_lines $old $ext]
                if {$new ne $old} {
                    set ch [open $path w]
                    fconfigure $ch -encoding utf-8 -translation lf
                    puts -nonewline $ch [join $new "\n"]
                    close $ch
                    incr n
                }
            }
        }
        puts "reflow: $n file(s) rewritten"
    }

    proc run {argv} {
        if {![llength $argv] || "--help" in $argv || "-h" in $argv} {
            ::usage $::SCRIPT
            return
        }
        set cmd [lindex $argv 0]
        set rest [lrange $argv 1 end]
        switch -- $cmd {
            --check {check $rest}
            --snapshot {
                if {[llength $rest] != 1} {fail linelen.tcl "--snapshot needs a directory"}
                snapshot [lindex $rest 0]
            }
            --verify {
                if {![llength $rest]} {
                    fail linelen.tcl "--verify needs the snapshot directory"
                }
                verify [lindex $rest 0] [lrange $rest 1 end]
            }
            --reflow {reflow $rest}
            default {
                fail linelen.tcl "unknown option $cmd (one of: --check, --snapshot,\
                    --verify, --reflow)"
            }
        }
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main linelen::run $argv
}
