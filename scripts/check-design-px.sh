#!/bin/zsh
# Lists sizes in the UI code that are not in design px: a font size, spacing, padding, frame or corner radius written
# as a number of points, which would stay put while the rest of the window follows the UI scale. Every design number is
# written `14.px`, `.design(12)` or `.designMono(11)` (docs/ARCHITECTURE.md › Conventions). Zero, hairlines (0.5,
# `1 / displayScale`) and sizes derived from a scaled one (`size * 0.3`) are not design numbers; the pieces the system
# draws at its own size whatever the scale are listed in `allowed` below.
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
        # A number ending an argument (`isDesignNumber` then lets zero and hairlines through).
        number = "-?([0-9]+(\\.[0-9]+)?|\\.[0-9]+) *[,)]"
        # Arguments up to the one checked, which may hold one level of parentheses.
        arguments = "([^()]|\\([^()]*\\))*"
        patterns[1] = "\\.system\\(size: *" number
        patterns[2] = "[sS]ystemFont\\(ofSize: *" number
        # Stacks, grids and layouts (`HStack(spacing: 8)`, `Grid(horizontalSpacing: 8)`), and spacers; the spacing
        # and corner radius arguments of the app components are design px already.
        patterns[3] = "(Stack|Grid|GridItem|Layout)\\(" arguments "[sS]pacing: *" number
        patterns[4] = "Spacer\\(minLength: *" number
        patterns[5] = "\\.padding\\((\\.[a-zA-Z]+, *|\\[[^]]*\\], *)?" number
        patterns[6] = "EdgeInsets\\(" arguments "(top|leading|bottom|trailing): *" number
        patterns[7] = "\\.frame\\(" arguments "([wW]idth|[hH]eight): *" number
        patterns[8] = "(Rectangle|\\.rect)\\(cornerRadius: *" number
        patterns[9] = "\\.cornerRadius\\( *" number
        patternCount = 9
        found = 0
    }
    function isAllowed(path, line,    i) {
        for (i = 1; i <= count; i++) {
            if (allowPath[i] == path && line ~ allowLine[i]) return 1
        }
        return 0
    }
    # The number a match ends with, which zero and hairlines may be.
    function isDesignNumber(fragment,    value) {
        match(fragment, /-?([0-9]+(\.[0-9]+)?|\.[0-9]+) *[,)]$/)
        value = substr(fragment, RSTART, RLENGTH) + 0
        return value != 0 && value != 0.5 && value != -0.5
    }
    /^[ \t]*\/\// { next }
    {
        line = $0
        # Trailing comments, but not the slashes of a URL in a string.
        sub(/[ \t]+\/\/[ \/].*$/, "", line)
        if (isAllowed(FILENAME, line)) next
        sizes = 0
        for (p = 1; p <= patternCount; p++) {
            rest = line
            while (match(rest, patterns[p])) {
                if (isDesignNumber(substr(rest, RSTART, RLENGTH))) sizes++
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
        if (sizes) {
            sub(/^[ \t]+/, "", line)
            printf "%s:%d: %s\n", FILENAME, FNR, line
            found += sizes
        }
    }
    END {
        if (found) {
            fflush()
            printf "\n%d size(s) in points; write them in design px (`N.px`, `.design(N)`) or allow them in %s.\n", found, "scripts/check-design-px.sh" > "/dev/stderr"
            exit 1
        }
    }
' "${files[@]}"
