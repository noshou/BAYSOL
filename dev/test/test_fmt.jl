# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of Fmt: the license header, the SCSS indentation, the re-wrapping of prose, the
# line-length rule, and the release-name, setting-name and settings-page checks.

using Test

# --- Format

module TFormat
using Test
using Dev.Common
using Dev.Fmt
using .Main.Helpers

lines(xs...) = join(xs, "\n")

const SPDX = "SPDX-License-Identifier: LGPL-3.0-or-later"

@testset "an unknown option is refused before any formatter runs" begin
    status, out = run_tool("fmt", "--bogus")
    @test status == 2 && says(out, "unknown option --bogus")
end

@testset "the header is inserted first, in the file's comment syntax" begin
    @test Fmt.with_header("x = 1", ".jl") == lines("# $SPDX", "", "x = 1")
    @test Fmt.with_header("export {}", ".ts") == lines("// $SPDX", "", "export {}")
    @test Fmt.with_header("<A />", ".tsx") == lines("// $SPDX", "", "<A />")
    @test Fmt.with_header("export {}", ".mts") == lines("// $SPDX", "", "export {}")
    @test Fmt.with_header("a {}", ".scss") == lines("// $SPDX", "", "a {}")
    @test Fmt.with_header("name: x", ".yml") == "name: x"
    @test Fmt.with_header("\"\"\"Doc.\"\"\"", ".jl") ==
          lines("# $SPDX", "", "\"\"\"Doc.\"\"\"")
end

@testset "the header follows a shebang on the next line" begin
    @test Fmt.with_header(lines("#!/usr/bin/env node", "export {}"), ".ts") ==
          lines("#!/usr/bin/env node", "// $SPDX", "", "export {}")
    @test Fmt.with_header(lines("#!/usr/bin/env node", "// $SPDX", "// about"), ".ts") ==
          lines("#!/usr/bin/env node", "// $SPDX", "", "// about")
end

@testset "a correct header is left alone" begin
    for (ext, prefix) in ((".jl", "#"), (".ts", "//"), (".scss", "//"))
        text = lines("$prefix $SPDX", "", "body", "", "", "more")
        @test Fmt.with_header(text, ext) == text
    end
    text = lines("# $SPDX", "", "", "x")
    @test Fmt.with_header(text, ".jl") == text
    text = lines("# $SPDX", "", "x") * "\n"
    @test Fmt.with_header(text, ".jl") == text
    @test Fmt.with_header("x\n", ".jl") == lines("# $SPDX", "", "x") * "\n"
end

@testset "a missing blank line or a stale identifier is repaired" begin
    @test Fmt.with_header(lines("# $SPDX", "x = 1"), ".jl") == lines("# $SPDX", "", "x = 1")
    @test Fmt.with_header(
        lines("# SPDX-License-Identifier: LGPL-3.1-or-later", "", "x = 1"), ".jl") ==
          lines("# $SPDX", "", "x = 1")
    @test Fmt.with_header(lines("x = 1", "# $SPDX"), ".jl") ==
          lines("# $SPDX", "", "x = 1", "# $SPDX")
end

@testset "odd files" begin
    @test Fmt.with_header("", ".jl") == "# $SPDX\n"
    @test Fmt.with_header("# $SPDX\n", ".jl") == "# $SPDX\n"
    @test Fmt.with_header("{\"a\": 1}", ".json") == "{\"a\": 1}"
end

@testset "with_header is idempotent" begin
    for text in
        ["", "x", "x\n", "#!/usr/bin/env node\nexport {}",
            "# SPDX-License-Identifier: X\ny",
            "# $SPDX\ny", "# $SPDX\n\n\ny\n"],
        ext in (".jl", ".ts")

        once = Fmt.with_header(text, ext)
        @test Fmt.with_header(once, ext) == once
    end
end

