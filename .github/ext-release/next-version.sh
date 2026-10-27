#!/bin/sh
# Prints the next release of an `<base>+ext.x` branch as GitHub Actions
# outputs:
#
#   base=1.22.1               upstream release the branch builds on
#   version=1.22.1+ext.3      next free `<base>+ext.<n>` tag
#   released=1.22.1+ext.2     tag that already releases HEAD, if any
#
# A release tag points at a release commit whose parent is the branch commit
# it releases, so HEAD is released when some tag's parent is HEAD.
#
# Usage: next-version.sh <branch>
set -eu

branch=$1

case "$branch" in
*+ext.x) ;;
*)
  echo "Not an +ext.x branch: $branch" >&2
  exit 1
  ;;
esac

prefix=${branch%x}
base=${branch%%+*}
head=$(git rev-parse HEAD)
last=-1
released=

for tag in $(git tag --list "${prefix}*"); do
  n=${tag#"$prefix"}
  case "$n" in
  '' | *[!0-9]*) continue ;;
  esac

  if [ "$(git rev-parse "$tag^{commit}^")" = "$head" ]; then
    released=$tag
  fi

  if [ "$n" -gt "$last" ]; then
    last=$n
  fi
done

echo "base=$base"
echo "version=$prefix$((last + 1))"
echo "released=$released"
