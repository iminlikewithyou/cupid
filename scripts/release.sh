#!/usr/bin/env bash
# release.sh: build a Cupid release locally; print (or, with --publish, run) the publish commands.
#
#   scripts/release.sh <version> [--notes FILE] [--publish | --dry-run]
#
# Releases are ad hoc signed (no Developer ID, no notarisation).
# 1. Pre-flight: on main, clean tree (VERSION may differ), gh logged in, tag v<version> absent
#    locally and on origin, <version> is semver, Resources/runtime/ has the archive and descriptor.
# 2. Writes VERSION, runs `swift build` and `swift test`, `scripts/build-app.sh --dmg`, then
#    build/Cupid-<version>.dmg.sha256 and (without --notes) build/notes-<version>.md.
# 3. Commits "Release <version>" (VERSION only), then creates the annotated tag v<version> last.
# 4. Prints `git push` and `gh release create`; --publish runs them instead.
# --dry-run does everything except the commit and the tag, and restores VERSION afterwards.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/build"
die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo "== $*"; }

version=""; notes=""; publish=0; dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) shift; notes="${1:?--notes needs a file}" ;;
        --publish) publish=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
        *) [ -z "$version" ] || die "only one version, got '$version' and '$1'"; version="$1" ;;
    esac
    shift
done
[ -n "$version" ] || die "usage: scripts/release.sh <version> [--notes FILE] [--publish | --dry-run]"
[ "$publish" = 1 ] && [ "$dry_run" = 1 ] && die "--publish and --dry-run cannot be combined"
TAG="v$version"
DMG_NAME="Cupid-$version.dmg"
DMG="$BUILD/$DMG_NAME"
SHA="$DMG.sha256"

# 1. pre-flight
step "Pre-flight"
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ "$version" =~ $semver ]] || die "'$version' is not a semver version (e.g. 1.2.3 or 1.2.3-beta.1); no leading v"
cd "$REPO"
branch="$(git branch --show-current)"
[ "$branch" = main ] || die "on branch '${branch:-detached HEAD}', not main. Run: git switch main"
dirty="$(git status --porcelain --untracked-files=normal | grep -v '^ M VERSION$' || true)"
[ -z "$dirty" ] || die "the working tree has changes other than VERSION; commit or stash them first:
$dirty"
gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally. Pick a new version, or delete it: git tag -d $TAG"
remote_tags="$(git ls-remote --tags origin "refs/tags/$TAG")" || die "could not reach origin to check tags (git ls-remote failed); check the network and credentials"
[ -z "$remote_tags" ] || die "tag $TAG already exists on origin. Pick a new version."
[ -f Resources/runtime/runtime.tar.gz ] || die "Resources/runtime/runtime.tar.gz is missing. Build it with scripts/runtime and copy it there."
[ -f Resources/runtime/runtime-archive.json ] || die "Resources/runtime/runtime-archive.json is missing. Copy it from the scripts/runtime build output."
RUNTIME_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' Resources/runtime/runtime-archive.json)" \
    || die "Resources/runtime/runtime-archive.json has no readable \"version\""
if [ -n "$notes" ]; then
    [ -f "$notes" ] || die "notes file '$notes' does not exist"
    notes="$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")"
fi
echo "  Cupid $version, tag $TAG, runtime $RUNTIME_VERSION$([ "$dry_run" = 1 ] && echo ', DRY RUN')"

# VERSION: written now; restored on failure (or always, on a dry run) unless committed.
old_version_file="$(git show HEAD:VERSION 2>/dev/null || true)"
committed=0
restore_version() {
    if [ "$committed" = 0 ] && ! git diff --quiet -- VERSION 2>/dev/null; then
        git checkout -q -- VERSION && echo "  (VERSION restored to ${old_version_file:-its committed value})"
    fi
}
trap 'status=$?; [ $status -ne 0 ] && echo "Release stopped; nothing was committed, tagged or pushed unless reported above." >&2; restore_version; exit $status' EXIT
printf '%s\n' "$version" > VERSION

# 2. build, test, bundle
step "swift build"
swift build || die "swift build failed; fix the build and rerun"
step "swift test"
swift test || die "swift test failed; fix the failing tests and rerun"
step "scripts/build-app.sh --dmg"
"$REPO/scripts/build-app.sh" --dmg || die "build-app.sh failed (see its output above)"
[ -f "$DMG" ] || die "build-app.sh did not produce $DMG"
step "hdiutil verify"
hdiutil verify -quiet "$DMG" || die "hdiutil verify failed for $DMG; rerun the script to rebuild it"
step "sha256"
(cd "$BUILD" && shasum -a 256 "$DMG_NAME") > "$SHA"
DMG_SHA="$(cut -d' ' -f1 "$SHA")"
echo "  $(cat "$SHA")"

if [ -z "$notes" ]; then
    notes="$BUILD/notes-$version.md"
    cat > "$notes" <<NOTES
# Cupid $version

Download \`$DMG_NAME\` below, open it, and drag **Cupid** into **Applications**. The first time
you open Cupid, macOS will not open it: close the message, go to **System Settings > Privacy &
Security**, and click **Open Anyway** next to Cupid.

Requires a Mac with Apple silicon running macOS 26 or later.

- Runtime: \`$RUNTIME_VERSION\`
- SHA-256 of \`$DMG_NAME\`: \`$DMG_SHA\`
NOTES
    step "Notes: $notes"
else
    step "Notes: $notes (given)"
fi

# 3. commit and tag (tag last, so a failure never leaves a tag behind)
if [ "$dry_run" = 1 ]; then
    step "Dry run: skipping commit and tag"
else
    if git diff --quiet -- VERSION; then
        step "VERSION already says $version at HEAD; no release commit needed"
    else
        step "Commit: Release $version"
        git commit -q -m "Release $version" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" -- VERSION \
            || die "git commit failed; VERSION will be restored, fix the problem and rerun"
    fi
    committed=1
    step "Tag: $TAG"
    git tag -a "$TAG" -m "Cupid $version" || die "git tag failed; the release commit exists, so rerun the script (it will tag HEAD)"
fi

# 4. publish
rel_notes="${notes#"$REPO"/}"
push_cmd=(git push origin main "$TAG")
release_cmd=(gh release create "$TAG" "build/$DMG_NAME" "build/$DMG_NAME.sha256" --title "Cupid $version" --notes-file "$rel_notes")
echo
echo "DMG:   $DMG ($(du -h "$DMG" | cut -f1))"
echo "SHA:   $SHA"
echo "Notes: $notes"
if [ "$publish" = 1 ]; then
    step "Publishing"
    "${push_cmd[@]}" || die "git push failed; the commit and tag are local. Fix the problem, then run: ${push_cmd[*]}"
    "${release_cmd[@]}" || die "gh release create failed after the push; fix it, then run: ${release_cmd[*]}"
    echo "Published $TAG."
else
    echo
    if [ "$dry_run" = 1 ]; then
        echo "Dry run complete. A real run would commit and tag, then print:"
    else
        echo "Nothing pushed. To publish, run:"
    fi
    echo "  git push origin main $TAG"
    echo "  gh release create $TAG build/$DMG_NAME build/$DMG_NAME.sha256 --title \"Cupid $version\" --notes-file $(printf '%q' "$rel_notes")"
fi
