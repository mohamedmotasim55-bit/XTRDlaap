#!/usr/bin/env bash
# Run one backtest iteration end to end: lint, compile-check on CI, download the
# artifacts, analyse them and record the metrics in CHANGELOG.md.
#
# Usage: tools/run_iteration.sh <tag> [days] [model] [execution_mode]
#   e.g. tools/run_iteration.sh iter1 45 4 15
#
# Requires: git push access to the branch, `gh` authenticated, repository
# secrets MT5_LOGIN / MT5_PASSWORD / MT5_SERVER.
set -uo pipefail

REPO="${REPO:-mohamedmotasim55-bit/XTRDlaap}"
WORKFLOW="backtest.yml"
TAG="${1:?tag required (e.g. iter1)}"
DAYS="${2:-45}"
MODEL="${3:-4}"
EXEC="${4:-15}"
EA="XTRD_OMIGA_Enabled_GoldSymbol.mq5"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo "== 0. static checks =="
python3 tools/mql5_lint.py "$EA" || { echo "lint failed"; exit 1; }

echo "== 1. push =="
git add -A
git diff --cached --quiet || git commit -m "iter ${TAG}: parameter/geometry update"
git push origin "$BRANCH" || { echo "push failed"; exit 1; }

echo "== 2. dispatch =="
gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" \
  -f "tag=${TAG}" -f "days=${DAYS}" -f "model=${MODEL}" -f "execution_mode=${EXEC}"
sleep 8

RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" \
          --limit 1 --json databaseId --jq '.[0].databaseId')"
echo "run id: ${RUN_ID}"

echo "== 3. watch =="
gh run watch "$RUN_ID" --repo "$REPO" --exit-status --interval 20 || {
  echo "run failed; fetching logs"
  gh run view "$RUN_ID" --repo "$REPO" --log-failed | tail -80
  exit 1
}

echo "== 4. download =="
rm -rf artifacts && mkdir -p artifacts
gh run download "$RUN_ID" --repo "$REPO" -D artifacts

echo "== 5. analyse =="
BEST="$(ls -1 reports/score_*.txt 2>/dev/null | sed 's/.*score_//;s/\.txt//' | sort -g | tail -1)"
mkdir -p reports
python3 tools/analyze_backtest.py \
  --iteration "$TAG" \
  --out "reports/${TAG}.json" \
  --append-changelog CHANGELOG.md \
  ${BEST:+--best-score "$BEST"}

SCORE="$(python3 -c "import json;print(json.load(open('reports/${TAG}.json'))['score'])")"
echo "$SCORE" > "reports/score_${TAG}.txt"
echo "score=${SCORE}"
