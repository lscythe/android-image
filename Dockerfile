# syntax=docker/dockerfile:1

# General-purpose Android CI image: JDK, Android SDK and SonarScanner CLI.
# Everything environment-specific (proxy, heap sizes, Sonar server and token, Gradle flags)
# is supplied at `docker run` time, never baked in.
#
# Ubuntu rather than Alpine: aapt2 (from build-tools and from Maven, used by AGP for every
# Android module's unit tests) and adb are glibc binaries and do not run on musl.

ARG UBUNTU_VERSION=24.04
ARG JDK_IMAGE=eclipse-temurin:17-jdk-noble
# cmdline-tools 21.0. From 22.0 sdkmanager is deprecated, and from 23.0 it hands off to the
# Android CLI, which downloads itself on first use and sends usage data: unsuitable for CI.
ARG CMDLINE_TOOLS_BUILD=15641748
ARG CMDLINE_TOOLS_SHA256=a66d5ef0238fc0162e9c1446602ce0dd41702d4dd7a94d2ce42d12b7f80baf7e
# Space separated sdkmanager package ids.
ARG ANDROID_PACKAGES="platform-tools platforms;android-36 build-tools;35.0.0"
ARG SONAR_SCANNER_VERSION=7.2.0.5079
ARG SONAR_SCANNER_SHA256=30d80b37c8f4be1254b6c43ec8c64291798d97a710c28475958b5e2f10809fe1

FROM ${JDK_IMAGE} AS jdk
# jmods are only needed by jlink, src.zip only by IDEs. Dropping them saves about 120 MB.
RUN rm -rf "$JAVA_HOME/jmods" "$JAVA_HOME/lib/src.zip" "$JAVA_HOME/man"

FROM ${JDK_IMAGE} AS downloader
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip \
 && rm -rf /var/lib/apt/lists/*

FROM downloader AS android-sdk
ARG CMDLINE_TOOLS_BUILD
ARG CMDLINE_TOOLS_SHA256
ARG ANDROID_PACKAGES
ENV ANDROID_HOME=/opt/android-sdk
# sdkmanager ignores the http(s)_proxy variables, so translate a build-time https_proxy into its flags.
# The SDK is left writable by any uid so AGP can install packages a project needs beyond the defaults.
RUN set -eu; \
    proxy_flags=""; \
    if [ -n "${https_proxy:-}" ]; then \
      proxy_address="${https_proxy#*://}"; proxy_address="${proxy_address##*@}"; proxy_address="${proxy_address%%/*}"; \
      proxy_flags="--proxy=http --proxy_host=${proxy_address%:*} --proxy_port=${proxy_address##*:}"; \
    fi; \
    curl -fsSL -o /tmp/cmdline-tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip"; \
    echo "${CMDLINE_TOOLS_SHA256}  /tmp/cmdline-tools.zip" | sha256sum -c -; \
    unzip -q /tmp/cmdline-tools.zip -d /tmp; \
    mkdir -p "$ANDROID_HOME/cmdline-tools"; \
    mv /tmp/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"; \
    sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"; \
    yes | "$sdkmanager" $proxy_flags --licenses > /dev/null; \
    "$sdkmanager" $proxy_flags $ANDROID_PACKAGES; \
    rm -rf /tmp/cmdline-tools.zip "$ANDROID_HOME/.temp"; \
    chmod -R a+rwX "$ANDROID_HOME"

FROM downloader AS sonar-scanner
ARG SONAR_SCANNER_VERSION
ARG SONAR_SCANNER_SHA256
# The platform-neutral zip has no bundled JRE; it runs on the image JDK.
RUN set -eu; \
    curl -fsSL -o /tmp/sonar-scanner.zip \
      "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip"; \
    echo "${SONAR_SCANNER_SHA256}  /tmp/sonar-scanner.zip" | sha256sum -c -; \
    unzip -q /tmp/sonar-scanner.zip -d /tmp; \
    mv "/tmp/sonar-scanner-${SONAR_SCANNER_VERSION}" /opt/sonar-scanner

FROM ubuntu:${UBUNTU_VERSION}
ARG CMDLINE_TOOLS_BUILD
ARG ANDROID_PACKAGES
ARG SONAR_SCANNER_VERSION

# git: Sonar SCM blame and new-code detection. fontconfig: AWT/font lookups in JVM tests.
# libnss-wrapper: passwd entry for arbitrary uids, see entrypoint.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl fontconfig git libnss-wrapper tzdata unzip \
 && rm -rf /var/lib/apt/lists/*

COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
COPY --from=android-sdk /opt/android-sdk /opt/android-sdk
COPY --from=sonar-scanner /opt/sonar-scanner /opt/sonar-scanner

# A fixed, world-writable HOME lets the container run as the CI agent's uid (docker run --user),
# which has no passwd entry, while Gradle, Android and Sonar still have somewhere to write.
# COPY creates /opt/android-sdk itself as 755, so reopen it for AGP's package installs.
RUN mkdir -p /home/ci /workspace \
 && chmod 1777 /home/ci /workspace \
 && chmod a+rwx /opt/android-sdk

# The *_USER_HOME defaults keep caches under HOME even when a CI runner replaces the entrypoint.
ENV LANG=C.UTF-8 \
    HOME=/home/ci \
    GRADLE_USER_HOME=/home/ci/.gradle \
    ANDROID_USER_HOME=/home/ci/.android \
    SONAR_USER_HOME=/home/ci/.sonar \
    JAVA_HOME=/opt/java/openjdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:/opt/sonar-scanner/bin:$PATH"

LABEL org.opencontainers.image.title="android-ci" \
      org.opencontainers.image.description="JDK 17, Android SDK and SonarScanner CLI for Android CI" \
      android.cmdline-tools.build="${CMDLINE_TOOLS_BUILD}" \
      android.sdk.packages="${ANDROID_PACKAGES}" \
      sonar.scanner.version="${SONAR_SCANNER_VERSION}"

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
