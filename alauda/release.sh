#!/bin/bash

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
ROOT=$(dirname "$WD")

set -eux

DOCKER_HUB=${DOCKER_HUB:-build-harbor.alauda.cn/asm}
HELM_HUB=${HELM_HUB:-build-harbor.alauda.cn/asm/istio-charts}
S3_BUCKET=${S3_BUCKET:-istio-build/dev}

# Enable emulation required for cross compiling a few images (VMs)
export ISTIO_DOCKER_QEMU=true

# Use a pinned version in case breaking changes are needed
BUILDER_SHA=5cdbd863f36634f8191bdb1084b5e4f69cfdc9bb

TAG="${GIT_DESCRIBE_TAG}"
VERSION="${TAG}"

export ISTIO_VERSION=$TAG

# In CI we want to store the outputs to artifacts, which will preserve the build
# If not specified, we can just create a temporary directory
WORK_DIR=${WORK_DIR:-/tmp/istio-build}

MANIFEST=$(cat <<EOF
version: ${VERSION}
docker: ${DOCKER_HUB}
directory: ${WORK_DIR}
ignoreVulnerability: true
dependencies:
${DEPENDENCIES:-$(cat <<EOD
  istio:
    localpath: ${ROOT}
  api:
    git: https://github.com/istio/api
    auto: modules
  proxy:
    git: https://github.com/istio/proxy
    auto: deps
  client-go:
    git: https://github.com/istio/client-go
    auto: modules
  test-infra:
    git: https://github.com/istio/test-infra
    branch: master
  tools:
    git: https://github.com/istio/tools
    branch: release-1.28
  envoy:
    git: https://github.com/envoyproxy/envoy
    auto: proxy_workspace
  release-builder:
    git: https://github.com/alauda-mesh/release-builder
    sha: ${BUILDER_SHA}
  ztunnel:
    git: https://github.com/istio/ztunnel
    auto: deps
architectures: [linux/amd64, linux/arm64]
dashboards:
  istio-mesh-dashboard: 7639
  istio-performance-dashboard: 11829
  istio-service-dashboard: 7636
  istio-workload-dashboard: 7630
  pilot-dashboard: 7645
  istio-extension-dashboard: 13277
  ztunnel-dashboard: 21306
EOD
)}
${PROXY_OVERRIDE:-}
EOF
)

go install "github.com/alauda-mesh/release-builder@${BUILDER_SHA}"

release-builder build --manifest <(echo "${MANIFEST}")

release-builder validate --release "${WORK_DIR}/out"

if [[ -z "${DRY_RUN:-}" ]]; then
  release-builder publish --release "${WORK_DIR}/out" \
    --s3bucket "${S3_BUCKET}" --s3aliases "${TAG}" \
    --dockerhub "${DOCKER_HUB}" --helmhub "${HELM_HUB}"
fi
