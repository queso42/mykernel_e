#!/usr/bin/env bash
#if this looks like slop, forgive me for using got
set -Eeuo pipefail

# --------------------------------------------------
# Paths and configuration
# --------------------------------------------------

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/build.conf"

: "${arch:?Missing arch in build.conf}"
: "${toolarch:?Missing toolarch in build.conf}"
: "${linux_version:?Missing linux_version in build.conf}"
: "${kernel_files:?Missing kernel_files in build.conf}"

VERSION="${linux_version#v}"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
    echo "Invalid Linux release version: '$linux_version'" >&2
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"

# Kernel.org keeps major/minor and stable patch tarballs
# together under the relevant major-version directory.
TARBALL="linux-${VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"

WORK="$ROOT/work"
KERNEL="$WORK/linux-$VERSION"
ARCHIVE="$WORK/$TARBALL"
UPKERNEL="$ROOT/upkernel"
UPMODS="$ROOT/upmods"

CROSS_COMPILE="${toolarch}-linux-gnu-"

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
# Dependencies
# --------------------------------------------------

sudo apt-get update

sudo apt-get install -y \
    build-essential \
    "gcc-${toolarch}-linux-gnu" \
    "binutils-${toolarch}-linux-gnu" \
    bc bison flex patch \
    libssl-dev libelf-dev libncurses-dev \
    xz-utils curl ca-certificates kmod

# --------------------------------------------------
# Download and extract Linux source tarball
# --------------------------------------------------

mkdir -p "$WORK"

echo "Downloading Linux source..."

curl --fail --location --retry 3 \
    "$URL" \
    --output "$ARCHIVE"

echo "Extracting Linux source..."

rm -rf "$KERNEL"
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

    for patchfile in "${PATCHES[@]}"; do
        echo "Applying patch: ${patchfile##*/}"

        patch --batch --forward \
            -d "$KERNEL" \
            -p1 < "$patchfile"
    done

    shopt -u nullglob
fi

# --------------------------------------------------
# Configure kernel
# --------------------------------------------------

if [[ ! -f "$ROOT/linconf" ]]; then
    echo "Missing kernel configuration: $ROOT/linconf" >&2
    exit 1
fi

echo "Installing kernel configuration..."

cp "$ROOT/linconf" "$KERNEL/.config"

echo "Resolving kernel configuration..."

make -C "$KERNEL" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    olddefconfig

# --------------------------------------------------
# Compile kernel and modules
# --------------------------------------------------

echo "Building kernel and modules..."

make -C "$KERNEL" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$(nproc)" \
    vmlinuz modules

# --------------------------------------------------
# Stage kernel artifacts
# --------------------------------------------------

echo "Preparing artifact directories..."

rm -rf "$UPKERNEL" "$UPMODS"

mkdir -p "$UPKERNEL" "$UPMODS"

echo "Copying configured kernel files..."

while IFS= read -r file || [[ -n "$file" ]]; do
    # Trim surrounding whitespace.
    file="${file#"${file%%[![:space:]]*}"}"
    file="${file%"${file##*[![:space:]]}"}"

    # Skip empty lines and comments.
    [[ -z "$file" || "$file" == \#* ]] && continue

    # Reject absolute paths and parent-directory traversal.
    case "$file" in
        /*|..|../*|*/../*|*/..)
            echo "Invalid kernel artifact path: $file" >&2
            exit 1
            ;;
    esac

    if [[ ! -f "$KERNEL/$file" ]]; then
        echo "Kernel artifact not found: $file" >&2
        echo "Check kernel_files in build.conf." >&2
        exit 1
    fi

    (
        cd "$KERNEL"
        cp --parents -- "$file" "$UPKERNEL"
    )
done <<< "$kernel_files"

# --------------------------------------------------
# Stage kernel modules separately
# --------------------------------------------------

echo "Installing kernel modules into upmods/..."

make -C "$KERNEL" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$UPMODS" \
    modules_install

# --------------------------------------------------
# Verify artifact outputs
# --------------------------------------------------

if [[ -z "$(find "$UPKERNEL" -type f -print -quit)" ]]; then
    echo "ERROR: upkernel/ contains no files." >&2
    exit 1
fi

if [[ -z "$(find "$UPMODS" -type f -print -quit)" ]]; then
    echo "ERROR: upmods/ contains no files." >&2
    echo "Check whether your kernel configuration builds modules." >&2
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