@testset "check lists and apply repairs, in an isolated folder" begin
    dir = scratch_dir()
    stub = joinpath(dir, "biome-stub")
    write(stub, "#!/bin/sh\nexit 0\n")
    chmod(stub, 0o755)
    write_file(joinpath(dir, "a.ts"), "export {}  \n\n\n")
    write_file(joinpath(dir, "types.d.ts"), "declare const x: number\t\n")
    write_file(joinpath(dir, "b.ts"), "// $SPDX\n\nexport {}\n")
    write_file(joinpath(dir, "c.jl"), "x = 1\n")
    write_file(joinpath(dir, "notes.txt"), "plain\n")
    status, out = withenv(() -> run_tool("fmt", "--check", "--ts", dir), "BIOME" => stub)
    @test status == 1
    @test says(out, "license header missing:", "a.ts", "types.d.ts", "not formatted:")
    @test !occursin("b.ts", out)
    @test read(joinpath(dir, "a.ts"), String) == "export {}  \n\n\n"
    @test read(joinpath(dir, "c.jl"), String) == "x = 1\n"
    status, out = withenv(() -> run_tool("fmt", "--ts", dir), "BIOME" => stub)
    @test status == 0
    @test read(joinpath(dir, "a.ts"), String) == "// $SPDX\n\nexport {}\n"
    @test read(joinpath(dir, "types.d.ts"), String) ==
          "// $SPDX\n\ndeclare const x: number\n"
    @test read(joinpath(dir, "c.jl"), String) == "x = 1\n"    # --ts leaves Julia files
    @test read(joinpath(dir, "notes.txt"), String) == "plain\n"
    @test withenv(() -> run_tool("fmt", "--check", "--ts", dir), "BIOME" => stub)[1] == 0
end

@testset "the scss flag checks only SCSS headers" begin
    dir = scratch_dir()
    write_file(joinpath(dir, "a.scss"), "a {}\n")
    write_file(joinpath(dir, "b.ts"), "export {}\n")
    status, out = run_tool("fmt", "--check", "--scss", dir)
    @test status == 1 && occursin("a.scss", out) && !occursin("b.ts", out)
    @test run_tool("fmt", "--scss", dir)[1] == 0
    @test read(joinpath(dir, "a.scss"), String) == "// $SPDX\n\na {}\n"
    @test read(joinpath(dir, "b.ts"), String) == "export {}\n"
end

@testset "SCSS nesting is four spaces a level" begin
    @test Fmt.reindent_scss(
        lines("a {", "color: red;", "  b {", "      margin: 0;", "  }",
            "      }"),
    ) == lines("a {", "    color: red;", "    b {", "        margin: 0;", "    }", "}")
    @test Fmt.reindent_scss(lines("a {  ", "\t\tcolor: red;   ", "}")) ==
          lines("a {", "    color: red;", "}")
end

@testset "a declaration continues one level in" begin
    @test Fmt.reindent_scss(
        lines("a {", "src: url(\"a.woff2\") format(\"woff2\"),",
            "url(\"b.woff2\");", "color: red;", "}"),
    ) ==
          lines("a {", "    src: url(\"a.woff2\") format(\"woff2\"),",
        "        url(\"b.woff2\");",
        "    color: red;", "}")
    @test Fmt.reindent_scss(lines("\$f: \"A\", \"B\",", "\"C\";", "a {}")) ==
          lines("\$f: \"A\", \"B\",", "    \"C\";", "a {}")
    @test Fmt.reindent_scss(lines("a:hover,", "  b,", "      c {", "x: y;", "}")) ==
          lines("a:hover,", "b,", "c {", "    x: y;", "}")
    @test Fmt.reindent_scss(
        lines("\$m: (", "'a': 1,", "        'b': 2,", "    );", "a {}"),
    ) ==
          lines("\$m: (", "    'a': 1,", "    'b': 2,", ");", "a {}")
end

@testset "strings, comments and urls hide brackets" begin
    @test Fmt.reindent_scss(lines("a {", "content: \"{\"; // }", "b: c;", "}")) ==
          lines("a {", "    content: \"{\"; // }", "    b: c;", "}")
    @test Fmt.reindent_scss(
        lines("a {", "background: url(http://x.org/a'b);", "b: c;", "}"),
    ) ==
          lines("a {", "    background: url(http://x.org/a'b);", "    b: c;", "}")
    @test Fmt.reindent_scss(lines("a {", "width: #{\$w}px;", "b: c;", "}")) ==
          lines("a {", "    width: #{\$w}px;", "    b: c;", "}")
end

@testset "SCSS comments" begin
    @test Fmt.reindent_scss(
        lines("// top", "a {", "// inside", "b: c;", "      // last",
            "}"),
    ) == lines("// top", "a {", "    // inside", "    b: c;", "    // last", "}")
    @test Fmt.reindent_scss(lines("a {", "/* one", "     two */", "b: c;", "}")) ==
          lines("a {", "    /* one", "     two */", "    b: c;", "}")
    text = lines("a {}", "", "", "b {}", "")
    @test Fmt.reindent_scss(text) == text
