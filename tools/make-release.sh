#!/usr/bin/env bash
# Build dist/mvn-deploy-<tag>.tar.gz + .sha256 for a GitHub Release.
# Usage: tools/make-release.sh v1.0.0   (also pins MVN_PINNED_REF in the archived install.sh)
set -Eeuo pipefail
tag="${1:?usage: make-release.sh vX.Y.Z}"
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "tag must look like v1.0.0" >&2
  exit 2
}
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ver="${tag#v}"
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
dir="${stage}/mvn-deploy-${tag}"
mkdir -p "${dir}"
tar -C "${ROOT}" --exclude=.git --exclude=dist -cf - . | tar -C "${dir}" -xf -
sed -i "s/^MVN_PINNED_REF=.*/MVN_PINNED_REF=\"${tag}\"/" "${dir}/install.sh"
sed -i "s/^MVN_VERSION=.*/MVN_VERSION=\"${ver}\"/" "${dir}/config/defaults.conf"
mkdir -p "${ROOT}/dist"
out="${ROOT}/dist/mvn-deploy-${tag}.tar.gz"
tar -C "${stage}" --owner=0 --group=0 -czf "${out}" "mvn-deploy-${tag}"
(cd "${ROOT}/dist" && sha256sum "mvn-deploy-${tag}.tar.gz" > "mvn-deploy-${tag}.tar.gz.sha256")
cat "${ROOT}/dist/mvn-deploy-${tag}.tar.gz.sha256"
echo "Upload both files to the GitHub Release ${tag}; commit the pinned install.sh in the tag."
