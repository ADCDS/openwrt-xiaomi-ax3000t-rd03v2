#!/bin/bash
# freeze-feeds.sh <feeds.conf> <timestamp>: print "<name> <commit>" for every src-git feed,
# the last commit on the feed's branch before <timestamp> (ISO 8601). kuncy7's CI updates his
# unpinned feeds right after a release commit, so his release time is the closest guess for
# what his build compiled. Feed repos are cached bare (blob-less) in $FEED_CACHE.
set -euo pipefail
CONF=${1:?feeds.conf}; TS=${2:?timestamp}
FEED_CACHE=${FEED_CACHE:-${RD03V2_WS:-$(cd "$(dirname "$0")/../../.." && pwd)}/mirrors/feeds}
mkdir -p "$FEED_CACHE"
grep -E '^src-git(-full)? ' "$CONF" | while read -r _ name spec; do
	url=${spec%%;*}; branch=; [ "$spec" != "$url" ] && branch=${spec#*;}
	dir=$FEED_CACHE/$name.git
	if [ -d "$dir" ]; then git -C "$dir" fetch -q --prune origin '+refs/heads/*:refs/heads/*'
	else git clone -q --bare --filter=blob:none "$url" "$dir"; fi
	ref=${branch:-$(git -C "$dir" symbolic-ref --short HEAD)}
	c=$(git -C "$dir" rev-list -1 --before="$TS" "$ref")
	[ -n "$c" ] || { echo "no commit on $name $ref before $TS" >&2; exit 1; }
	echo "$name $c"
done