end

@testset "SCSS reindent is idempotent" begin
    for text in [lines("a {", "b: c,", "d;", "}"), lines("\$m: (", "'a': 1", ");"), "",
        "a{b:c}", lines("x {", "/* a", "b */", "y: z", "}")]
        once = Fmt.reindent_scss(text)
        @test Fmt.reindent_scss(once) == once
    end
end

@testset "the repository's SCSS files are fixed points" begin
    for f in code_files(root())
        endswith(f, ".scss") || continue
        text = slurp8(in_root(f))
        @test Fmt.reindent_scss(text) == text
    end
end

@testset "fmt on SCSS in an isolated folder" begin
    dir = scratch_dir()
    file = joinpath(dir, "t.scss")
    write_file(file, "a {\ncolor: red;\n}\n")
    status, out = run_tool("fmt", "--check", "--scss", dir)
    @test status == 1 && occursin("not formatted:", out)
    @test read(file, String) == "a {\ncolor: red;\n}\n"
    @test run_tool("fmt", "--scss", dir)[1] == 0
    @test read(file, String) == "// $SPDX\n\na {\n    color: red;\n}\n"
    @test run_tool("fmt", "--check", "--scss", dir)[1] == 0
end

@testset "the release name must fit the main menu" begin
    toml(
        version,
        release,
    ) = "name = \"BAYSOL\"\nversion = \"$version\"\nrelease_name = \"$release\"\n"
    @test Fmt.version_name(toml("0.4.0", "yals-n-gɛsga")) == "v0.4.0-yals-n-gɛsga"
    @test Fmt.version_problem(toml("0.4.0", "yals-n-gɛsga")) === nothing
    @test Fmt.version_problem(toml("0.4.0", "a"^28)) === nothing
    @test Fmt.version_problem(toml("0.4.0", "a"^29)) !== nothing
    @test Fmt.version_problem("name = \"BAYSOL\"\nversion = \"0.4.0\"\n") !== nothing
    @test Fmt.version_problem(slurp8(in_root("Project.toml"))) === nothing
end

@testset "setting names fit the sheets" begin
    @test Fmt.parameter_names(
        lines("# comment", "const A_B = 1", "const C::Int = 2", "x = 3"),
    ) ==
          ["A_B", "C"]
    ok = "A"^Fmt.MAX_PARAMETER_NAME_LENGTH
    too_long = ok * "B"
    @test isempty(Fmt.parameter_problems("const $ok = 1"))
    @test length(Fmt.parameter_problems("const $too_long = 1")) == 1
    @test occursin(too_long, first(Fmt.parameter_problems("const $too_long = 1")))
    for d in readdir(in_root("src"))
        f = in_root("src", d, "Params.jl")
        isfile(f) && @test isempty(Fmt.parameter_problems(slurp8(f)))
    end
end

const PAGE_HEADER =
    "   ║        name            ║" * "        description          ║" *
    "      value        ║"
const PAGE_RULE_UNDER =
    "   ╠════════════════════════╬" * "═════════════════════════════╬" *
    "═══════════════════╣"
const PAGE_BOTTOM =
    "   ╚════════════════════════╩" * "═════════════════════════════╬" *
    "═══════════════════╣"

# A first line of a setting: the marker or 3 spaces, then the three fields.
name_row(marked, setting, desc) =
    (marked ? " > " : "   ") * "╠" * rpad(" $setting", 24) *
    "╬" * rpad(" $desc", 29) * "╬" * " "^19 * "╣"
# A continuation line: the three fields with a description.
more_row(desc) = "   ║" * " "^24 * "║" * rpad(" $desc", 29) * "║" * " "^19 * "║"
page(body...) = lines(PAGE_HEADER, PAGE_RULE_UNDER, body..., PAGE_BOTTOM, "   footer")

