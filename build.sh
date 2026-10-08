
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/build.conf"

# Fail early if required configuration is missing.
: "${arch:?Missing arch in build.conf}"
: "${toolarch:?Missing toolarch in build.conf}"
: "${linux_version:?Missing linux_version in build.conf}"
: "${kernel_files:?Missing kernel_files in build.conf}"

# This script downloads full major.minor release tarballs.
if [[ ! "$linux_version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    echo "Invalid Linux release version: '$linux_version'" >&2
    echo "Use a full-release version such as 6.12." >&2
    exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
VERSION="$linux_version"

KERNEL="$ROOT/work/linux-$VERSION"
TARBALL="$ROOT/linux-$VERSION.tar.xz"
UPKERNEL="$ROOT/upkernel"
UPMODS="$ROOT/upmods"

URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${VERSION}.tar.xz"

echo "Architecture: $arch"
echo "Toolchain:    ${toolarch}-linux-gnu-"
echo "Linux:        $VERSION"
echo "Source URL:   $URL"

# Install the cross-compiler selected by toolarch.
sudo apt-get update
sudo apt-get install -y \
    "gcc-${toolarch}-linux-gnu" \
    "binutils-${toolarch}-linux-gnu" \
    build-essential bc bison flex patch \
    libssl-dev libelf-dev libncurses-dev \
    xz-utils curl ca-certificates kmod

export ARCH="$arch"
export CROSS_COMPILE="${toolarch}-linux-gnu-"

# Download and extract a clean source tree.
mkdir -p "$ROOT/work"
rm -rf "$KERNEL"

curl --fail --location --retry 3 \
    "$URL" -o "$TARBALL"

mkdir -p "$KERNEL"
tar -xJf "$TARBALL" \
    -C "$KERNEL" --strip-components=1

# Apply optional distro patches in lexical order.
if [[ -d "$ROOT/patches" ]]; then
    for patchfile in "$ROOT"/patches/*.patch; do
        [[ -f "$patchfile" ]] || continue

        echo "Applying ${patchfile##*/}"
        patch --batch -d "$KERNEL" -p1 < "$patchfile"
    done
fi

# Install the distro kernel configuration.
cp "$ROOT/linconf" "$KERNEL/.config"

make -C "$KERNEL" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    olddefconfig

# Compile the kernel and modules.
make -C "$KERNEL" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$(nproc)" \
    vmlinux modules

# Recreate artifact staging directories.
rm -rf "$UPKERNEL" "$UPMODS"
mkdir -p "$UPKERNEL" "$UPMODS"

# Copy configured kernel files, preserving their relative paths.
while IFS= read -r file || [[ -n "$file" ]]; do
    # Trim leading and trailing whitespace.
    file="${file#"${file%%[![:space:]]*}"}"
    file="${file%"${file##*[![:space:]]}"}"

    # Ignore blank lines and comments.
    [[ -z "$file" || "$file" == \#* ]] && continue

    # Only accept paths relative to the source tree.
    if [[ "$file" == /* || "$file" == .. || "$file" == ../* || "$file" == */../* ]]; then
        echo "Invalid kernel file path: $file" >&2
        exit 1
    fi

    if [[ ! -f "$KERNEL/$file" ]]; then
        echo "Configured kernel file not found: $file" >&2
        exit 1
    fi

    (
        cd "$KERNEL"
        cp --parents -- "$file" "$UPKERNEL"
    )
done <<< "$kernel_files"

# Install kernel modules separately.
make -C "$KERNEL" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$UPMODS" \
    modules_install

# Fail if the selected kernel artifact list produced nothing.
if [[ -z "$(find "$UPKERNEL" -type f -print -quit)" ]]; then
    echo "No kernel artifacts were staged." >&2
    exit 1
fi

echo "Build succeeded."
echo "Kernel artifacts: $UPKERNEL"
echo "Module artifacts: $UPMODS"
find "$UPKERNEL" "$UPMODS" -type f
