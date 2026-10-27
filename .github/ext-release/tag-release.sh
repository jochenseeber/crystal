#!/bin/sh
# Creates the release commit for <version> on top of HEAD and tags it.
#
# The commit sets the version in `src/VERSION` and `shard.yml` and records the
# build date in `src/SOURCE_DATE_EPOCH`, as upstream releases do. It is only
# reachable from the tag, so the branch itself never changes. Nothing is
# pushed.
#
# Usage: tag-release.sh <version>
set -eu

version=$1

# Commit on a detached HEAD, so no branch moves.
git checkout --quiet --detach

echo "$version" >src/VERSION
sed "s/^version: .*/version: $version/" shard.yml >shard.yml.new
mv shard.yml.new shard.yml
git log -1 --format=%ct >src/SOURCE_DATE_EPOCH

git commit --quiet --message "Release $version" -- src/VERSION shard.yml src/SOURCE_DATE_EPOCH
git tag --annotate "$version" --message "Crystal $version"
