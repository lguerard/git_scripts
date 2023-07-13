exit_usage() {
    echo "Usage:"
    echo
    echo "$0"
    echo
    exit 1
}

if [ $# -ne 0 ]; then
    exit_usage
fi

DEFAULT_BRANCH=$(basename $(git symbolic-ref --short refs/remotes/origin/HEAD))

git checkout "$DEFAULT_BRANCH"
CURRENT_TAG=$(git describe --abbrev=0 --tags)

if [ -z "$CURRENT_TAG" ]
then
    CURRENT_TAG_NUMBER="1.0.0"
else
    CURRENT_TAG_NUMBER=$(echo "$CURRENT_TAG" | cut -d "-" -f3)
fi

printf 'Version? [%s]: ' "$CURRENT_TAG_NUMBER"
read VERSION
test "$VERSION" || VERSION=$CURRENT_TAG_NUMBER
echo "$VERSION"

REPO_NAME=$(basename "$PWD")
CURRENT_TAG="$REPO_NAME-$VERSION"
echo $CURRENT_TAG

git merge --no-ff dev --no-edit
git tag -a $CURRENT_TAG -m ""
git push origin $CURRENT_TAG
git push origin
