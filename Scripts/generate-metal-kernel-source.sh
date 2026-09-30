#!/bin/sh
# Generates MetalKernelSource.generated.swift from the canonical MSL source.
# Usage: generate-metal-kernel-source.sh <input.metal> <output.swift>
#
# The .metal file is the single source of truth for the preview kernels.
# SwiftPM cannot compile .metal files in library targets, so the kernels are
# embedded as a string literal and compiled at runtime via makeLibrary(source:).
set -eu

input="$1"
output="$2"

{
    printf '%s\n' \
        '// Generated from Sources/SpektrafilmCore/SpektrafilmKernels.metal.' \
        '// Do not edit; run the MetalKernelSourcePlugin build tool (or this script) instead.' \
        'import Foundation' \
        '' \
        '#if canImport(Metal)' \
        'extension MetalAccelerator {' \
        '    static let source = #"""'
    # Swift multiline string literals require every content line to be indented
    # at least as much as the closing delimiter (4 spaces). Blank lines pass
    # through untouched.
    sed -e 's/^\(.\)/    \1/' "$input"
    printf '%s\n' \
        '    """#' \
        '}' \
        '#endif'
} > "$output"
