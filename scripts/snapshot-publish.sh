#!/usr/bin/env bash
#
# Snapshot-based publishing: create a snapshot commit on public/latest whose tree matches
# origin/main@HEAD, keeping public history clean while retaining full private history.
#
# This script is designed to be run from a private repo, and will create a snapshot commit
# on the public remote that matches the private HEAD. It will then push the commit to the
# public branch, and update the rolling sync tag on the private remote.
#
# It will also create a per-release annotated tag on the private remote that contains the
# public commit hash, the private HEAD hash, and the range of commits that were included.

set -euo pipefail

# ===== Config (override via env) =====
PRIV_REMOTE="${PRIV_REMOTE:-origin}"      # private remote
PRIV_BRANCH="${PRIV_BRANCH:-main}"        # private branch to snapshot
PUB_REMOTE="${PUB_REMOTE:-public}"        # public remote
PUB_BRANCH="${PUB_BRANCH:-latest}"        # public branch to update
SYNC_TAG="${SYNC_TAG:-public-sync}"       # rolling marker on private
ALLOW_REWRITE="${ALLOW_REWRITE:-1}"       # 1=allow force-with-lease on public branch
SNAPSHOT_DATE="${SNAPSHOT_DATE:-}"        # e.g. "2024-12-15 14:30:00 -0800" (optional backdate)

# ===== Helpers =====
die() { echo "Error: $*" >&2; exit 1; }
ed() { "${GIT_EDITOR:-$(git var GIT_EDITOR 2>/dev/null || command -v vi || command -v nano)}" "$@"; }

require_clean_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Working tree or index not clean. Commit/stash before running, or use a dedicated worktree."
  fi
}

# ===== Pre-flight =====
git rev-parse --git-dir >/dev/null 2>&1 || die "Run inside a git repo."
require_clean_tree

git fetch --all --prune

PUB_REF="refs/remotes/${PUB_REMOTE}/${PUB_BRANCH}"
PRIV_REF="refs/remotes/${PRIV_REMOTE}/${PRIV_BRANCH}"

git show-ref --verify "${PRIV_REF}" >/dev/null || die "Missing ${PRIV_REF} (fetch failed?)."

HAS_PUB=0
if git show-ref --verify "${PUB_REF}" >/dev/null 2>&1; then
  HAS_PUB=1
fi

# Resolve heads and trees from remote-tracking refs
PRIV_HEAD_SHA="$(git rev-parse "${PRIV_REF}")"
TREE_SHA="$(git rev-parse "${PRIV_REF}^{tree}")"

PARENT_SHA=""
PARENT_TREE=""
if [ "${HAS_PUB}" -eq 1 ]; then
  PARENT_SHA="$(git rev-parse "${PUB_REF}")"
  PARENT_TREE="$(git rev-parse "${PUB_REF}^{tree}")"
fi

# ===== No-op guards: skip if nothing changed =====
if [ "${HAS_PUB}" -eq 1 ]; then
  if git diff --quiet "${PUB_REF}" "${PRIV_REF}"; then
    echo "No content differences between ${PUB_REF} and ${PRIV_REF}; skipping snapshot."
    exit 0
  fi
  if [ -n "${PARENT_TREE}" ] && [ "${TREE_SHA}" = "${PARENT_TREE}" ]; then
    echo "Private tree matches current public tip; skipping snapshot."
    exit 0
  fi
fi

# ===== Build range summary for the editor (private only; commented) =====
LAST_RANGE_BASE=""
if git show-ref --verify "refs/tags/${SYNC_TAG}" >/dev/null 2>&1; then
  LAST_RANGE_BASE="$(git rev-parse "${SYNC_TAG}")"
fi

if [ -n "${LAST_RANGE_BASE}" ]; then
  SUMMARY="$(git log --no-merges --pretty='- %h %s (%an)' "${LAST_RANGE_BASE}..${PRIV_REF}" || true)"
else
  SUMMARY="$(git log --no-merges --pretty='- %h %s (%an)' --max-count=50 "${PRIV_REF}" || true)"
