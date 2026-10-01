#!/bin/bash
# Bumps the iceKast version in project.yml.
#
#   scripts/bump-version.sh beta            1.0b1 -> 1.0b2   (next beta of the same version)
#   scripts/bump-version.sh final           1.0b2 -> 1.0     (drop the beta suffix)
#   scripts/bump-version.sh start 1.1       -> 1.1b1         (begin betas of a new version)
#   add --commit to also commit the change and tag it (v1.0b2); never pushes.
#
# Public version (CFBundleShortVersionString): MAJOR.MINORbN  (e.g. 1.0b1) or MAJOR.MINOR when final.
# Internal build (CFBundleVersion): MAJOR.MINOR.PATCH.BUILD.BETA (e.g. 1.0.0.2.1).
# BUILD goes up on every release build; BETA is the beta number (0 for a final).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YML="${PROJECT_YML:-$ROOT/project.yml}"

cur_public=$(sed -nE 's/^ *MARKETING_VERSION: *"([^"]+)".*/\1/p' "$YML")
cur_build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"([^"]+)".*/\1/p' "$YML")
[ -n "$cur_public" ] && [ -n "$cur_build" ] || { echo "error: version settings not found in $YML" >&2; exit 1; }

# current state
if [[ "$cur_public" =~ ^([0-9]+(\.[0-9]+)*)b([0-9]+)$ ]]; then base="${BASH_REMATCH[1]}"; beta="${BASH_REMATCH[3]}"
elif [[ "$cur_public" =~ ^([0-9]+(\.[0-9]+)*)$ ]]; then base="${BASH_REMATCH[1]}"; beta=0
else echo "error: can't parse version '$cur_public'" >&2; exit 1; fi
IFS=. read -r -a bparts <<< "$cur_build"
[ "${#bparts[@]}" -eq 5 ] || { echo "error: build '$cur_build' is not MAJOR.MINOR.PATCH.BUILD.BETA" >&2; exit 1; }
build="${bparts[3]}"

cmd="${1:-}"; shift || true
commit=0
args=()
for a in "$@"; do if [ "$a" = "--commit" ]; then commit=1; else args+=("$a"); fi; done

case "$cmd" in
  beta)
    [ "$beta" -gt 0 ] || { echo "error: $cur_public is a final release; use 'start <version>' to begin new betas" >&2; exit 1; }
    beta=$((beta + 1)) ;;
  final)
    [ "$beta" -gt 0 ] || { echo "error: $cur_public is already final" >&2; exit 1; }
    beta=0 ;;
  start)
    [ "${#args[@]}" -eq 1 ] && [[ "${args[0]}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "usage: $0 start <MAJOR.MINOR>  e.g. start 1.1" >&2; exit 1; }
    base="${args[0]}"; beta=1 ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
build=$((build + 1))

# pad the base to MAJOR.MINOR.PATCH for the internal build number
IFS=. read -r -a b <<< "$base"
major="${b[0]}"; minor="${b[1]:-0}"; patch="${b[2]:-0}"
if [ "$beta" -gt 0 ]; then public="${base}b${beta}"; else public="$base"; fi
internal="${major}.${minor}.${patch}.${build}.${beta}"

sed -i '' -E "s/^( *MARKETING_VERSION: *)\"[^\"]+\"/\1\"$public\"/; s/^( *CURRENT_PROJECT_VERSION: *)\"[^\"]+\"/\1\"$internal\"/" "$YML"
echo "iceKast version: $cur_public ($cur_build)  ->  $public ($internal)"

# keep the README's stated version in sync when it is the real project file
if [ "$YML" = "$ROOT/project.yml" ] && grep -q '^\*\*Version ' "$ROOT/README.md"; then
  label="$public"; [ "$beta" -gt 0 ] && label="$public (beta)"
  sed -i '' -E "s/^\*\*Version .*\*\*$/**Version $label**/" "$ROOT/README.md"
  sed -i '' -E "s/^The public version is \`[^\`]+\` /The public version is \`$public\` /; s/^\`[0-9.]+\` \(\`CFBundleVersion\`\)/\`$internal\` (\`CFBundleVersion\`)/" "$ROOT/README.md"
fi

if [ "$commit" -eq 1 ]; then
  cd "$ROOT"
  git add project.yml README.md
  git commit -q -m "Version $public (build $internal)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
  git tag "v$public"
  echo "committed and tagged v$public (not pushed)"
fi
