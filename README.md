# anchore CI tools
Contains scripts for running anchore engine directly in CI pipelines.

Currently only supports docker based CI/CD tools. Scripts are intended to run directly on the anchore/anchore-engine container.

# CircleCi Orbs

All finished orbs will be published to the public CircleCi orb repository.
  * circleci orb publish orb.yml anchore/anchore-engine@<sem_ver>


### anchore/anchore-engine

This orb will allow stateless docker image security scanning.

Examples for how to run this orb can be found in .circleci/config.yml