fi

T="$(mktemp -t pubmsg.XXXXXX)"
{
  echo "sync: snapshot ${PRIV_REMOTE}/${PRIV_BRANCH} -> ${PUB_REMOTE}/${PUB_BRANCH}"
  echo
  echo "# Range: ${LAST_RANGE_BASE:+${LAST_RANGE_BASE}..}${PRIV_REMOTE}/${PRIV_BRANCH}"
  echo "# Notable changes:"
  [ -n "${SUMMARY}" ] && echo "${SUMMARY}" | sed 's/^/# /'
  echo "# Lines starting with '#' are ignored."
} > "${T}"

vim "${T}"
MSG="$(git stripspace --strip-comments < "${T}")"
rm -f "${T}"
[ -n "${MSG}" ] || die "Aborted: empty commit message."

# Optional backdate for the public commit
if [ -n "${SNAPSHOT_DATE}" ]; then
  export GIT_AUTHOR_DATE="${SNAPSHOT_DATE}"
  export GIT_COMMITTER_DATE="${SNAPSHOT_DATE}"
fi

# ===== Create the snapshot commit =====
if [ -n "${PARENT_SHA}" ]; then
  NEW_SHA="$(git commit-tree "${TREE_SHA}" -p "${PARENT_SHA}" <<<"${MSG}")"
else
  NEW_SHA="$(git commit-tree "${TREE_SHA}" <<<"${MSG}")"
fi
[ -n "${NEW_SHA}" ] || die "Failed to create snapshot commit."

# ===== Push to public (FF when possible; otherwise guarded rewrite) =====
if [ "${HAS_PUB}" -eq 1 ]; then
  CUR_REMOTE_TIP="$(git rev-parse "${PUB_REF}")"
  if [ -n "${PARENT_SHA}" ] && [ "${PARENT_SHA}" = "${CUR_REMOTE_TIP}" ]; then
    git push "${PUB_REMOTE}" "${NEW_SHA}:refs/heads/${PUB_BRANCH}"
  else
    if [ "${ALLOW_REWRITE}" = "1" ]; then
      git push --force-with-lease="refs/heads/${PUB_BRANCH}:${CUR_REMOTE_TIP}" \
        "${PUB_REMOTE}" "${NEW_SHA}:refs/heads/${PUB_BRANCH}"
    else
      die "Remote ${PUB_REMOTE}/${PUB_BRANCH} moved; set ALLOW_REWRITE=1 to overwrite."
    fi
  fi
else
  git push "${PUB_REMOTE}" "${NEW_SHA}:refs/heads/${PUB_BRANCH}"
fi

# ===== After successful push: update private tags =====
# Advance rolling sync tag to the private head we just exported
git tag -f "${SYNC_TAG}" "${PRIV_HEAD_SHA}"
git push -f "${PRIV_REMOTE}" "refs/tags/${SYNC_TAG}"

# Create per-release annotated tag on the private head (name uses PUBLIC commit's date)
TAG_TS="$(git show -s --format=%cd --date=format:%Y%m%d-%H%M%S "${NEW_SHA}")"
PRIV_TAG="public-snap-${TAG_TS}"
TAG_MSG=$(
  cat <<EOF
Public snapshot to ${PUB_REMOTE}/${PUB_BRANCH}
Public commit:  ${NEW_SHA}
Private head:   ${PRIV_HEAD_SHA}
Range:          ${LAST_RANGE_BASE:+${LAST_RANGE_BASE}..}${PRIV_HEAD_SHA}
EOF
)
git tag -a "${PRIV_TAG}" -m "${TAG_MSG}" "${PRIV_HEAD_SHA}"
git push "${PRIV_REMOTE}" "refs/tags/${PRIV_TAG}"

echo "Done. Updated ${PUB_REMOTE}/${PUB_BRANCH} -> ${NEW_SHA}"
echo "Tags: moved ${SYNC_TAG}, created ${PRIV_TAG}"