@testset "settings pages are well formed" begin
    @test isempty(
        Fmt.page_problems(
            page(
                name_row(true, "PLOT_HIST_BINS", "Bins in the histogram."),
                more_row("More of it."),
                name_row(false, "PLOT_FONT", "A font."),
            ),
        ),
    )
    @test any(
        occursin("0 times", p) for p in
        Fmt.page_problems(page(name_row(false, "A", "a"), name_row(false, "B", "b")))
    )
    @test any(
        occursin("2 times", p) for p in
        Fmt.page_problems(page(name_row(true, "A", "a"), name_row(true, "B", "b")))
    )
    @test any(
        occursin("continuation", p) for p in Fmt.page_problems(page(
            name_row(true, "A", "a"), " > " * more_row("x")[4:end]))
    )
    bad = replace(name_row(true, "A", "a"), "╬" => "║")
    @test any(startswith(p, "line 3:") for p in Fmt.page_problems(page(bad)))
    @test !isempty(Fmt.page_problems(page(name_row(true, "A", "a"), more_row("x") * " ")))
    @test !isempty(Fmt.page_problems(page(name_row(true, "A", "a"), more_row("x")[2:end])))
    @test !isempty(Fmt.page_problems(page(name_row(true, "A", "a"), more_row("x") * "║")))
    @test !isempty(
        Fmt.page_problems(replace(page(name_row(true, "A", "a")), "name" => "NAME")),
    )
    @test !isempty(
        Fmt.page_problems(replace(page(name_row(true, "A", "a")), PAGE_BOTTOM => "   ╚")),
    )
    real = split(
        slurp8(in_root("tui", "resources", "plots-settings", "pages", "page1.txt")),
        "\n",
    )
    @test real[1] == PAGE_HEADER && real[2] == PAGE_RULE_UNDER
end

@testset "trailing spaces are trimmed" begin
    @test Fmt.trim_trailing_space("a  \n b\t\n  \nc") == "a\n b\n\nc"
    @test Fmt.trim_trailing_space("║ x ║   \n") == "║ x ║\n"
    @test Fmt.trim_trailing_space("a\n b") == "a\n b"
end

end

# --- Biome

module TBiome

using Test
using Dev
using Dev.Common
using .Main.Helpers

# A stand-in for Biome that records its arguments and exits with `STUB_EXIT`.
function stub(dir)
    path = joinpath(dir, "biome-stub")
    write(path, "#!/bin/sh\necho \"\$@\" >> \"\$STUB_LOG\"\nexit \${STUB_EXIT:-0}\n")
    chmod(path, 0o755)
    return path
end

SPDX = "SPDX-License-Identifier: LGPL-3.0-or-later"

if !Sys.iswindows()
    @testset "TypeScript layout and lint are Biome's: how it is called" begin
        dir = scratch_dir()
        log = joinpath(dir, "calls.log")
        write_file(joinpath(dir, "a.ts"), "// $SPDX\n\nexport {}\n")
        withenv("BIOME" => stub(dir), "STUB_LOG" => log, "STUB_EXIT" => "0") do
            @test run_tool("fmt", "--check", "--ts", dir)[1] == 0
            @test run_tool("fmt", "--ts", dir)[1] == 0
        end
        calls = split(strip(read(log, String)), '\n')
        @test length(calls) == 2
        @test startswith(calls[1], "check --config-path=") && !occursin("--write", calls[1])
        @test startswith(calls[2], "check --write --config-path=")
        @test all(c -> occursin(joinpath(dir, "a.ts"), c), calls)
        # a failure of Biome fails the step
        withenv("BIOME" => stub(dir), "STUB_LOG" => log, "STUB_EXIT" => "1") do
            @test run_tool("fmt", "--check", "--ts", dir)[1] == 1
        end
    end

    @testset "no TypeScript file, no Biome call" begin
        dir = scratch_dir()
        log = joinpath(dir, "calls.log")
        write_file(joinpath(dir, "c.jl"), "x = 1\n")
        withenv("BIOME" => stub(dir), "STUB_LOG" => log) do
            @test run_tool("fmt", "--check", "--ts", dir)[1] == 0
        end
        @test !ispath(log)
    end

    @testset "TypeScript files without Biome installed fail with a message" begin
        dir = scratch_dir()
        write_file(joinpath(dir, "a.ts"), "// $SPDX\n\nexport {}\n")
        # an empty root hides the repository's node_modules, PATH hides a global Biome
        withenv("BIOME" => nothing, "PATH" => "/usr/bin:/bin", "BAYSOL_ROOT" => dir) do
            Sys.which("biome") === nothing || return
            ok = Ref(true)
            _, out = run_tool_call() do
                ok[] = Dev.Fmt.format_ts(false, [dir])
            end
            @test !ok[] && occursin("Biome is not installed", out)
        end
    end
end

end

# --- Reflow

