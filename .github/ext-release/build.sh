#!/bin/sh
# Builds `<out>/crystal-<profile>.tar.gz` from the checked-out sources.
#
# Profiles:
#
#   darwin-arm64-system-static  macOS with Homebrew. LLVM, bdw-gc, pcre2,
#                               libyaml and zstd are linked statically, so the
#                               binaries only depend on macOS system libraries.
#   linux-amd64-musl-static     Fully static binaries, built in the
#   linux-arm64-musl-static     crystallang/crystal Alpine image. The compiler
#                               targets `<arch>-unknown-linux-gnu` and has no
#                               interpreter, which needs `dlopen`.
#
# The archive holds `bin/crystal`, `bin/shards`, the standard library in
# `share/crystal/src` and shell completions. The compiler finds the standard
# library relative to its own path, so the archive can be unpacked anywhere.
#
# Usage: build.sh <profile> [<out>]
set -eu

profile=$1
out=$(mkdir -p "${2:-dist}" && cd "${2:-dist}" && pwd)
shards_version=${SHARDS_VERSION:-v0.20.0}

root=$(pwd)
work="${RUNNER_TEMP:-$root/.build}/ext-release/$profile"
stage="$work/crystal-$profile"

rm -rf "$work"
mkdir -p "$stage"

git clone --quiet --depth 1 --branch "$shards_version" https://github.com/crystal-lang/shards.git "$work/shards"

case "$profile" in
darwin-arm64-system-static)
  # On a developer machine these are expected to be installed already.
  if [ -n "${CI:-}" ]; then
    brew install --quiet llvm bdw-gc pcre2 libyaml zstd pkgconf
  fi

  LLVM_CONFIG="$(brew --prefix llvm)/bin/llvm-config"
  export LLVM_CONFIG

  # The linker takes the first `lib<name>.a` or `lib<name>.dylib` it finds on
  # the search path. A directory holding only the archives, searched first with
  # `-search_paths_first`, makes it pick the static libraries.
  static="$work/static-libs"
  mkdir -p "$static"
  ln -s "$(brew --prefix bdw-gc)/lib/libgc.a" \
    "$(brew --prefix pcre2)/lib/libpcre2-8.a" \
    "$(brew --prefix libyaml)/lib/libyaml.a" \
    "$(brew --prefix zstd)/lib/libzstd.a" \
    "$static/"
  link_flags="-L$static -Wl,-search_paths_first -Wl,-dead_strip_dylibs -fuse-ld=/usr/bin/ld"

  # LLVM's component archives instead of `libLLVM.dylib`. Homebrew's LLVM lists
  # Z3 as a system library; Crystal doesn't use the Z3 solver, so drop it.
  LLVM_LDFLAGS=$("$LLVM_CONFIG" --link-static --libs --system-libs --ldflags | tr ' ' '\n' | grep -v libz3 | tr '\n' ' ')
  export LLVM_LDFLAGS

  make crystal release=1 interpreter=1 FLAGS=--no-debug LDFLAGS="$link_flags"
  make install_compiler install_completions DESTDIR="$stage" PREFIX=

  (
    cd "$work/shards"
    shards install --production --skip-postinstall --skip-executables
    "$stage/bin/crystal" build src/shards.cr -o bin/shards --release --no-debug --link-flags="$link_flags"
  )
  install -m 0755 "$work/shards/bin/shards" "$stage/bin/shards"

  # Only macOS system libraries may remain.
  foreign=$(otool -L "$stage/bin/crystal" "$stage/bin/shards" | grep -v ':$' | grep -vE '^\s+/(usr/lib|System)/' || true)
  if [ -n "$foreign" ]; then
    echo "Non-system libraries linked:" >&2
    echo "$foreign" >&2
    exit 1
  fi

  CRYSTAL_LIBRARY_PATH="$(brew --prefix)/lib" "$stage/bin/crystal" eval 'puts "compiled with #{Crystal::VERSION}"'
  echo 'puts "interpreted with #{Crystal::VERSION}"' >"$work/interpreted.cr"
  CRYSTAL_LIBRARY_PATH="$(brew --prefix)/lib" "$stage/bin/crystal" i "$work/interpreted.cr"
  ;;

linux-amd64-musl-static | linux-arm64-musl-static)
  case "$profile" in
  linux-amd64-*) target=x86_64-unknown-linux-gnu ;;
  linux-arm64-*) target=aarch64-unknown-linux-gnu ;;
  esac

  apk add --no-cache git make g++ llvm22-dev llvm22-static libxml2-static xz-static \
    zlib-static zstd-static gc-dev gc-static pcre2-dev pcre2-static yaml-dev yaml-static

  export LLVM_CONFIG=/usr/lib/llvm22/bin/llvm-config

  # Without this the compiler would target musl, the libc it is built with.
  CRYSTAL_CONFIG_TARGET=$target make crystal release=1 static=1 FLAGS=--no-debug
  make install_compiler install_completions DESTDIR="$stage" PREFIX=

  # shards is an ordinary program, so the image's compiler builds it.
  (
    cd "$work/shards"
    shards install --production --skip-postinstall --skip-executables
    crystal build src/shards.cr -o bin/shards --release --no-debug --static
  )
  install -m 0755 "$work/shards/bin/shards" "$stage/bin/shards"

  # Static LLVM brings its debug information along.
  strip "$stage/bin/crystal" "$stage/bin/shards"

  # Static PIE binaries have a dynamic section, but no interpreter and no
  # shared libraries.
  for bin in "$stage/bin/crystal" "$stage/bin/shards"; do
    if readelf -l "$bin" | grep -q INTERP || readelf -d "$bin" | grep -q NEEDED; then
      echo "$bin is not statically linked" >&2
      exit 1
    fi
  done

  # The compiler swaps `-gnu` for `-musl` when it runs on musl, as here.
  "$stage/bin/crystal" --version | grep -q "^Default target: ${target%-gnu}-"

  echo 'puts "compiled with #{Crystal::VERSION}"' >"$work/compiled.cr"
  "$stage/bin/crystal" build "$work/compiled.cr" -o "$work/compiled"
  "$work/compiled"
  ;;

*)
  echo "Unknown profile: $profile" >&2
  exit 1
  ;;
esac

"$stage/bin/crystal" --version
"$stage/bin/shards" --version

# The compiler's default library path; the linker warns when it is missing.
mkdir -p "$stage/lib/crystal"

COPYFILE_DISABLE=1 tar -C "$work" -czf "$out/crystal-$profile.tar.gz" "crystal-$profile"
echo "Built $out/crystal-$profile.tar.gz"
