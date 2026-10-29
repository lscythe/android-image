# android-ci

A general-purpose Docker image for building, testing and analysing Android projects in CI.

It holds only the toolchain. Proxy, JVM heap, Gradle flags and Sonar settings are passed in when you run it, so the same image works with any CI server, network or project.

| Tool | Default | Location |
| --- | --- | --- |
| Ubuntu | 24.04 | base image |
| JDK | Temurin 17 (no `jmods` or `src.zip`) | `/opt/java/openjdk` (`JAVA_HOME`) |
| Android cmdline-tools | 21.0 (build 15641748) | `/opt/android-sdk/cmdline-tools/latest` |
| Android SDK packages | `platform-tools`, `platforms;android-36`, `build-tools;35.0.0` | `/opt/android-sdk` (`ANDROID_HOME`, `ANDROID_SDK_ROOT`) |
| SonarScanner CLI | 7.2.0.5079 (no bundled JRE, runs on the image JDK) | `/opt/sonar-scanner` |
| Shell tools | `git`, `curl`, `unzip`, `ca-certificates`, `fontconfig`, `tzdata` | |

`java`, `javac`, `sdkmanager`, `adb` and `sonar-scanner` are on `PATH`. Any command runs as given. The small entrypoint only adds a passwd entry for uids that lack one (see [Running as the agent's user](#running-as-the-agents-user)). It is `linux/amd64` only, because Google ships the Linux Android SDK tools for x86_64 only.

## Why Ubuntu and not Alpine

Alpine uses musl libc. `aapt2` (from build-tools, and the copy the Android Gradle Plugin downloads from Maven) and `adb` are glibc binaries. AGP runs `aapt2` for every Android module, unit tests included, so those builds break on Alpine. Ubuntu costs about 75 MB more and works.

## Build arguments

| Argument | Default | Notes |
| --- | --- | --- |
| `ANDROID_PACKAGES` | `platform-tools platforms;android-36 build-tools;35.0.0` | Space separated `sdkmanager` ids. Each extra platform or build-tools adds about 100 MB. |
| `CMDLINE_TOOLS_BUILD` / `CMDLINE_TOOLS_SHA256` | `15641748` / pinned | Change both together. Newer releases deprecate `sdkmanager` (22.0) and then hand it off to the Android CLI (23.0), which downloads itself on first use and sends usage data, so 21.0 is the default. |
| `SONAR_SCANNER_VERSION` / `SONAR_SCANNER_SHA256` | `7.2.0.5079` / pinned | Change both together. Sonar publishes `<zip>.sha256` next to each zip. |
| `JDK_IMAGE` | `eclipse-temurin:17-jdk-noble` | Any image with a JDK in `/opt/java/openjdk`, for example `eclipse-temurin:21-jdk-noble`. |
| `UBUNTU_VERSION` | `24.04` | Keep it in step with `JDK_IMAGE`. |
| `https_proxy` | unset | Used only while building, never stored in the image. `sdkmanager` gets it as `--proxy_host`/`--proxy_port`. |

## Building

GitHub Actions ([.github/workflows/image.yml](.github/workflows/image.yml)) builds the image, runs the smoke test and pushes it to `ghcr.io/<owner>/<repo>`:

- pull requests: build and test only
- `main`: tags `latest` and `sha-<short>`
- tags `v1.2.3`: tags `1.2.3` and `1.2`
- every Monday 03:00 UTC: rebuilds `latest` without the layer cache, picking up Ubuntu and JDK security updates. Version tags stay fixed, so pin a version when you need reproducible builds and follow `latest` when you want the patches.
- manual run (Actions, image, Run workflow): override `android_packages` or the Sonar version without editing the Dockerfile

To build and test locally (on Apple silicon this runs under emulation and is slower):

```bash
docker buildx build --platform linux/amd64 --load -t android-ci:dev .
```

```bash
test/smoke-test.sh android-ci:dev
```

The smoke test checks the tools, the installed SDK packages, a 1 GiB size limit, that the container works under an arbitrary uid, and that no proxy or Sonar settings are baked in.

To copy a published image into another registry, such as Nexus or Artifactory:

```bash
skopeo copy docker://ghcr.io/<owner>/<repo>:1.0.0 docker://<registry>/android-ci:1.0.0
```

`docker pull`, `docker tag` and `docker push` work as well.

## Running

### Host requirements

- Docker 20.10.10 or newer. Ubuntu 24.04's glibc calls `clone3`, and older Docker seccomp profiles reject it with `EPERM`, which makes even `java` fail inside the container. Hosts on older distributions such as Ubuntu 18.04 often have an older Docker, so check `docker version`.
- An x86_64 host, or one that can emulate it.

### Basic usage

Mount the project at `/workspace` (the working directory) and run any command:

```bash
docker run --rm --init \
  --user "$(id -u):$(id -g)" \
  -v "$PWD":/workspace \
  -v "$HOME/.cache/android-ci/gradle":/home/ci/.gradle \
  android-ci:dev ./gradlew --no-daemon testDebugUnitTest
```

- `--user` keeps files in the workspace owned by the CI agent's user, so the agent can clean them up.
- Mounting `/home/ci/.gradle` (and `/home/ci/.sonar` for scans) keeps the Gradle distribution, dependencies and Sonar plugins between runs. Without it every run downloads everything again.
- `--init` reaps the worker processes Gradle forks.

### Running as the agent's user

`HOME` is `/home/ci`, writable by any uid. Java ignores `$HOME`, though: it reads the home directory from the passwd entry, and a uid passed with `--user` usually has none. Java then sets `user.home` to `?`, and Gradle, AGP, Robolectric and Sonar write their caches into a `?/` folder inside the workspace.

The entrypoint prevents that. When the current uid has no passwd entry, it serves one with home `/home/ci` through `nss_wrapper` (`LD_PRELOAD`). `/etc/passwd` stays read-only, and every child process, including Gradle's test workers, sees the right home.

If your CI runner replaces the entrypoint, `GRADLE_USER_HOME`, `ANDROID_USER_HOME` and `SONAR_USER_HOME` still point under `/home/ci`. Tools that only read `user.home`, such as Robolectric's artifact cache, will not.

### Proxy

Nothing is baked in, so pass the proxy per run:

```bash
PROXY_HOST=proxy.example.com
PROXY_PORT=8080
docker run --rm \
  -e http_proxy="http://$PROXY_HOST:$PROXY_PORT" \
  -e https_proxy="http://$PROXY_HOST:$PROXY_PORT" \
  -e no_proxy="localhost,127.0.0.1,.example.com" \
  -e JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=$PROXY_HOST -Dhttp.proxyPort=$PROXY_PORT -Dhttps.proxyHost=$PROXY_HOST -Dhttps.proxyPort=$PROXY_PORT -Dhttp.nonProxyHosts=localhost|127.0.0.1|*.example.com" \
  ...
```

`curl` and `git` use the environment variables. Gradle, `sdkmanager`, Robolectric and `sonar-scanner` are Java programs and use `JAVA_TOOL_OPTIONS`.

### Memory

The JVM heap is only part of a Java process. Metaspace, the JIT, threads and glibc's malloc arenas come on top, and every test worker is a JVM of its own. Run Gradle and Sonar one after the other, never in parallel.

These figures come from a large multi-module app (about 40 modules: AGP 8.11, Kotlin 2.0, KSP, Robolectric, Kover), run under a 3800 MB container limit:

- Compiling the biggest module needed a 2 GB heap; 1.5 GB failed with "Not enough memory to run compilation".
- Metaspace in the Gradle JVM reached about 560 MB, so a 512 MB cap fails.
- With two workers, compilation was OOM-killed at about 3.7 GB.
- The Gradle JVM keeps the memory it used for compiling, about 2.7 GB. A test JVM with Gradle's default 512 MB heap takes another 0.3 to 1.4 GB, so compiling and testing in one Gradle call does not fit in 4 GB.
- Compiling first and testing in a second call kept the test phase at about 2.9 GB.

Those runs were under amd64 emulation on Apple silicon, which adds some native memory. A native x86 host will be somewhat lower.

With 6 to 8 GB, a single Gradle call with `-Xmx2g` should fit: the figures above add up to about 5.5 GB for two workers, though that was not run. For 4 GB:

| Setting | Value | Why |
| --- | --- | --- |
| Gradle JVM | `-Dorg.gradle.jvmargs="-Xmx2g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=192m -XX:+UseSerialGC -XX:TieredStopAtLevel=1"` | 2 GB heap; Serial GC and C1-only JIT have the smallest native footprint |
| glibc | `-e MALLOC_ARENA_MAX=2` | stops glibc creating a malloc arena per CPU core |
| Workers | `--max-workers=1` | one compile or test JVM at a time |
| Kotlin compiler | `-Pkotlin.compiler.execution.strategy=in-process` | no separate Kotlin daemon JVM |
| Build | two Gradle calls, see [Unit tests with coverage](#unit-tests-with-coverage) | the test phase must not compile anything |
| SonarScanner | `-e SONAR_SCANNER_JAVA_OPTS="-Xmx2g"` | not measured; lower it if the scan is killed |
| Container | `--memory=3800m` | fails fast instead of starving the host |

If a 4 GB build is still killed, the reliable fix is a bigger agent (6 to 8 GB) or swap on the host.

### Android SDK packages

The SDK is writable by any uid and its licenses are accepted, so AGP installs whatever a project needs beyond the defaults: another platform or build-tools, or the NDK and CMake. In a fresh container that download repeats on every run.

Small packages are best baked in with `ANDROID_PACKAGES`. The NDK is too big for the base image (about 2 GB unpacked), and AGP fetches it whenever a module sets `ndkVersion` or `externalNativeBuild`, even for unit tests. Keep it on a volume so it downloads once:

```bash
docker run ... \
  -v "$HOME/.cache/android-ci/ndk":/opt/android-sdk/ndk \
  -v "$HOME/.cache/android-ci/cmake":/opt/android-sdk/cmake \
  ...
```

You can also install packages explicitly, for example in a derived image:

```bash
sdkmanager "platforms;android-35"
```

## Examples

These are plain shell, so they fit in a script step of any CI server (GitHub Actions, GitLab CI, Jenkins, Bamboo, and so on). Add the proxy flags above when your network needs them.

### Unit tests with coverage

On a 4 GB host, compile in one Gradle call and test in a second one (see [Memory](#memory)). `compileDebugUnitTestSources` compiles main and test code in every module that has the `debug` variant. Use the matching `compile<Variant>UnitTestSources` task for modules with product flavors.

```bash
gradle_in_image() {
  docker run --rm --init --memory=3800m \
    --user "$(id -u):$(id -g)" \
    -v "$PWD":/workspace \
    -v "$HOME/.cache/android-ci/gradle":/home/ci/.gradle \
    -v "$HOME/.cache/android-ci/ndk":/opt/android-sdk/ndk \
    -e MALLOC_ARENA_MAX=2 \
    <registry>/android-ci:1.0.0 \
    ./gradlew --no-daemon --max-workers=1 \
      -Dorg.gradle.jvmargs="-Xmx2g -XX:MaxMetaspaceSize=768m -XX:ReservedCodeCacheSize=192m -XX:+UseSerialGC -XX:TieredStopAtLevel=1" \
      -Pkotlin.compiler.execution.strategy=in-process \
      "$@"
}

gradle_in_image compileDebugUnitTestSources
gradle_in_image koverXmlReport
```

With 6 to 8 GB, a single `gradle_in_image testDebugUnitTest koverXmlReport` call should be enough (estimated, not measured).

If the project uses Gradle Java toolchains and the CI network cannot download JDKs, point Gradle at the image JDK with `-Dorg.gradle.java.installations.paths=/opt/java/openjdk -Dorg.gradle.java.installations.auto-download=false`.

### SonarQube scan

```bash
docker run --rm --init --memory=3800m \
  --user "$(id -u):$(id -g)" \
  -v "$PWD":/workspace \
  -v "$HOME/.cache/android-ci/sonar":/home/ci/.sonar \
  -e SONAR_HOST_URL="https://sonarqube.example.com" \
  -e SONAR_TOKEN="$SONAR_TOKEN" \
  -e SONAR_SCANNER_JAVA_OPTS="-Xmx2g" \
  <registry>/android-ci:1.0.0 \
  sonar-scanner \
    -Dsonar.scanner.skipJreProvisioning=true \
    -Dsonar.projectKey=<project-key> \
    -Dsonar.branch.name="<branch>" \
    -Dsonar.coverage.jacoco.xmlReportPaths='**/build/reports/kover/report.xml'
```

- Passing the token as `SONAR_TOKEN` keeps it out of the process list, unlike `-Dsonar.token`.
- `sonar.scanner.skipJreProvisioning=true` makes the scanner use the image JDK instead of downloading a JRE from the server on every run.
- Paths in Sonar properties are relative to `/workspace`, the mounted project.

## Extending

Put anything specific to a project or company in a derived image:

```dockerfile
FROM <registry>/android-ci:1.0.0
USER root

# TLS inspection: trust a corporate root CA in both the OS and the JDK.
COPY corp-root-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates \
 && keytool -importcert -noprompt -cacerts -storepass changeit \
      -alias corp-root -file /usr/local/share/ca-certificates/corp-root-ca.crt

# NDK and CMake for native code (about 2 GB, which is why the base image leaves them out).
RUN sdkmanager "ndk;27.2.12479018" "cmake;3.22.1"
```

Node.js (for React Native bundling) and emulator system images are also left out to keep the base image under 1 GiB.
