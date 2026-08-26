#!/bin/bash
# Integrator gate for one rank: verify ONLY the owned file changed, run syntax +
# uncached rubocop, then commit it and update state.
# usage: verify_and_commit.sh <rank>
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"; eval "$(rbenv init -)" || true

rank="$1"
file=$(awk -F'\t' -v r="$rank" '$1==r{print $3}' .review-state/queue.tsv)
[ -n "$file" ] || { echo "ABORT: rank $rank not in queue"; exit 1; }
gem=$(echo "$file" | cut -d/ -f2)
base=$(basename "$file")

echo "== ownership check =="
dirty=$(git status --porcelain | grep -v '^??' || true)
if ! echo "$dirty" | grep -q "^ M $file\$"; then
  echo "NOTE: owned file not dirty for rank $rank (nothing to commit)"
else
  foreign=$(echo "$dirty" | sed 's/^...//' | while IFS= read -r p; do
    [ -z "$p" ] && continue
    awk -F'\t' -v p="$p" '$3==p{found=1} END{exit !found}' .review-state/queue.tsv || echo "$p"
  done)
  if [ -f .review-state/foreign_allow.txt ]; then
    foreign=$(echo "$foreign" | grep -vxF -f .review-state/foreign_allow.txt || true)
  fi
  if [ -n "$foreign" ]; then echo "ABORT: foreign dirty paths:"; echo "$foreign"; exit 1; fi
  echo "(other dirty paths belong to queued ranks; staging only: $file)"

echo "== syntax =="
ruby -c "$file"

echo "== rubocop (uncached) =="
rubocop --cache false --format simple "$file" | tail -2 || true

echo "== diff stat =="
git diff --stat "$file"

git add "$file"
git commit -q -m "refactor($gem): clean-code pass on $base" \
  -m "Rank $rank of the gems/ clean-code review loop (analyzer+fixer pipeline).
Reviewed candidates: .review-state/reports/$rank.md (working notes, not committed).
Principles applied: intent-revealing names, step-down methods, single level of
abstraction, dedup within file. Behavior-preserving; public surface unchanged."
echo "committed: $(git log -1 --format='%h %s')"
fi

awk -F'\t' -v r="$rank" 'BEGIN{OFS="\t"}$1==r{$3="committed"}1' .review-state/state.tsv > .review-state/s.tmp
mv .review-state/s.tmp .review-state/state.tsv
.review-state/bar.sh
