#!/usr/bin/env bash
# Checks that an image built from ../Dockerfile has a working Android + Sonar toolchain
# and keeps CI-specific settings (proxy, heap, Sonar target) out of the image.
#
# Usage: test/smoke-test.sh <image> [max-size-bytes]
# Check commands are single quoted on purpose: they expand inside the container, not here.
# shellcheck disable=SC2016
set -uo pipefail

IMAGE="${1:?usage: $0 <image> [max-size-bytes]}"
MAX_SIZE_BYTES="${2:-1073741824}"
PLATFORM="linux/amd64"

failures=0

# The containerd image store answers for the host platform unless asked; older engines lack --platform.
inspect_image() {
  docker image inspect --platform "$PLATFORM" --format "$1" "$IMAGE" 2>/dev/null ||
    docker image inspect --format "$1" "$IMAGE"
}

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# Runs as an arbitrary non-root uid, the way a CI agent should run it, so file ownership in the
# mounted workspace matches the agent user.
in_image() { docker run --rm --platform "$PLATFORM" --user 4242:4242 "$IMAGE" bash -c "$1" 2>&1; }

expect_output() {
  local description="$1" command="$2" pattern="$3" output
  output="$(in_image "$command")"
  if grep -Eq -- "$pattern" <<<"$output"; then pass "$description"; else
    fail "$description"; printf '        command: %s\n        output:  %s\n' "$command" "${output//$'\n'/ | }"
  fi
}

expect_success() {
  local description="$1" command="$2" output
  if output="$(in_image "$command")"; then pass "$description"; else
    fail "$description"; printf '        command: %s\n        output:  %s\n' "$command" "${output//$'\n'/ | }"
  fi
}

echo "Smoke testing $IMAGE"

echo "image"
# Measured inside the container because `docker image inspect` reports compressed size on the
# containerd image store but unpacked size on the classic one.
size="$(in_image 'du -sxb / 2>/dev/null | cut -f1')"
if (( size <= MAX_SIZE_BYTES )); then pass "unpacked size $((size / 1024 / 1024)) MiB <= $((MAX_SIZE_BYTES / 1024 / 1024)) MiB"
else fail "unpacked size $((size / 1024 / 1024)) MiB exceeds $((MAX_SIZE_BYTES / 1024 / 1024)) MiB"; fi
arch="$(inspect_image '{{.Architecture}}')"
if [[ "$arch" == "amd64" ]]; then pass "architecture amd64"; else fail "architecture is $arch, Android SDK tools need amd64"; fi

echo "java"
expect_output "java 17 runtime" 'java -version' 'version "17\.'
expect_output "javac 17 compiler" 'javac -version' '^javac 17\.'
expect_success "JAVA_HOME points at the JDK" 'test -x "$JAVA_HOME/bin/javac"'

echo "android sdk"
expect_success "ANDROID_HOME and ANDROID_SDK_ROOT agree" 'test -n "$ANDROID_HOME" && test "$ANDROID_HOME" = "$ANDROID_SDK_ROOT"'
expect_output "sdkmanager on PATH" 'sdkmanager --version' '^[0-9]+\.[0-9]+'
expect_success "sdkmanager is the classic tool, not the self-downloading Android CLI" \
  '! sdkmanager --version 2>&1 | grep -q "Android CLI"'
requested_packages="$(inspect_image '{{index .Config.Labels "android.sdk.packages"}}')"
if [[ -n "$requested_packages" ]]; then pass "android.sdk.packages label: $requested_packages"
else fail "android.sdk.packages label missing"; fi
installed_packages="$(in_image 'sdkmanager --list_installed')"
for package in $requested_packages; do
  if grep -Eq "^ *${package//./\\.} " <<<"$installed_packages"; then pass "$package installed"
  else fail "$package not installed"; fi
done
expect_output "adb runs" 'adb version' 'Android Debug Bridge'
expect_output "build-tools aapt2 runs (needs glibc)" '"$ANDROID_HOME"/build-tools/*/aapt2 version' 'Android Asset Packaging Tool'
expect_success "licenses accepted" 'test -s "$ANDROID_HOME/licenses/android-sdk-license"'
expect_success "SDK writable by any uid, so AGP can add missing packages" 'touch "$ANDROID_HOME/.write-check"'

echo "sonar"
expect_output "sonar-scanner on PATH" 'sonar-scanner --version' 'SonarScanner CLI'
expect_output "sonar-scanner uses the image JDK" 'sonar-scanner -X --version' 'Java 17\.'
expect_success "sonar-scanner ships no JRE of its own" 'test ! -e /opt/sonar-scanner/jre'

echo "shell tools"
expect_output "git for Sonar SCM blame" 'git --version' '^git version'
expect_success "curl and unzip" 'command -v curl && command -v unzip'
expect_success "HOME writable by any uid" 'mkdir -p "$HOME/.gradle" "$HOME/.android" "$HOME/.sonar"'
# Java takes user.home from the passwd entry, not $HOME. Without one it becomes "?" and Gradle,
# AGP, Robolectric and Sonar scatter their caches into ./?/ in the workspace.
expect_output "Java user.home is /home/ci for a uid without a passwd entry" \
  'java -XshowSettings:properties -version' 'user\.home = /home/ci$'
expect_output "Gradle, Android and Sonar homes default under /home/ci" \
  'echo "$GRADLE_USER_HOME $ANDROID_USER_HOME $SONAR_USER_HOME"' '^/home/ci/\.gradle /home/ci/\.android /home/ci/\.sonar$'

echo "nothing CI-specific baked in"
expect_success "no proxy variables" '! env | grep -iE "^(http|https|no)_proxy="'
expect_success "no JAVA_TOOL_OPTIONS or GRADLE_OPTS" 'test -z "${JAVA_TOOL_OPTIONS:-}" && test -z "${GRADLE_OPTS:-}"'
expect_success "no SONAR_* settings" '! env | grep -E "^SONAR_(TOKEN|HOST_URL|SCANNER_JAVA_OPTS)="'

echo
if (( failures > 0 )); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
