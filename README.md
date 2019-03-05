# Anchore CI tools [![CircleCI](https://circleci.com/gh/anchore/ci-tools.svg?style=svg)](https://circleci.com/gh/anchore/ci-tools)

An assortment of scripts & tools for integrating Anchore Engine into your CI/CD pipeline.

### `scripts/anchore-ci-tools.py`

  * Currently only supports docker based CI/CD tools. 
  * Script is intended to run directly on Anchore Engine containers.

# CircleCI Orbs

Source code for CircleCi orbs can be found in circleci-orbs/<ORB>/.

# Anchore inline-scan container

Image is built using the official Anchore Engine image base. It contains a Postgresql database pre-loaded with Anchore vulnerability data from https://github.com/anchore/engine-db-preload daily. Also contains a Docker registry which is used for passing images to Anchore Engine for vulnerability scanning.

Container is built using the `scripts/build_image.sh` script. The version of anchore-engine to build with can be specified with the environment variable `ANCHORE_VERSION=<VERSION>`.

After building the inline_scan container locally, the `scripts/inline_scan` script can be called using this container by setting the environment variable `ANCHORE_CI_IMAGE=stateless_anchore:ci`.

### `scripts/inline_scan`
Wrapper script for inline_scan container, requires Docker & BASH to be installed on system running the script.
* Call script directly from github with: 
  
  ```curl -s https://raw.githubusercontent.com/anchore/ci-tools/scripts/inline_scan | bash -s -- [OPTIONS] <IMAGE_NAME>```

#### Pull multiple images from dockerhub, scan and generate reports.
```bash
inline_scan -p -r alpine:latest ubuntu:latest centos:latest
```

#### Pass Dockerfile to image scan, after docker build.
```bash
docker build -t example-image:latest -f ./Dockerfile .
inline_scan -d ./Dockerfile example-image:latest
```

#### Scan image using custom policy bundle, fail script upon failed policy evaluation.
```bash
inline_scan -f -p ./policy-bundle.json example-image:latest
```

#### Scan a directory full of image archives, with timeout on scans set to 500s.
```bash
mkdir images
docker save example-image:latest -o images/example-image+latest.tar
docker save example-image:dev -o images/example-image+dev.tar
inline_scan -v ./images -t 500
```