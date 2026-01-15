#
# Version handling
#

version_extra := ""
version_dirty := `[ -z "$(git status -s)" ] || echo "-$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 2)$(date +"%H%M")"`
version := `git describe --tags --dirty --always` + version_dirty + version_extra

# Print version that will be used in the build
version:
  @echo "Using version: {{version}}"

_is_clean:
  [ -z "`git status -s`" ] || exit 1

#
# Downloading all tools locally
#

localbin := "bin"
localbinpath := `pwd`/localbin

_localbin:
  @mkdir -p {{localbin}}

# Download all tools locally
tools: _oras _skopeo

# oras
oras_version := "v1.2.0"
oras := localbin / "oras" + "-" + oras_version
@_oras: _localbin
  [ -f {{oras}} ] || just _goinstall "oras.land/oras/cmd/oras" {{oras_version}} "oras" {{oras}}

# skopeo
skopeo_version := "v1.16.1"
skopeo := localbin / "skopeo" + "-" + skopeo_version
@_skopeo: _localbin
  [ -f {{skopeo}} ] || just _goinstall "github.com/containers/skopeo/cmd/skopeo" {{skopeo_version}} "skopeo" {{skopeo}} "--tags containers_image_openpgp,exclude_graphdriver_btrfs"

# go install helper
_goinstall PACKAGE VERSION BINNAME TARGET FLAGS="": _localbin
  #!/usr/bin/env bash
  set -euo pipefail

  echo "Installing go package: {{PACKAGE}}@{{VERSION}}..."
  GOBIN=`pwd`/{{localbin}} go install {{FLAGS}} {{PACKAGE}}@{{VERSION}}
  mv {{localbin}}/{{BINNAME}} {{TARGET}}

#
# Docker recipes
#

oci := ""
skopeo_dest_insecure := if oci == "http" { "--dest-tls-verify=false" } else { "" }
oras_insecure := if oci == "http" { "--plain-http" } else { "" }

_docker-build bin: build
  cp bin/{{bin}} config/docker/{{bin}}/
  cd config/docker/{{bin}}/ && docker build --platform=linux/amd64 -t {{oci_repo}}/{{oci_prefix}}/{{bin}}:{{version}} -f Dockerfile .

skopeo_copy_flags := if env("DOCKER_HOST", "") != "" { "--src-daemon-host " + env_var("DOCKER_HOST") } else { "" }
_docker-push bin: _skopeo
  {{skopeo}} --insecure-policy copy {{skopeo_copy_flags}} {{skopeo_dest_insecure}} docker-daemon:{{oci_repo}}/{{oci_prefix}}/{{bin}}:{{version}} docker://{{oci_repo}}/{{oci_prefix}}/{{bin}}:{{version}}