module TReflow
using Test
using Dev.Common
using Dev.Fmt
using .Main.Helpers

words_of(lines) = String[m.match for m in eachmatch(r"\S+", join(lines, " "))]

@testset "balanced: no orphan" begin
    lines = Fmt.balanced(fill("abcdefghi", 19), 92)
    @test length(lines) == 3
    @test length(last(lines)) > 40
end

@testset "balanced keeps the words" begin
    ws = split("the quick brown fox jumps over the lazy dog and keeps running far away")
    @test String.(ws) == words_of(Fmt.balanced(String.(ws), 30))
end

@testset "balanced: a code span is one piece" begin
    text =
        "text before `a span with spaces` and text after, " *
        "enough words to need wrapping here"
    @test all(l -> iseven(count('`', l)), Fmt.balanced(Fmt.words(text), 30))
end

@testset "balanced: no Markdown start" begin
    ws = String.(
        split("aaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbb - cccccccccccccccccccc dddd"),
    )
    @test !any(Fmt.bad_start, Fmt.balanced(ws, 45)[2:end])
end

@testset "a comment block with a long line is re-wrapped under the same prefix" begin
    long_line = "    # " * repeat("word ", 25) * "end"
    wrapped = Fmt.reflow_lines([long_line], "jl")
    @test length(wrapped) == 2
    @test startswith(first(wrapped), "    # ")
    @test filter(!=("#"), words_of([long_line])) == filter(!=("#"), words_of(wrapped))
    @test all(l -> length(l) <= 92, wrapped)
end

@testset "the same for the // comments of TypeScript" begin
    long_line = "// " * repeat("word ", 30) * "end"
    wrapped = Fmt.reflow_lines([long_line], "ts")
    @test length(wrapped) > 1
    @test all(l -> startswith(l, "// "), wrapped)
    @test all(l -> length(l) <= 92, wrapped)
end

@testset "nothing changes when no line is too long" begin
    lines = ["# a short comment", "# and another", "x = 1"]
    @test Fmt.reflow_lines(lines, "jl") == lines
end

@testset "indented text in a docstring is not re-wrapped" begin
    lines = ["\"\"\"", "    " * repeat("x", 120), "\"\"\""]
    @test Fmt.reflow_lines(lines, "jl") == lines
end

@testset "a trailing comment that makes a Julia line too long moves above it" begin
    line = "    x = f(y)  # " * repeat("word ", 20) * "end"
    wrapped = Fmt.reflow_lines([line], "jl")
    @test last(wrapped) == "    x = f(y)"
    @test first(wrapped)[5] == '#'
end

@testset "a plain triple-quoted string is not taken for a docstring" begin
    # the closing fence of `USAGE` must not open a docstring: the long string literal
    # after it is code, and its spaces are not collapsed
    code = ["const USAGE = \"\"\"", "text    with   spaces", "\"\"\"", "",
        "const BAR =", "    \"" * repeat("a  b ", 20) * "\"",
        "const X = \"" *
        repeat("c  d ", 20) * "\""]
    @test Fmt.reflow_lines(code, "jl") == code
end

const LONG_COMMENT = "# " * repeat("word ", 30) * "end"

@testset "reflow_files: check, then apply" begin
    dir = scratch_dir()
    write_file(joinpath(dir, "a.jl"), LONG_COMMENT * "\nx = 1\n")
    Common.ROOT_OVERRIDE[] = dir
    try
        before = read(joinpath(dir, "a.jl"), String)
        @test Fmt.reflow_files(false, :julia, [dir]) == ["a.jl"]
        @test read(joinpath(dir, "a.jl"), String) == before
        @test length(Fmt.reflow_files(true, :julia, [dir])) == 1
        @test isempty(Fmt.reflow_files(true, :julia, [dir]))
        @test read(joinpath(dir, "a.jl"), String) != before
        @test isempty(Fmt.reflow_files(false, :ts, [dir]))
    finally
        Common.ROOT_OVERRIDE[] = nothing
    end
end

@testset "long SCSS comments are re-wrapped" begin
    long_line = "// " * join(fill("word", 30), " ")
    out = Fmt.reflow_lines([long_line], "scss")
    @test length(out) > 1
    @test all(l -> startswith(l, "// "), out)
    @test all(l -> length(l) <= Common.LINE_LIMIT, out)
    @test Fmt.reflow_lines(["// short"], "scss") == ["// short"]
end

end
