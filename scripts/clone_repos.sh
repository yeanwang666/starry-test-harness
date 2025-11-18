#!/usr/bin/env bash
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case $1 in
    --whitelist)
      WHITELIST="$2"
      shift 2
      ;;
    --dest)
      DEST="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${WHITELIST:-}" || -z "${DEST:-}" ]]; then
  echo "Usage: clone_repos.sh --whitelist <file> --dest <dir>"
  exit 1
fi

branch="$(yq -r '.branch' "$WHITELIST")"


mapfile -t repos < <(yq -r '.repos[]' "$WHITELIST" | sed 's/"//g')

mkdir -p "$DEST"

echo "[clone] Destination: $DEST"
echo "[clone] Branch: $branch"


for repo in "${repos[@]}"; do
  [[ -z "$repo" ]] && continue   # skip empty lines

  name=$(basename "$repo" .git)
  target="$DEST/$name"

  echo "[clone] Processing repo: $repo"

  if [[ -d "$target/.git" ]]; then
    echo "[clone] Updating: $name"
    git -C "$target" fetch
    git -C "$target" checkout "$branch"
    git -C "$target" pull --ff-only
  else
    echo "[clone] Cloning: $repo → $target"
    git clone --branch "$branch" "$repo" "$target"
  fi
done