#!/bin/sh
# The checkout kept on ci-1 (each runner's _work, kept between jobs) made whole again where an earlier job left it a
# partial clone (a checkout with `filter: blob:none` sets remote.origin.promisor and partialclonefilter, and they stay):
# a later job's checkout with no filter then fetched each missing blob as git came to it, one HTTPS request at a time and
# never tried again, and failed on one broken handshake (`gnutls_handshake() failed`, 2026-11-16). Run in the job's own
# checkout (setup-linux, after it), where no other job writes: from outside, a runner's next checkout races it.
#   - no promisor pack left (its objects all here): the settings alone taken out, at once;
#   - promisor packs: the history borrowed from ci-1's whole clone (~/stillfail-ci/monoid-full.git, kept apart from any
#     runner's _work), what it lacks of this one's fetched, all of it packed here, then the settings and the promisor
#     marks taken out once nothing is missing. Once; a checkout already whole costs a `git config` read.
set -u
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 0
[ "$(git config --local --get remote.origin.promisor 2>/dev/null)" = true ] || exit 0
G=$(git rev-parse --absolute-git-dir)
whole() {
  git config --local --unset-all remote.origin.promisor 2>/dev/null || true
  git config --local --unset-all remote.origin.partialclonefilter 2>/dev/null || true
  git config --local --unset-all extensions.partialclone 2>/dev/null || true
}
if [ -z "$(find "$G/objects/pack" -maxdepth 1 -name '*.promisor' 2>/dev/null | head -1)" ]; then
  whole
  echo "whole-clone: no promisor pack; the partial clone's settings taken out"
  exit 0
fi
full=$HOME/stillfail-ci/monoid-full.git
[ -d "$full/objects" ] || { echo "whole-clone: a partial clone, and no $full to make it whole from"; exit 0; }
t0=$(date +%s)
# (the refs the jobs use alone: other branches' history is what was never fetched whole)
head=$(git symbolic-ref -q HEAD || true)
git for-each-ref --format='%(refname)' refs/remotes refs/heads refs/tags | while read -r r; do
  [ "$r" = refs/remotes/origin/main ] || [ "$r" = "$head" ] || git update-ref -d "$r"
done
alt="$G/objects/info/alternates"
mkdir -p "$G/objects/info"
[ ! -f "$alt" ] || cp "$alt" "$alt.before"
echo "$full/objects" >> "$alt"
back() { if [ -f "$alt.before" ]; then mv "$alt.before" "$alt"; else rm -f "$alt"; fi; }
missing() { git rev-list --objects --missing=print --all 2>/dev/null | sed -n 's/^?//p'; }
m=$(missing)
[ -z "$m" ] || printf '%s\n' "$m" | git -c fetch.negotiationAlgorithm=noop fetch -q --no-tags --no-write-fetch-head --stdin origin || { back; exit 1; }
# (reflogs name what the refs taken out had; their history is as partial)
git reflog expire --expire=now --all
timeout 150 git repack -a -d -q || { back; exit 1; }
back
n=$(missing | wc -l | tr -d ' ')
[ "$n" = 0 ] || { echo "whole-clone: $n objects still missing; left a partial clone"; exit 1; }
rm -f "$G"/objects/pack/*.promisor
whole
echo "whole-clone: made whole in $(( $(date +%s) - t0 )) s ($(echo "$m" | grep -c . || true) fetched)"
