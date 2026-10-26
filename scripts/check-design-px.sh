#!/bin/zsh
# Lists sizes in the UI code that are not in design px: a font size, spacing, padding, frame or corner radius written
# as a number of points, which would stay put while the rest of the window follows the UI scale. Every design number is
# written `14.px`, `.design(12)` or `.designMono(11)` (docs/ARCHITECTURE.md › Conventions). Zero, hairlines (0.5,
# `1 / displayScale`) and sizes derived from a scaled one (`size * 0.3`) are not design numbers; the pieces the system
# draws at its own size whatever the scale are listed in `allowed` below.
#
# Every size argument of a call is checked, also when it is a ternary (`compact ? 4 : 6`) or a call (`CGFloat(30)`),
# and a call's arguments may run over several lines; each size is reported on the line it is written on.
#
#   scripts/check-design-px.sh [file or folder…]    (default: Tidemark/UI)
#
# Prints every such size and exits with 1 if there is one.
set -euo pipefail

cd "${0:A:h}/.."
(( $# )) || set -- Tidemark/UI

# Lines that may keep points, as `path|extended regex the line matches`, each with the reason.
allowed=(
    # The probe window is sized for the web page in it, which keeps its CSS px whatever the scale.
    'Tidemark/UI/SiteProbe/ProbeBrowserWindow.swift|idealWidth: 1280'
    'Tidemark/UI/SiteProbe/ProbeBrowserWindow.swift|idealHeight: 824'
    # The iPhone frame drawn around the page's 393 CSS px viewport, which the scale must not change either.
    'Tidemark/UI/SiteProbe/ProbeBrowserWindow.swift|iphone \? (37|10|46|24) : 0'
    # The Domains & IPs header's rule, a hairline drawn 1.5 pt thick so it stays crisp under the row above it.
    'Tidemark/UI/Inventory/InventoryView.swift|frame\(height: 1\.5\)'
    # Xcode previews of the main window at the design's size.
    'Tidemark/UI/Shell/ShellDemoData.swift|frame\(width: 1248, height: 812\)'
)

files=("${(@f)$(find "$@" -name '*.swift' -type f | sort)}")
[[ -n ${files[1]:-} ]] || { echo "No Swift files in $*" >&2; exit 2; }

# Through the environment, which keeps the backslashes that `awk -v` would take as escapes.
ALLOWED="${(pj:\t:)allowed}" awk '
    BEGIN {
        count = split(ENVIRON["ALLOWED"], entries, "\t")
        for (i = 1; i <= count; i++) {
            bar = index(entries[i], "|")
            allowPath[i] = substr(entries[i], 1, bar - 1)
            allowLine[i] = substr(entries[i], bar + 1)
        }
        # The calls checked, up to their opening parenthesis, and which of their arguments are sizes: those whose
        # label matches, or with `-` the unlabeled ones. The spacing and corner radius arguments of the app
        # components are design px already.
        calls[1] = "\\.system\\(";              sizeArguments[1] = "^size$"
        calls[2] = "[sS]ystemFont\\(";          sizeArguments[2] = "^ofSize$"
        # Stacks, grids and layouts (`HStack(spacing: 8)`, `Grid(horizontalSpacing: 8)`).
        calls[3] = "(Stack|Grid|GridItem|Layout)\\("; sizeArguments[3] = "[sS]pacing$"
        calls[4] = "Spacer\\(";                 sizeArguments[4] = "^minLength$"
        # `.padding(8)`, `.padding(.horizontal, 8)`; not the edges, nor an `EdgeInsets`, which is a call of its own.
        calls[5] = "\\.padding\\(";             sizeArguments[5] = "-"
        calls[6] = "EdgeInsets\\(";             sizeArguments[6] = "^(top|leading|bottom|trailing|left|right)$"
        calls[7] = "\\.frame\\(";               sizeArguments[7] = "([wW]idth|[hH]eight)$"
        # `RoundedRectangle(cornerRadius: 8)`, `.rect(topLeadingRadius: 8)`.
        calls[8] = "(Rectangle|\\.rect)\\(";    sizeArguments[8] = "[rR]adius$"
        calls[9] = "\\.cornerRadius\\(";        sizeArguments[9] = "-"
        callCount = 9
        # Calls whose numbers are design px already: `UIScale.length(30, factor: f)`, `size.points(2)`.
        converting["length"] = converting["points"] = converting["design"] = converting["designMono"] = 1
        found = 0
    }
    FNR == 1 {
        if (NR > 1) checkFile()
        path = FILENAME
        lines = 0
        inComment = inString = 0
    }
    {
        source[++lines] = $0
        code[lines] = codeOf($0)
    }
    END {
        checkFile()
        if (found) {
            fflush()
            printf "\n%d size(s) in points; write them in design px (`N.px`, `.design(N)`) or allow them in %s.\n", found, "scripts/check-design-px.sh" > "/dev/stderr"
            exit 1
        }
    }

    # The line without its comments and without the text of its strings, which may hold `//`, parentheses or numbers.
    function codeOf(line,    out, i, n, c) {
        out = ""
        n = length(line)
        for (i = 1; i <= n; i++) {
            c = substr(line, i, 1)
            if (inComment) {
                if (substr(line, i, 2) == "*/") { inComment = 0; i++ }
            } else if (inString) {
                if (c == "\\") i++
                else if (inString == 3 && substr(line, i, 3) == "\"\"\"") { inString = 0; out = out "\"\"\""; i += 2 }
                else if (inString == 1 && c == "\"") { inString = 0; out = out c }
            } else if (substr(line, i, 2) == "//") {
                break
            } else if (substr(line, i, 2) == "/*") {
                inComment = 1; i++
            } else if (substr(line, i, 3) == "\"\"\"") {
                inString = 3; out = out "\"\"\""; i += 2
            } else {
                if (c == "\"") inString = 1
                out = out c
            }
        }
        # Only a multi-line string runs on to the next line.
        if (inString == 1) inString = 0
        return out
    }

    function checkFile(    i, c, rest, offset, open) {
        text = ""
        for (i = 1; i <= lines; i++) {
            lineStart[i] = length(text) + 1
            text = text code[i] "\n"
        }
        split("", sizesOnLine)
        for (c = 1; c <= callCount; c++) {
            offset = 0
            rest = text
            while (match(rest, calls[c])) {
                open = offset + RSTART + RLENGTH - 1
                checkArguments(open, sizeArguments[c])
                offset = open
                rest = substr(text, open + 1)
            }
        }
        for (i = 1; i <= lines; i++) {
            if (!(i in sizesOnLine) || isAllowed(path, source[i])) continue
            line = source[i]
            sub(/^[ \t]+/, "", line)
            printf "%s:%d: %s\n", path, i, line
            found += sizesOnLine[i]
        }
    }

    # Checks the size arguments of the call whose `(` is at `open` in `text`.
    function checkArguments(open, sizes,    i, n, c, depth, start) {
        n = length(text)
        depth = 0
        start = open + 1
        for (i = open + 1; i <= n; i++) {
            c = substr(text, i, 1)
            if (c == "(" || c == "[" || c == "{") {
                depth++
            } else if (depth == 0 && (c == ")" || c == ",")) {
                checkArgument(start, i - 1, sizes)
                if (c == ")") return
                start = i + 1
            } else if (c == ")" || c == "]" || c == "}") {
                depth--
            }
        }
    }

    function checkArgument(start, end, sizes,    argument, label) {
        argument = substr(text, start, end - start + 1)
        if (match(argument, /^[ \t\n]*[A-Za-z_][A-Za-z0-9_]*[ \t\n]*:/)) {
            label = substr(argument, RSTART, RLENGTH - 1)
            gsub(/[ \t\n]/, "", label)
            if (sizes != "-" && label ~ sizes) checkExpression(start + RLENGTH, end)
        } else if (sizes == "-" && argument !~ /^[ \t\n]*[.[]/ && argument !~ /EdgeInsets\(/) {
            checkExpression(start, end)
        }
    }

    # Counts the design numbers in the expression from `start` to `end` in `text`: every number literal but zero and
    # hairlines (0.5 and 1 pt, which the scale leaves as they are), one in a parenthesized expression scaled as a whole
    # (`(compact ? 14 : 18).px`), a factor or divisor, also one in parentheses or a call (`size * 0.3`, `1 / displayScale`,
    # `width / max(total, 0.001)`), the operand of a comparison, a number in px already (`14.px`, `points(2)`) and an
    # index.
    function checkExpression(start, end,    i, c, j, k, depth, enclosing, factor, token, value, before, after, opens, top, scaledFrom, scaledTo, scaledCount) {
        # Parenthesized expressions followed by `.px`: their numbers are design px.
        top = scaledCount = 0
        for (i = start; i <= end; i++) {
            c = substr(text, i, 1)
            if (c == "(") opens[++top] = i
            else if (c == ")" && top > 0) {
                if (substr(text, i + 1, 3) == ".px") { scaledFrom[++scaledCount] = opens[top]; scaledTo[scaledCount] = i }
                top--
            }
        }
        depth = 0
        split("", enclosing)
        split("", factor)
        for (i = start; i <= end; i++) {
            c = substr(text, i, 1)
            if (c == "(" || c == "[") {
                enclosing[++depth] = c == "[" ? "[" : nameBefore(i)
                factor[depth] = c == "(" && isFactor(start, i)
                continue
            }
            if (c == ")" || c == "]") {
                if (depth > 0) depth--
                continue
            }
            if (c !~ /[0-9]/) continue
            token = substr(text, i, end - i + 1)
            match(token, /^[0-9]+(\.[0-9]+)?/)
            token = substr(token, 1, RLENGTH)
            j = i + RLENGTH
            # Part of a name, or of a hex or exponent literal.
            if (substr(text, i - 1, 1) ~ /[A-Za-z0-9_.]/ || substr(text, j, 1) ~ /[A-Za-z0-9_]/) { i = j - 1; continue }
            before = lastCharacter(substr(text, start, i - start))
            after = substr(text, j, end - j + 1)
            sub(/^[ \t\n]+/, "", after)
            i = j - 1
            if (after ~ /^\.px([^A-Za-z0-9_]|$)/ || before ~ /[*\/<>=]/ || after ~ /^[*\/<>=!]/) continue
            value = token + 0
            if (value == 0 || value == 0.5 || value == 1 || insideExempt(enclosing, factor, depth)) continue
            for (k = 1; k <= scaledCount; k++) if (i > scaledFrom[k] && i < scaledTo[k]) break
            if (k <= scaledCount) continue
            sizesOnLine[lineOf(i)]++
        }
    }

    # The name a `(` at `position` in `text` calls, if any.
    function nameBefore(position,    head) {
        head = position > 64 ? substr(text, position - 64, 64) : substr(text, 1, position - 1)
        if (match(head, /[A-Za-z_][A-Za-z0-9_]*$/)) return substr(head, RSTART, RLENGTH)
        return ""
    }

    # Whether the `(` at `position` in `text`, in an expression from `start`, opens a factor or divisor: a call
    # (`max(total, 0.001)`, `CGFloat.maximum(…)`) or parentheses right after a `*` or `/`.
    function isFactor(start, position,    head) {
        head = substr(text, start, position - start)
        sub(/[A-Za-z0-9_.]*$/, "", head)
        return lastCharacter(head) ~ /[*\/]/
    }

    # Whether a number inside these parentheses and brackets is in px already, an index, or part of a factor or divisor.
    function insideExempt(enclosing, factor, depth,    k) {
        for (k = 1; k <= depth; k++) {
            if (enclosing[k] == "[" || enclosing[k] in converting || factor[k]) return 1
        }
        return 0
    }

    # The last character of `string` that is not white space.
    function lastCharacter(string) {
        sub(/[ \t\n]+$/, "", string)
        return substr(string, length(string), 1)
    }

    function lineOf(position,    low, high, middle) {
        low = 1
        high = lines
        while (low < high) {
            middle = int((low + high + 1) / 2)
            if (lineStart[middle] <= position) low = middle
            else high = middle - 1
        }
        return low
    }

    function isAllowed(path, line,    i) {
        for (i = 1; i <= count; i++) {
            if (allowPath[i] == path && line ~ allowLine[i]) return 1
        }
        return 0
    }
' "${files[@]}"
