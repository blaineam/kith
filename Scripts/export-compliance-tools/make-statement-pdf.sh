#!/usr/bin/env bash
# Regenerate the ASC encryption documentation PDF from the statement text.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cupsfilter "$HERE/encryption-statement.txt" > "$HERE/../export-compliance/haven-encryption-statement.pdf" 2>/dev/null
echo "wrote haven-encryption-statement.pdf"
