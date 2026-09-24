#!/bin/bash
# ShellCheck over every tracked shell script: *.sh and anything with a
# bash/sh shebang. Settings are in the repo's .shellcheckrc.
set -euo pipefail
cd "$(dirname "$0")/.."

files=()
while IFS= read -r -d '' f; do
  if [[ $f == *.sh ]] || head -n1 -- "$f" | grep -Eq '^#!.*\b(ba)?sh\b'; then
    files+=("$f")
  fi
done < <(git ls-files -z)

shellcheck -- "${files[@]}"
