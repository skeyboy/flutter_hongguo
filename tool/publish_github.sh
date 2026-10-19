#!/usr/bin/env bash
# Publish only after the pushed main commit passes the complete platform matrix.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
gh auth status >/dev/null 2>&1 || {
  echo 'Run: gh auth login --hostname github.com --web --scopes repo,workflow' >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit all project changes first.' >&2; exit 1; }
owner="$(gh api user --jq .login)"
repository="$owner/${1:-flutter_hongguo}"
if gh repo view "$repository" --json isPrivate --jq .isPrivate >/dev/null 2>&1; then
  [[ "$(gh repo view "$repository" --json isPrivate --jq .isPrivate)" == true ]] || {
    echo 'The destination must be private.' >&2; exit 1;
  }
else
  gh repo create "$repository" --private
fi
if git remote get-url origin >/dev/null 2>&1; then
  remote="$(git remote get-url origin)"
  [[ "$remote" == "https://github.com/$repository.git" || "$remote" == "git@github.com:$repository.git" ]] || {
    echo 'Existing origin is a different repository; it was not changed.' >&2; exit 1;
  }
else
  git remote add origin "https://github.com/$repository.git"
fi
gh auth setup-git
python3 tool/ci/configure_android_signing.py --upload --repo "$repository"
git push -u origin main
commit="$(git rev-parse HEAD)"
wait_for_run() {
  local workflow="$1" run_id=''
  for attempt in {1..20}; do
    run_id="$(gh run list --repo "$repository" --workflow "$workflow" --commit "$commit" --event push --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
    if [[ -n "$run_id" ]]; then
      gh run watch "$run_id" --repo "$repository" --exit-status
      return
    fi
    sleep 2
  done
  echo 'Workflow has not started; check GitHub Actions permissions and runner quota.' >&2
  return 1
}
wait_for_run build.yml
release_version="$(python3 tool/ci/release_meta.py version)"
tag="v$release_version"
if git rev-parse "$tag" >/dev/null 2>&1; then
  [[ "$(git rev-parse "$tag^{}")" == "$commit" ]] || { echo 'Existing tag points to another commit.' >&2; exit 1; }
else
  git tag -a "$tag" -m "Hongguo $release_version"
fi
git push origin "refs/tags/$tag"
wait_for_run release.yml
gh release view "$tag" --repo "$repository" --json url,isDraft --jq 'if .isDraft then error("Release is still draft") else .url end'
