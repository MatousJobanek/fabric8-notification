#!/bin/bash

# Output command before executing
set -x

# Exit on error
set -e

# Source environment variables of the jenkins slave
# that might interest this worker.
function load_jenkins_vars() {
  if [ -e "jenkins-env.json" ]; then
    eval "$(./env-toolkit load -f jenkins-env.json DEVSHIFT_TAG_LEN QUAY_USERNAME QUAY_PASSWORD JENKINS_URL GIT_BRANCH GIT_COMMIT BUILD_NUMBER ghprbSourceBranch ghprbActualCommit BUILD_URL ghprbPullId)"
  fi
}

function install_deps() {
  # We need to disable selinux for now, XXX
  /usr/sbin/setenforce 0 || :

  # Get all the deps in
  yum -y install \
    docker \
    make \
    git \
    curl

  service docker start

  echo 'CICO: Dependencies installed'
}

function cleanup_env {
  EXIT_CODE=$?
  echo "CICO: Cleanup environment: Tear down test environment"
  echo "CICO: Exiting with $EXIT_CODE"
}

function prepare() {
  # Let's test
  make docker-start
  make docker-check-go-format
  make docker-deps
  #make docker-analyze-go-code
  make docker-generate
  make docker-build
  echo 'CICO: Preparation complete'
}

function run_tests_without_coverage() {
  make docker-test-unit-no-coverage-junit
  #trap cleanup_env EXIT

  #make docker-test-integration-no-coverage
  #make docker-test-remote-no-coverage
  echo "CICO: ran tests without coverage"
}

function run_tests_with_coverage() {
  # Run the unit tests that generate coverage information
  make docker-test-unit
  trap cleanup_env EXIT

  # Run the integration tests that generate coverage information
  make docker-test-integration

  # Run the remote tests that generate coverage information
  make docker-test-remote

  # Output coverage
  make docker-coverage-all

  # Upload coverage to codecov.io
  cp tmp/coverage.mode* coverage.txt
  bash <(curl -s https://codecov.io/bash) -X search -f coverage.txt -t 86037e2c-2ae3-4d77-bb55-e4118c7f2f59 #-X fix

  echo "CICO: ran tests and uploaded coverage"
}

function tag_push() {
  local tag=$1

  docker tag fabric8-notification-deploy $tag
  docker push $tag
}

function deploy() {
  TAG=$(echo $GIT_COMMIT | cut -c1-${DEVSHIFT_TAG_LEN})
  REGISTRY="quay.io"

  if [ -n "${QUAY_USERNAME}" -a -n "${QUAY_PASSWORD}" ]; then
    docker login -u ${QUAY_USERNAME} -p ${QUAY_PASSWORD} ${REGISTRY}
  else
    echo "Could not login, missing credentials for the registry"
  fi

  # Let's deploy
  make docker-image-deploy

  if [ "$TARGET" = "rhel" ]; then
    tag_push ${REGISTRY}/openshiftio/rhel-fabric8-services-fabric8-notification:$TAG
    tag_push ${REGISTRY}/openshiftio/rhel-fabric8-services-fabric8-notification:latest
  else
    tag_push ${REGISTRY}/openshiftio/fabric8-services-fabric8-notification:$TAG
    tag_push ${REGISTRY}/openshiftio/fabric8-services-fabric8-notification:latest
  fi
  echo 'CICO: Image pushed, ready to update deployed app'
}

function cico_setup() {
  load_jenkins_vars;
  install_deps;
  prepare;
}
