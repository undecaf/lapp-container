#!/bin/bash

set -e

# Set environment variables for the current job
source .travis/setenv.inc
export ENGINE=${ENGINE:-docker}


echo $'\n*************** '"Building README snapshot"

# Build a self-contained HTML snapshot of the current README.md
# TODO: Move this to buildfiles/usr/local/bin/build as soon as pandoc is in Alpine/main
STYLE_URLS=$(curl --silent https://github.com/$TRAVIS_REPO_SLUG/ \
  | grep -E '<link [^>]*rel="stylesheet"[^>]*>' \
  | grep -o -E 'http[^"]+')

STYLES=$(mktemp -q)
echo '<style>' >$STYLES
curl --silent $STYLE_URLS >>$STYLES
echo '</style>' >>$STYLES

BEFORE_BODY=$(mktemp -q)
echo '<div class="Box-body p-4"><article class="markdown-body entry-content container-lg" itemprop="text">' >$BEFORE_BODY

AFTER_BODY=$(mktemp -q)
echo '</article></div>' >$AFTER_BODY

README=./runtime-files/var/www/readme.html
mkdir -p $(dirname $README)

pandoc \
  --self-contained \
  --metadata pagetitle='LAPP container' \
  --include-in-header $STYLES \
  --include-before-body $BEFORE_BODY \
  --include-after-body $AFTER_BODY \
  --from markdown \
  --to html5 \
  --output $README \
  ./README.md

trap "rm -f $README" EXIT


echo $'\n*************** '"Building image for tags: $DEPLOY_TAGS"

set -x

$ENGINE build \
  --build-arg MAJOR_VERSION=$MAJOR_VERSION \
  --build-arg BUILD_DATE=$(date --utc +'%Y-%m-%dT%H:%M:%SZ') \
  --build-arg COMMIT=$TRAVIS_COMMIT \
  --build-arg PRIMARY_TAG=$PRIMARY_TAG \
  --build-arg DEPLOY_TAGS="$DEPLOY_TAGS" \
  --tag $PRIMARY_IMG \
  "$@" \
  .
