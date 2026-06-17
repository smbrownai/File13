#!/usr/bin/env bash
# Sync File13's docs/ directory to smbrownai/next → file13/ and open a PR.
#
# Usage:
#   scripts/publish-docs.sh [--message "short description"]
#   scripts/publish-docs.sh --direct    # commit straight to main (no PR)
#
# Optional env:
#   NEXT_REPO_PATH   Local checkout of smbrownai/next. Defaults to ~/code/next.
#
# Requires: git, gh (GitHub CLI), rsync
set -euo pipefail

# ---- args ---------------------------------------------------------------------

COMMIT_MSG=""
DIRECT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)
      [[ $# -ge 2 ]] || { echo "error: --message needs an argument" >&2; exit 2; }
      COMMIT_MSG="$2"; shift 2 ;;
    --direct)
      DIRECT=1; shift ;;
    -h|--help)
      cat >&2 <<EOF
usage: $(basename "$0") [-m "message"] [--direct]

  -m, --message   short description for the commit / PR title
                  (default: "File13 docs update")
  --direct        commit straight to main without a PR
EOF
      exit 0 ;;
    *)
      echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

[[ -n "$COMMIT_MSG" ]] || COMMIT_MSG="File13 docs update"

: "${NEXT_REPO_PATH:=$HOME/code/next}"

# ---- paths -------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_SRC="$REPO_ROOT/docs/"
BRANCH="file13/docs-$(date +%Y%m%d-%H%M%S)"

# ---- helpers -----------------------------------------------------------------

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
info()  { printf "  \033[36m·\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*" >&2; }
die()   { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null || die "missing required command: $1"; }

# ---- preflight ---------------------------------------------------------------

require_cmd git
require_cmd rsync
(( DIRECT == 0 )) && require_cmd gh

[[ -d "$DOCS_SRC" ]] || die "docs source not found: $DOCS_SRC"

if [[ ! -d "$NEXT_REPO_PATH/.git" ]]; then
  warn "NEXT_REPO_PATH ($NEXT_REPO_PATH) is not a git repo"
  info "manual sync:"
  cat <<EOF
    mkdir -p $NEXT_REPO_PATH/file13
    rsync -a --delete --exclude='.DS_Store' $DOCS_SRC $NEXT_REPO_PATH/file13/
    cd $NEXT_REPO_PATH
    git add file13
    git commit -m "$COMMIT_MSG"
    git push
EOF
  exit 1
fi

# ---- sync --------------------------------------------------------------------

bold "==> Sync docs/ → next/file13/"

(
  cd "$NEXT_REPO_PATH"
  git fetch --quiet origin
  git checkout main 2>/dev/null || git checkout master
  git pull --ff-only
  ok "next repo on main, up to date"

  mkdir -p file13
  rsync -a --delete --exclude='.DS_Store' "$DOCS_SRC" file13/

  if [[ -z "$(git status --porcelain)" ]]; then
    ok "docs/ unchanged since last publish — nothing to do"
    exit 0
  fi

  info "changed files:"
  git status --short file13/

  if (( DIRECT == 1 )); then
    # ---- direct commit to main -----------------------------------------------
    git add file13
    git commit -m "$COMMIT_MSG"
    git push origin main
    ok "docs pushed to main: $NEXT_REPO_PATH/file13/"
  else
    # ---- branch + PR (auto-merged) -------------------------------------------
    git checkout -b "$BRANCH"
    git add file13
    git commit -m "$COMMIT_MSG"
    git push -u origin "$BRANCH"
    ok "branch pushed: $BRANCH"

    PR_URL=$(gh pr create \
      --base main \
      --head "$BRANCH" \
      --title "$COMMIT_MSG" \
      --body "Sync of \`docs/\` from smbrownai/File13. Source: https://github.com/smbrownai/File13/tree/main/docs")
    ok "PR opened: $PR_URL"

    if gh pr merge "$PR_URL" --squash --delete-branch; then
      ok "PR merged and branch deleted"
    else
      warn "auto-merge failed — merge manually: $PR_URL"
    fi
  fi
)
