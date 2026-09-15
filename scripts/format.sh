#!/bin/zsh
set -eu
cd "${0:A:h:h}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if (( $# > 0 )); then
    files=("$@")
else
    files=("${(@f)$(find . -name '*.swift' -not -path './.git/*' -not -path './.build/*')}")
fi

(( ${#files[@]} > 0 )) || exit 0

xcrun swift-format format --in-place --configuration .swift-format "${files[@]}"
