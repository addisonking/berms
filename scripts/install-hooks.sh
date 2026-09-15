#!/bin/zsh
set -eu
cd "${0:A:h:h}"

git config core.hooksPath scripts/hooks
chmod +x scripts/format.sh scripts/lint.sh scripts/hooks/pre-commit
print "installed git hooks (core.hooksPath=scripts/hooks)"
