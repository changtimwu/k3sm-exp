#!/bin/sh
# Bundle Homebrew's llama-server and every non-system dylib it needs into ./ctx,
# relocatable via @rpath, so it can run inside a k3sm pod (the pod sandbox
# denies all reads under /opt, so /opt/homebrew paths cannot be used directly).
#
#   ctx/bin/llama-server
#   ctx/bin/libggml-*.so      ggml backends (Metal/CPU/BLAS); ggml searches the exe dir
#   ctx/lib/*.dylib           llama, ggml, openssl, ...
#
# Usage: ./bundle.sh && k3sm build -t llama-server:<version> .
set -eu

cd "$(dirname "$0")"
LLAMA="$(brew --prefix llama.cpp)"
GGML="$(brew --prefix ggml)"

rm -rf ctx
mkdir -p ctx/bin ctx/lib
cp "$LLAMA/bin/llama-server" ctx/bin/
cp "$GGML"/libexec/libggml-*.so ctx/bin/

# Copy non-system dependencies (recursively) into ctx/lib, resolving @rpath
# against the Homebrew lib dirs.
resolve() {
	case "$1" in
	@rpath/*)
		for d in "$LLAMA/lib" "$GGML/lib"; do
			[ -e "$d/${1#@rpath/}" ] && { echo "$d/${1#@rpath/}"; return; }
		done
		echo "unresolved: $1" >&2; exit 1 ;;
	*) echo "$1" ;;
	esac
}
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^(@rpath|/opt/homebrew)/' || true; }

queue="ctx/bin/llama-server $(ls ctx/bin/*.so)"
while [ -n "$queue" ]; do
	set -- $queue; f="$1"; shift; queue="$*"
	for dep in $(deps "$f"); do
		name="$(basename "$dep")"
		[ -e "ctx/lib/$name" ] && continue
		cp "$(resolve "$dep")" "ctx/lib/$name"
		chmod u+w "ctx/lib/$name"
		queue="$queue ctx/lib/$name"
	done
done

# Rewrite every /opt/homebrew reference to @rpath/<name> and point rpaths at ../lib.
for f in ctx/bin/* ctx/lib/*; do
	chmod u+w "$f"
	case "$f" in ctx/lib/*) install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null ;; esac
	for dep in $(deps "$f"); do
		case "$dep" in /opt/homebrew/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null ;; esac
	done
	otool -l "$f" | grep -A2 LC_RPATH | awk '/ path /{print $2}' | while read -r rp; do
		install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
	done
	case "$f" in
	ctx/bin/*) install_name_tool -add_rpath @loader_path/../lib "$f" 2>/dev/null ;;
	ctx/lib/*) install_name_tool -add_rpath @loader_path "$f" 2>/dev/null ;;
	esac
	codesign --force --sign - "$f" 2>/dev/null
done

echo "bundled into ctx/:"
ls -l ctx/bin ctx/lib
# Fail if any load command still points into /opt (unreadable from a pod).
for f in ctx/bin/* ctx/lib/*; do
	if otool -L "$f" | tail -n +2 | grep -q /opt/; then echo "still references /opt: $f" >&2; exit 1; fi
done
