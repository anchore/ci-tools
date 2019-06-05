# Anchore CircleCi Orbs
All orbs are tested with .circleci/config.yaml of this repo. Finished orbs will be published to the public CircleCi orb repository under the anchore namespace.

* To test orb changes, create a branch that starts with `orb_`. 
* Push the `orb_` branch to origin and a `@dev:alpha` version of the orb will be published. 

After the `@dev:alpha` orb is successfully published, a temporary tag that begins with `integration-orb_` will be pushed to the orb's git registry. This tag will trigger all orb tests to be started. Once all tests have passed, the dev orb can be promoted to production.

* Publish dev orb to production - promote major, minor, or patch version based on changes made.
  * `circleci orb publish promote anchore/anchore-engine@dev:alpha [major|minor|patch]`
