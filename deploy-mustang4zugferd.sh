#!/bin/sh
# Build the mustang4zugferd fork and deploy the Mustang-CLI uber-JAR as an
# immutable release to the AWV GitLab Maven registry, under coordinates
# independent of the upstream mustangproject POMs:
#
#   de.ferd:mustang4zugferd:<zugferd.version>-<yyyyMMdd.HHmmss>-g<commit>
#
# for example 2.6.0-20261014.090801-g0a830a26. The timestamp is the UTC
# committer time of the fork commit the JAR is built from, and the suffix is
# that commit's short hash, so the version names its exact source and sorts by
# commit time. The `g` prefix keeps an all-digit hash from turning the version
# into a timestamped Maven snapshot (<base>-<yyyyMMdd.HHmmss>-<number>).
#
# The ZUGFeRD part comes from <zugferd.version> in factur-x/release-config.xml
# (a sibling checkout by default). Maven fixes a module's own <version> before
# any plugin runs, so the fork's POMs cannot read that file themselves; this
# script resolves the version externally and passes it to deploy:deploy-file
# instead of touching the POMs, so pulling further upstream commits into this
# branch stays conflict-free.
#
# A published version never changes: the script refuses a dirty working tree
# and a version the registry already holds. Factur-X pins the version together
# with the JAR's SHA-256 in its pom.xml; the script prints those lines at the
# end.
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

# Phase 1: the commit is the source of the version, so it must describe the
# JAR's content completely.
if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree is not clean; commit or stash these changes first:" >&2
    git status --short >&2
    exit 1
fi

# Phase 2: resolve the ZUGFeRD version. An explicit ZUGFERD_VERSION always
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

commit=$(git rev-parse HEAD)
commit_time=$(TZ=UTC git show -s --date=format-local:%Y%m%d.%H%M%S --format=%cd HEAD)
version="${zugferd_version}-${commit_time}-g$(git rev-parse --short=8 HEAD)"

# Phase 3: refuse a version that is already published. The probe uses an empty
# local repository, so a locally installed copy cannot answer it. Only a
# "not found" after asking the AWV registry counts as unpublished; any other
# failure (e.g. a missing or rejected token) stops the script.
probe_repo=$(mktemp -d)
pom=$(mktemp)
trap 'rm -rf -- "$probe_repo" "$pom"' EXIT
if probe_output=$(mvn_cmd -B -N -Dmaven.repo.local="$probe_repo" \
        org.apache.maven.plugins:maven-dependency-plugin:3.8.1:get \
        -Dartifact="${group_id}:${artifact_id}:${version}" \
        -DremoteRepositories="${repo_id}::default::${repo_url}" \
        -Dtransitive=false 2>&1); then
    echo "${group_id}:${artifact_id}:${version} is already published." >&2
    echo "A published version never changes; commit the change to this fork and publish that commit." >&2
    exit 1
fi
case "$probe_output" in
    *"Could not transfer"*) probe_state=failed ;;
    *"Downloading from ${repo_id}: ${repo_url}/"*"Could not find artifact ${group_id}:${artifact_id}:jar:${version} "*) probe_state=new ;;
    *) probe_state=failed ;;
esac
if [ "$probe_state" != new ]; then
    printf '%s\n' "$probe_output" >&2
    echo "Could not check whether ${version} is already published at ${repo_url}." >&2
    exit 1
fi

# Phase 4: build and run the fork's own tests. A failing test stops the
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
# this is the mustang4zugferd fork nor its own version. Factur-X copies the
# resolved JAR under this same name. This is local naming only; it does not
# change the deployed Maven coordinates or filename.
jar="Mustang-CLI/target/${artifact_id}-${version}_mustang-${mustang_version}.jar"
cp "$built_jar" "$jar"

# Phase 5: deploy, using the gitlab-maven server credentials from the active
# Maven settings.xml (see header comment above).
echo "Deploying ${group_id}:${artifact_id}:${version} (Mustang ${mustang_version}) to ${repo_url}"

# Without -DpomFile, deploy-file publishes the Mustang-CLI POM embedded in the
# shaded JAR, whose unpublished parent (org.mustangproject:core) makes the
# artifact unresolvable. The uber-JAR needs a dependency-free POM instead.
cat >"$pom" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${group_id}</groupId>
  <artifactId>${artifact_id}</artifactId>
  <version>${version}</version>
  <packaging>jar</packaging>
  <description>Shaded Mustang-CLI ${mustang_version} from mustang4zugferd fork commit ${commit}.</description>
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
jar_sha256=$(checksum_of "$jar")

echo "Published:       ${group_id}:${artifact_id}:${version}"
echo "Mustang version: ${mustang_version}"
echo "Fork commit:     ${commit}"
echo "JAR SHA-256:     ${jar_sha256}"
if [ -z "$(git branch -r --contains HEAD)" ]; then
    echo "WARNING: commit ${commit} is on no remote branch yet; push it so the version stays traceable." >&2
fi
echo
echo "Pin this release in factur-x/pom.xml, in a commit that changes only these lines:"
echo "        <mustang.version>${version}</mustang.version>"
echo "        <mustang.upstream.version>${mustang_version}</mustang.upstream.version>"
echo "        <mustang.sha256>${jar_sha256}</mustang.sha256>"
