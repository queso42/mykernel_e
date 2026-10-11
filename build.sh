#!/usr/bin/env bash
set -euo pipefail

# Deterministic glob/sort order and messages.
export LC_ALL=C

# --------------------------------------------------
# Paths and configuration
# --------------------------------------------------

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/build.conf"

: "${arch:?Missing arch in build.conf}"
: "${tooltriplet:?Missing tooltriplet in build.conf}"
: "${kernel_target:?Missing kernel_target in build.conf}"
: "${linux_version:?Missing linux_version in build.conf}"
: "${kernel_files:?Missing kernel_files in build.conf}"

VERSION="${linux_version#v}"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
    echo "Invalid Linux release version: '$linux_version'" >&2
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"

BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x"
TARBALL="linux-${VERSION}.tar.xz"
URL="$BASE_URL/$TARBALL"
SUMS_URL="$BASE_URL/sha256sums.asc"

WORK="$ROOT/work"
KERNEL="$WORK/linux-$VERSION"   # pristine source (+ patches)
BUILD="$WORK/build"             # out-of-tree build output (O=)
ARCHIVE="$WORK/$TARBALL"
SUMS="$WORK/sha256sums.asc"
UPKERNEL="$ROOT/upkernel"
UPMODS="$ROOT/upmods"

CROSS_COMPILE="${tooltriplet}-"

export ARCH="$arch"
export CROSS_COMPILE

echo "======================================"
echo " Linux kernel CI build"
echo "======================================"
echo "Architecture : $ARCH"
echo "Toolchain    : $CROSS_COMPILE"
echo "Linux version: $VERSION"
echo "Source       : $URL"
echo "======================================"

# --------------------------------------------------
# Check build tools (installed by the workflow)
# --------------------------------------------------

missing=0
for tool in make bc bison flex patch curl xz zstd tar sha256sum depmod \
            "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}ld"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        missing=1
    fi
done
(( missing == 0 )) || exit 1

# --------------------------------------------------
# Download, verify and extract Linux source tarball
# --------------------------------------------------

rm -rf "$WORK"
mkdir -p "$WORK" "$BUILD"

echo "Downloading Linux source..."

curl --fail --location --retry 3 --retry-all-errors \
    "$URL" --output "$ARCHIVE"

curl --fail --location --retry 3 --retry-all-errors \
    "$SUMS_URL" --output "$SUMS"

echo "Verifying checksum..."

# Match the exact filename (second field) so e.g. 5.15.2 can't match 5.15.222.
expected="$(awk -v f="$TARBALL" '$2 == f { print $1; exit }' "$SUMS")"

if [[ -z "$expected" ]]; then
    echo "No checksum found for $TARBALL in sha256sums.asc" >&2
    exit 1
fi

echo "$expected  $ARCHIVE" | sha256sum --check --strict -

echo "Extracting Linux source..."

mkdir -p "$KERNEL"

tar -xJf "$ARCHIVE" \
    -C "$KERNEL" \
    --strip-components=1

# --------------------------------------------------
# Apply optional distro patches
# --------------------------------------------------

if [[ -d "$ROOT/patches" ]]; then
    shopt -s nullglob
    PATCHES=("$ROOT"/patches/*.patch)
    shopt -u nullglob

    for patchfile in "${PATCHES[@]}"; do
        echo "Applying patch: ${patchfile##*/}"

        # Fresh tree every run, so no --forward: a patch that does not
        # apply cleanly is a real error and must fail the build.
        patch --batch -d "$KERNEL" -p1 < "$patchfile"
    done
fi

# --------------------------------------------------
# Configure kernel
# --------------------------------------------------

if [[ ! -f "$ROOT/linconf" ]]; then
    echo "Missing kernel configuration: $ROOT/linconf" >&2
    exit 1
fi

KMAKE=(make -C "$KERNEL" O="$BUILD" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE")

echo "Installing kernel configuration..."

cp "$ROOT/linconf" "$BUILD/.config"

echo "Resolving kernel configuration..."

"${KMAKE[@]}" olddefconfig

if grep -q '^CONFIG_MODULES=y' "$BUILD/.config"; then
    HAVE_MODULES=1
else
    HAVE_MODULES=0
    echo "NOTE: CONFIG_MODULES is not enabled; skipping modules."
fi

# --------------------------------------------------
# Compile kernel (and modules if enabled)
# --------------------------------------------------

echo "Building kernel..."

TARGETS=("$kernel_target")
(( HAVE_MODULES )) && TARGETS+=(modules)

"${KMAKE[@]}" -j"$(nproc)" "${TARGETS[@]}"

# --------------------------------------------------
# Stage kernel artifacts
# --------------------------------------------------

echo "Preparing artifact directories..."

rm -rf "$UPKERNEL" "$UPMODS"
mkdir -p "$UPKERNEL" "$UPMODS"

echo "Copying configured kernel files..."

# kernel_files is whitespace/newline separated; disable globbing so
# entries are never expanded against the current directory.
set -f
# shellcheck disable=SC2206
FILES=($kernel_files)
set +f

for file in "${FILES[@]}"; do
    # Reject absolute paths and parent-directory traversal.
    case "$file" in
        /*|..|../*|*/../*|*/..)
            echo "Invalid kernel artifact path: $file" >&2
            exit 1
            ;;
    esac

    # Paths are relative to the build output directory (O=).
    if [[ ! -f "$BUILD/$file" ]]; then
        echo "Kernel artifact not found: $file" >&2
        echo "Check kernel_files in build.conf." >&2
        exit 1
    fi

    ( cd "$BUILD" && cp --parents -- "$file" "$UPKERNEL" )
done

# --------------------------------------------------
# Stage kernel modules separately
# --------------------------------------------------

if (( HAVE_MODULES )); then
    echo "Installing kernel modules into upmods/..."

    "${KMAKE[@]}" \
        INSTALL_MOD_PATH="$UPMODS" \
        INSTALL_MOD_STRIP=1 \
        modules_install

    # modules_install leaves absolute build/ and source/ symlinks pointing
    # at the CI work tree. They are useless off this runner, and archiving
    # tools follow them, pulling in the whole kernel source and build tree.
    find "$UPMODS/lib/modules" -mindepth 2 -maxdepth 2 -type l \
        \( -name build -o -name source \) -print -delete
fi

# --------------------------------------------------
# Verify artifact outputs
# --------------------------------------------------

if [[ -z "$(find "$UPKERNEL" -type f -print -quit)" ]]; then
    echo "ERROR: upkernel/ contains no files." >&2
    exit 1
fi

if (( HAVE_MODULES )) && [[ -z "$(find "$UPMODS" -type f -print -quit)" ]]; then
    echo "ERROR: CONFIG_MODULES=y but upmods/ contains no files." >&2
    exit 1
fi

echo
echo "======================================"
echo " BUILD SUCCESSFUL"
echo "======================================"

echo
echo "Kernel artifacts:"
find "$UPKERNEL" -type f -printf '%P\n'

echo
echo "Module artifacts:"
find "$UPMODS" -type f -printf '%P\n'

echo
echo "Artifacts are ready for GitHub Actions."
