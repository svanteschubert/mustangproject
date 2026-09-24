#!/bin/sh
# Build the mustang4zugferd fork and deploy the Mustang-CLI uber-JAR as a
# snapshot to the AWV GitLab Maven registry, under coordinates independent of
# the upstream mustangproject POMs:
#
#   de.ferd:mustang4zugferd:<zugferd.version>-SNAPSHOT
#
# The version comes from <zugferd.version> in factur-x/release-config.xml (a
# sibling checkout by default), read the same way
# factur-x/publish-mustang-package.sh reads pom.xml properties. Maven fixes a
# module's own <version> before any plugin runs, so the fork's POMs cannot
# read that file themselves; this script resolves the version externally and
# passes it to deploy:deploy-file instead of touching the POMs, so pulling
# further upstream commits into this branch stays conflict-free.
#
# This is a manual, local-only publish; there is no CI automation and no
# GitLab credential is stored in this repository. Authorization: this script
# has no token handling of its own; it relies on a <server> entry already
# present in your active Maven settings.xml (normally ~/.m2/settings.xml),
# the same way you already deploy mirrorUtil:
#
#   <server>
#     <id>gitlab-maven</id>
#     <configuration>
#       <httpHeaders>
#         <property>
#           <name>Private-Token</name>
#           <value>glpat-...</value>
#         </property>
#       </httpHeaders>
#     </configuration>
#   </server>
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$project_dir"

group_id='de.ferd'
artifact_id='mustang4zugferd'
repo_id='gitlab-maven'
repo_url=${MUSTANG_REPO_URL-'https://awv-git.de/api/v4/projects/1/packages/maven'}
release_config=${FACTURX_RELEASE_CONFIG-"$project_dir/../factur-x/release-config.xml"}

mvn_cmd() {
    if [ -x ./mvnw ]; then
        ./mvnw "$@"
    else
        mvn "$@"
    fi
}

# Phase 1: resolve the snapshot version. An explicit ZUGFERD_VERSION always
# wins; otherwise read <zugferd.version> from the Factur-X release config.
if [ -n "${ZUGFERD_VERSION-}" ]; then
    zugferd_version="$ZUGFERD_VERSION"
else
    if [ ! -r "$release_config" ]; then
        echo "No readable release-config.xml at: $release_config" >&2
        echo "Set FACTURX_RELEASE_CONFIG or ZUGFERD_VERSION explicitly." >&2
        exit 1
    fi
    zugferd_version=$(mvn_cmd -q -N -f "$release_config" \
        help:evaluate -Dexpression=zugferd.version -DforceStdout 2>/dev/null | tail -n 1)
fi

case "$zugferd_version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "zugferd.version did not resolve to a version: '$zugferd_version'" >&2
        echo "Checked: $release_config" >&2
        exit 1
        ;;
esac
snapshot_version="${zugferd_version}-SNAPSHOT"

# Phase 2: build and run the fork's own tests. A failing test stops the
# script before anything is uploaded.
mvn_cmd -B clean package

mustang_version=$(mvn_cmd -q -N help:evaluate -Dexpression=project.version -DforceStdout 2>/dev/null | tail -n 1)
built_jar="Mustang-CLI/target/Mustang-CLI-${mustang_version}.jar"
if [ ! -r "$built_jar" ]; then
    echo "Expected uber-JAR not found: $built_jar" >&2
    exit 1
fi

# Give the local copy a self-describing name, since the plain artifactId-less
# filename Maven produces (Mustang-CLI-<mustang_version>.jar) does not show
# this is the mustang4zugferd fork nor its own version. This is local naming
# only; it does not change the deployed Maven coordinates or filename.
jar="Mustang-CLI/target/${artifact_id}-${zugferd_version}_mustang-${mustang_version}.jar"
cp "$built_jar" "$jar"

# Phase 3: deploy, using the gitlab-maven server credentials from the active
# Maven settings.xml (see header comment above).
echo "Deploying ${group_id}:${artifact_id}:${snapshot_version} (Mustang ${mustang_version}) to ${repo_url}"

# Without -DpomFile, deploy-file publishes the Mustang-CLI POM embedded in the
# shaded JAR, whose unpublished parent (org.mustangproject:core) makes the
# artifact unresolvable. The uber-JAR needs a dependency-free POM instead.
pom=$(mktemp)
trap 'rm -f -- "$pom"' EXIT
cat >"$pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${group_id}</groupId>
  <artifactId>${artifact_id}</artifactId>
  <version>${snapshot_version}</version>
  <packaging>jar</packaging>
  <description>Shaded Mustang-CLI ${mustang_version} from the mustang4zugferd fork.</description>
</project>
EOF

mvn_cmd -B \
    org.apache.maven.plugins:maven-deploy-plugin:3.1.4:deploy-file \
    -Dfile="$jar" \
    -DpomFile="$pom" \
    -DrepositoryId="$repo_id" \
    -Durl="$repo_url"

checksum_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

echo "Published:      ${group_id}:${artifact_id}:${snapshot_version}"
echo "Mustang version: ${mustang_version}"
echo "Fork commit:     $(git rev-parse --short HEAD)"
echo "JAR SHA-256:     $(checksum_of "$jar")"
