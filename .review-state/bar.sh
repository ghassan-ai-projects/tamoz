#!/bin/bash
# Progress bar for the clean-code review loop, rendered from .review-state/state.tsv
cd "$(dirname "$0")/.." || exit 1
f=.review-state/state.tsv
total=$(wc -l < "$f" | tr -d ' ')
count() { awk -F'\t' -v s="$1" '$3==s' "$f" | wc -l | tr -d ' '; }
committed=$(count committed); clean=$(count clean); exempt=$(count exempt)
flagged=$(count flagged); skipped=$(count skipped)
analyzing=$(count analyzing); fixing=$(count fixing); pending=$(count pending)
done_n=$((committed + clean + exempt + skipped))
width=30
filled=$(( done_n * width / total ))
[ "$filled" -gt "$width" ] && filled=$width
bar=""
for ((i=0; i<width; i++)); do if (( i < filled )); then bar+="█"; else bar+="░"; fi; done
echo "[${bar}] ${done_n}/${total} (${skipped} queued-out)"
echo "  committed:${committed}  clean:${clean}  exempt:${exempt}  flagged:${flagged}  |  in-flight: analyzing:${analyzing} fixing:${fixing}  |  pending:${pending}"
