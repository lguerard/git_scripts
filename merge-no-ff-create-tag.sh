#!/usr/bin/env bash
set -euo pipefail

exit_usage() {
    cat <<EOF
Usage: $0 [--dry-run|-n] [--yes|-y]

Options:
  --dry-run, -n   Print actions without executing them
  --yes, -y       Answer yes to prompts (non-interactive)
  -h, --help      Show this help
EOF
    exit 1
}

# Defaults
DRY_RUN=0
AUTO_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=1
            shift
            ;;
        --yes|-y)
            AUTO_YES=1
            shift
            ;;
        -h|--help)
            exit_usage
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit_usage
            ;;
    esac
done

# Helper to run or print commands when dry-run is enabled
run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY RUN: $*"
        return 0
    else
        "$@"
    fi
}

# Current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ -z "$CURRENT_BRANCH" ]; then
    echo "Failed to determine current branch." >&2
    exit 1
fi
# Try to determine the default branch on the remote in a robust way.
# Fetch to ensure remote refs are up to date (quietly).
run_cmd git fetch --quiet origin || true

# First try: resolve origin/HEAD (may return 'origin/main').
DEFAULT_BRANCH=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || true)
if [ -n "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=${DEFAULT_BRANCH#origin/}
fi

# If rev-parse yields 'HEAD' (literal) treat it as unknown.
if [ "$DEFAULT_BRANCH" = "HEAD" ] || [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=""
fi

# Try resolving remote HEAD using ls-remote --symref (works even when origin/HEAD
# is a symref on the server side).
if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=$(git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's@^ref: refs/heads/\([^ ]*\) HEAD@\1@p' || true)
fi

# Second try: parse `git remote show origin` output.
if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)
fi

# Fallbacks: prefer local "main" then "master", otherwise check remote heads.
if [ -z "$DEFAULT_BRANCH" ]; then
    if git show-ref --verify --quiet refs/heads/main; then
        DEFAULT_BRANCH=main
    elif git show-ref --verify --quiet refs/heads/master; then
        DEFAULT_BRANCH=master
    else
        if git ls-remote --heads origin main | grep -q main 2>/dev/null; then
            DEFAULT_BRANCH=main
        elif git ls-remote --heads origin master | grep -q master 2>/dev/null; then
            DEFAULT_BRANCH=master
        fi
    fi
fi

echo "Current branch: $CURRENT_BRANCH"
echo "Detected default branch: $DEFAULT_BRANCH"

# Prefer to merge into 'main' if it exists on remote or locally, otherwise use DEFAULT_BRANCH
TARGET_BRANCH=""
if git show-ref --verify --quiet refs/heads/main || git ls-remote --heads origin main | grep -q main 2>/dev/null; then
    TARGET_BRANCH=main
else
    TARGET_BRANCH=$DEFAULT_BRANCH
fi

if [ -z "$TARGET_BRANCH" ]; then
    echo "Error: unable to determine target branch to merge into." >&2
    exit 1
fi

echo "Target branch: $TARGET_BRANCH"

# Checkout and update the target branch to match origin
run_cmd git fetch --quiet origin || true
if git show-ref --verify --quiet refs/heads/"$TARGET_BRANCH"; then
    run_cmd git checkout "$TARGET_BRANCH" || { echo "Failed to checkout $TARGET_BRANCH" >&2; exit 1; }
    run_cmd git pull --ff-only origin "$TARGET_BRANCH" 2>/dev/null || true
else
    run_cmd git checkout -b "$TARGET_BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null || { echo "Failed to create local $TARGET_BRANCH from origin/$TARGET_BRANCH" >&2; exit 1; }
fi

if [ "$CURRENT_BRANCH" = "$TARGET_BRANCH" ]; then
    echo "Current branch is the same as target branch ($TARGET_BRANCH). Aborting." >&2
    exit 1
fi

# Repo name from top-level git dir (safer than PWD)
REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$REPO_TOP" ]; then
    REPO_NAME=$(basename "$REPO_TOP")
else
    REPO_NAME=$(basename "$PWD")
fi

# Compute next patch version from tags named <repo>-X.Y.Z
LATEST_TAG=$(git tag --list "$REPO_NAME-*" --sort=-v:refname | head -n1 || true)
if [ -z "$LATEST_TAG" ]; then
    NEXT_VERSION="1.0.0"
else
    VERSION_PART=${LATEST_TAG#"$REPO_NAME-"}
    if [[ "$VERSION_PART" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        MAJOR=${BASH_REMATCH[1]}
        MINOR=${BASH_REMATCH[2]}
        PATCH=${BASH_REMATCH[3]}
        PATCH=$((PATCH+1))
        NEXT_VERSION="$MAJOR.$MINOR.$PATCH"
    else
        NEXT_VERSION="1.0.0"
    fi
fi

printf 'Version? [%s]: ' "$NEXT_VERSION"
read -r VERSION
test "$VERSION" || VERSION=$NEXT_VERSION
CURRENT_TAG="$REPO_NAME-$VERSION"

echo "Tag to create: $CURRENT_TAG"

# Perform the merge into the target branch
if ! run_cmd git merge --no-ff --no-edit "$CURRENT_BRANCH"; then
    echo "Error: merge failed." >&2
    exit 1
fi

# Tag the merge commit (HEAD)
TARGET_COMMIT=$(git rev-parse --verify HEAD)

# Check existing tag
TAG_EXISTS=0
if git show-ref --tags --quiet --verify "refs/tags/$CURRENT_TAG"; then
    TAG_EXISTS=1
elif git ls-remote --tags origin | grep -q "refs/tags/$CURRENT_TAG"; then
    TAG_EXISTS=1
fi

if [ $TAG_EXISTS -eq 1 ]; then
    echo "Tag '$CURRENT_TAG' already exists."
    if [ "$AUTO_YES" -eq 1 ]; then
        OVERWRITE_TAG="y"
    else
        printf 'Overwrite tag and move it to the merge commit %s? [y/N]: ' "$TARGET_COMMIT"
        read -r OVERWRITE_TAG
    fi
    if [ "${OVERWRITE_TAG,,}" = "y" ] || [ "${OVERWRITE_TAG,,}" = "yes" ]; then
        run_cmd git tag -f -a "$CURRENT_TAG" -m "" "$TARGET_COMMIT"
        run_cmd git push origin --force "refs/tags/$CURRENT_TAG"
    else
        echo "Skipping tag update. Existing tag left in place." >&2
    fi
else
    run_cmd git tag -a "$CURRENT_TAG" -m "" "$TARGET_COMMIT"
    run_cmd git push origin "$CURRENT_TAG"
fi

# Push the target branch to origin
run_cmd git push origin "$TARGET_BRANCH"

# Done
echo "Done."
