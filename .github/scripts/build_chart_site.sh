#!/usr/bin/env bash
# Build the files of the Helm repository for one new chart version.
#
# usage: build_chart_site.sh CHART_DIR SITE_DIR
#
# The repository is a static site: index.yaml plus the chart packages. GitHub Pages
# replaces the whole site at each deployment, so SITE_DIR must hold everything:
# the packages the site already serves, the new package and the merged index.
# Packages up to 1.1.20 are GitHub release assets: the index keeps pointing to them.
set -euo pipefail

chart_dir=$1
site=$2
repo_url=${REPO_URL:-https://charts.diracgrid.org}
work=$(mktemp -d)

# The query string avoids a cached copy: a deployment may have happened a minute ago.
curl -fsSL "${repo_url}/index.yaml?nocache=${GITHUB_RUN_ID:-$$}" -o "${work}/old-index.yaml"

name=$(yq '.name' "${chart_dir}/Chart.yaml")
version=$(yq '.version' "${chart_dir}/Chart.yaml")
if NAME="${name}" VERSION="${version}" yq -e \
    '.entries[strenv(NAME)][] | select(.version == strenv(VERSION))' \
    "${work}/old-index.yaml" > /dev/null 2>&1; then
  echo "${name} ${version} is already published: nothing to do"
  echo "published=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

mkdir -p "${site}" "${work}/new"

# Carry forward the packages that this site serves itself, and check their digest.
REPO_URL="${repo_url}" yq \
    '.entries[][] | select(.urls[0] | test("^" + strenv(REPO_URL) + "/")) | [.urls[0], .digest] | @tsv' \
    "${work}/old-index.yaml" |
  while IFS=$'\t' read -r url digest; do
    [[ -n "${url}" ]] || continue
    file="${site}/$(basename "${url}")"
    curl -fsSL "${url}" -o "${file}"
    echo "${digest}  ${file}" | sha256sum --check --quiet -
  done

# Index the new package only, then merge: the existing entries stay as they are.
helm package "${chart_dir}" --destination "${work}/new"
helm repo index "${work}/new" --url "${repo_url}" --merge "${work}/old-index.yaml"
mv "${work}/new/"*.tgz "${work}/new/index.yaml" "${site}/"

# Nothing that was published may disappear.
missing=$(comm -23 \
  <(yq '.entries[][] | .name + " " + .version' "${work}/old-index.yaml" | sort) \
  <(yq '.entries[][] | .name + " " + .version' "${site}/index.yaml" | sort))
if [[ -n "${missing}" ]]; then
  echo "::error::Versions missing from the new index: ${missing}"
  exit 1
fi

echo "Publishing ${name} ${version}"
echo "published=true" >> "${GITHUB_OUTPUT:-/dev/null}"
