#!/bin/bash

# Set environment variables for the current job
source .travis/setenv.inc

echo $'\n*************** '"Deploying $PRIMARY_IMG to $DEPLOY_TAGS"

set -x

# Tag primary image with all applicable tags and push them simultaneously
for T in $DEPLOY_TAGS; do 
    docker tag $PRIMARY_IMG $TRAVIS_REPO_SLUG:$T
done

# Push all local tags
docker push $TRAVIS_REPO_SLUG

# Update bages at MicroBadger only for the most recent build version
#test -n "$MOST_RECENT" && \
#    curl -X POST https://hooks.microbadger.com/images/undecaf/lapp-container/$MICROBADGER_WEBHOOK

# If we have arrived here then exit successfully
exit 0
