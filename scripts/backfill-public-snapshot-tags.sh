#!/usr/bin/env bash
#
# Backfills private release tags for snapshot-based publishing.
#
# Given an *earliest public snapshot* commit SHA on public/latest, this script walks
# that commit and all descendants on the public branch (oldest → newest), and for
# each commit:
#
#   1) Finds the matching private commit on origin/main by comparing tree hashes.
#   2) Creates an annotated private tag named public-snap-YYYYmmdd-HHMMSS
#      (timestamp taken from the public commit’s committer date) pointing to the
#      matching private commit.
#   3) Pushes the tag(s) to the private remote.
#
# After processing, it advances the rolling public-sync tag on the private remote
# to the newest matched private commit. This mirrors the tagging behavior of
# snapshot-publish.sh for historical snapshot commits that were created earlier.
#
# Notes:
# - Idempotent: existing public-snap-* tags are left in place and skipped.
# - Read-only for the public repo: no changes are pushed to the public remote.
# - Requires both remotes fetched (origin/main and public/latest present as
#   remote-tracking refs) and the start SHA to be an ancestor of public/latest.
# - Only tags commits where the private tree exactly matches the public snapshot.

set -euo pipefail

PRIV_REMOTE="${PRIV_REMOTE:-origin}"     # private remote
PRIV_BRANCH="${PRIV_BRANCH:-main}"       # private branch
PUB_REMOTE="${PUB_REMOTE:-public}"       # public remote
PUB_BRANCH="${PUB_BRANCH:-latest}"       # public branch
SYNC_TAG="${SYNC_TAG:-public-sync}"      # rolling tag on private

die() { echo "Error: $*" >&2; exit 1; }

START_PUB_COMMIT="${1:-}"
[ -n "${START_PUB_COMMIT}" ] || die "Usage: $0 <earliest-public-snapshot-SHA>"

command -v git >/dev/null || die "git not found"
git rev-parse --git-dir >/dev/null 2>&1 || die "Run inside a git repo."

echo "Fetching..."
git fetch --all --prune

PUB_REF="refs/remotes/${PUB_REMOTE}/${PUB_BRANCH}"
PRIV_REF="refs/remotes/${PRIV_REMOTE}/${PRIV_BRANCH}"

git show-ref --verify "${PUB_REF}"  >/dev/null || die "Missing ${PUB_REF}"
git show-ref --verify "${PRIV_REF}" >/dev/null || die "Missing ${PRIV_REF}"

git cat-file -t "${START_PUB_COMMIT}" >/dev/null 2>&1 || die "Unknown object ${START_PUB_COMMIT}"
[ "$(git cat-file -t "${START_PUB_COMMIT}")" = "commit" ] || die "${START_PUB_COMMIT} is not a commit"

git merge-base --is-ancestor "${START_PUB_COMMIT}" "${PUB_REF}" \
  || die "Provided SHA is not an ancestor of ${PUB_REF}"

# Build list of public commits to process (oldest -> newest), including START
PUB_LIST="$(printf '%s\n' "${START_PUB_COMMIT}"; git rev-list --reverse "${START_PUB_COMMIT}..${PUB_REF}")"

latest_priv_commit=""

echo "Backfilling from ${START_PUB_COMMIT} on ${PUB_REF}..."
# Iterate each public commit in the list
while IFS= read -r PUB_COMMIT; do
  [ -n "${PUB_COMMIT}" ] || continue

  # Tag name based on the public commit's committer date
  TS="$(git show -s --format=%cd --date=format:%Y%m%d-%H%M%S "${PUB_COMMIT}")"
  TAG="public-snap-${TS}"

  PUB_TREE="$(git rev-parse "${PUB_COMMIT}^{tree}")"
  echo "• Match public ${PUB_COMMIT:0:7} (tree ${PUB_TREE:0:7}) -> private..."

  # Find the private commit whose tree equals this public tree (scan newest->oldest)
  PRIV_COMMIT=""
  while IFS= read -r C; do
    [ -n "${C}" ] || continue
    T="$(git rev-parse "${C}^{tree}")"
    if [ "${T}" = "${PUB_TREE}" ]; then
      PRIV_COMMIT="${C}"
      break
    fi
  done <<EOF2
$(git rev-list "${PRIV_REF}")
EOF2

  if [ -z "${PRIV_COMMIT}" ]; then
    echo "  ! No matching private commit found. Skipping."
    continue
  fi

  if git show-ref --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "  • Tag ${TAG} already exists."
  else
    TAG_MSG=$(
      cat <<EOF3
Public snapshot to ${PUB_REMOTE}/${PUB_BRANCH}
Public commit:  ${PUB_COMMIT}
Private commit: ${PRIV_COMMIT}
EOF3
    )
    git tag -a "${TAG}" -m "${TAG_MSG}" "${PRIV_COMMIT}"
    git push "${PRIV_REMOTE}" "refs/tags/${TAG}"
    echo "  ✓ Created ${TAG} on private ${PRIV_COMMIT:0:7}"
  fi

  latest_priv_commit="${PRIV_COMMIT}"
done <<EOF4
${PUB_LIST}
EOF4

# Update rolling public-sync to the newest matched private commit
if [ -n "${latest_priv_commit}" ]; then
  git tag -f "${SYNC_TAG}" "${latest_priv_commit}"
  git push -f "${PRIV_REMOTE}" "refs/tags/${SYNC_TAG}"
  echo "Moved ${SYNC_TAG} -> ${latest_priv_commit:0:7}"
else
  echo "No matches found; ${SYNC_TAG} unchanged."
fi

echo "Done."
