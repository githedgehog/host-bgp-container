set shell := ["bash", "-euo", "pipefail", "-c"]

import "hack/tools.just"

# Print list of available recipes
default:
  @just --list

# build everything
all: build && version

oci_repo := "127.0.0.1:30000"
oci_prefix := "githedgehog/host-bgp"
oci_fabricator_prefix := "githedgehog/fabricator"

# Build all artifacts
build:
  docker build --platform=linux/amd64 -t {{oci_repo}}/{{oci_prefix}}:{{version}} -f Dockerfile .

# Push all host-bgp artifacts
push: _skopeo _oras build && version
  {{skopeo}} --insecure-policy copy {{skopeo_copy_flags}} {{skopeo_dest_insecure}} docker-daemon:{{oci_repo}}/{{oci_prefix}}:{{version}} docker://{{oci_repo}}/{{oci_prefix}}:{{version}}
  docker image rm {{oci_repo}}/{{oci_prefix}}:latest || true
  docker tag {{oci_repo}}/{{oci_prefix}}:{{version}} {{oci_repo}}/{{oci_prefix}}:latest
  docker save -o host-bgp.tar {{oci_repo}}/{{oci_prefix}}:latest
  oras push {{oras_insecure}} {{oci_repo}}/{{oci_fabricator_prefix}}/host-bgp:{{version}} host-bgp.tar
