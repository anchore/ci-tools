# anchore CI tools
`scripts/` - Contains scripts for running anchore engine directly in CI pipelines.

  * Currently only supports docker based CI/CD tools. Scripts are intended to run directly on the anchore/anchore-engine container.

## CircleCi Orbs

All finished orbs will be published to the public CircleCi orb repository.

Publish to dev first (before pushing changes to repo):
  * circleci orb publish orb.yml anchore/anchore-engine@dev:latest

Push orb changes to this repo to kick off tests for all orb commands.

Publish to production:
  * circleci orb publish orb.yml anchore/anchore-engine@<sem_ver>


### Examples for using the anchore/anchore-engine@1.0.0 CircleCi orb:

Adding a public image scan job to a CircleCi workflow:
```
version: 2.1
orbs:
  anchore-engine: anchore/anchore-engine@1.0.1
workflows:
  scan_image:
    jobs:
      - anchore/image_scan:
          image_name: anchore/anchore-engine:latest
          timeout: '300'
```

Adding a private image scan job to a CircleCi workflow:
```
version: 2.1
orbs:
  anchore-engine: anchore/anchore-engine@1.0.1
workflows:
  scan_image:
    jobs:
      - anchore/image_scan:
          image_name: anchore/anchore-engine:latest
          timeout: '300'
          private_registry: True
          registry_name: docker.io
          registry_user: "${DOCKER_USER}"
          registry_pass: "${DOCKER_PASS}"
```
Adding image scanning to your container build pipeline job.
```
version: 2.1
orbs:
  anchore-engine: anchore/anchore-engine@1.0.1
jobs:
  local_image_scan:
    executor: anchore/anchore_engine
    steps:
      - checkout
      - run:
          name: build container
          command: docker build -t ${CIRCLE_PROJECT_REPONAME}:ci .
      - anchore/analyze_local_image:
          image_name: ${CIRCLE_PROJECT_REPONAME}:ci
          timeout: '500'
```

Put a custom policy bundle in to your repo at .circleci/.anchore/policy_bundle.json
Job will be marked a 'failed' if the Anchore policy evaluation fails
```
version: 2.1
orbs:
  anchore-engine: anchore/anchore-engine@1.0.1
jobs:
  local_image_scan:
    executor: anchore/anchore_engine
    steps:
      - checkout
      - run:
          name: build container
          command: docker build -t ${CIRCLE_PROJECT_REPONAME}:ci .
      - anchore/analyze_local_image:
          image_name: ${CIRCLE_PROJECT_REPONAME}:ci
          timeout: '500'
          policy_failure: True
