#!/bin/sh
# Containers run with `docker run --user <agent uid>` have no passwd entry, so Java resolves
# user.home to "?" regardless of $HOME. nss_wrapper serves a passwd entry for the current uid
# without making /etc/passwd writable; LD_PRELOAD carries it into every child process.
set -eu

if ! getent passwd "$(id -u)" > /dev/null 2>&1; then
  NSS_WRAPPER_PASSWD="$(mktemp)"
  cat /etc/passwd > "$NSS_WRAPPER_PASSWD"
  echo "ci:x:$(id -u):$(id -g):CI user:${HOME}:/bin/bash" >> "$NSS_WRAPPER_PASSWD"
  NSS_WRAPPER_GROUP=/etc/group
  LD_PRELOAD="libnss_wrapper.so${LD_PRELOAD:+ $LD_PRELOAD}"
  export NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP LD_PRELOAD
fi

exec "$@"
