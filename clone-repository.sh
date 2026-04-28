#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_OWNER="takanotaiga"
readonly REPOSITORIES=(
  "mlops-cloud"
  "mlops-cloud-ui"
  "mlops-cloud-backend"
  "mlops-cloud-updater"
)

base_dir="."
owner="$DEFAULT_OWNER"
branch=""

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [OPTIONS]

Clone required MLOps Cloud repositories.

Options:
  -d, --dir PATH       Destination directory (default: current directory)
  -o, --owner OWNER    GitHub owner/org name (default: $DEFAULT_OWNER)
  -b, --branch BRANCH  Clone a specific branch for all repositories
  -h, --help           Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; exit 2; }
      base_dir="$2"
      shift 2
      ;;
    -o|--owner)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; exit 2; }
      owner="$2"
      shift 2
      ;;
    -b|--branch)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; exit 2; }
      branch="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v git >/dev/null 2>&1 || {
  echo "Error: git command was not found" >&2
  exit 127
}

mkdir -p "$base_dir"
cd "$base_dir"

echo "Destination: $(pwd)"
echo "Owner: $owner"
[[ -n "$branch" ]] && echo "Branch: $branch"

cloned=0
skipped=0
failed=0

for repo in "${REPOSITORIES[@]}"; do
  url="https://github.com/${owner}/${repo}.git"

  if [[ -d "$repo/.git" ]]; then
    echo "[SKIP] $repo (already exists as git repository)"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -e "$repo" ]]; then
    echo "[SKIP] $repo (path exists and is not a git repository)" >&2
    skipped=$((skipped + 1))
    continue
  fi

  clone_cmd=(git clone "$url" "$repo")
  if [[ -n "$branch" ]]; then
    clone_cmd=(git clone --branch "$branch" --single-branch "$url" "$repo")
  fi

  if "${clone_cmd[@]}"; then
    echo "[OK] $repo"
    cloned=$((cloned + 1))
  else
    echo "[FAIL] $repo" >&2
    failed=$((failed + 1))
  fi
done

echo
echo "Result: cloned=$cloned skipped=$skipped failed=$failed"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
