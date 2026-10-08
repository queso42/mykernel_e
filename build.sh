
# Download the official Linux source tarball
VERSION="${linux_version#v}"

# Find the kernel archive series, e.g. 6.12.10 -> 6.12
if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?$ ]]; then
    SERIES="${BASH_REMATCH[1]}"
else
    echo "Invalid Linux release version: $VERSION" >&2
    exit 1
fi

TARBALL="linux-${VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${SERIES}.x/${TARBALL}"

WORK="$ROOT/linux-src"
mkdir -p "$WORK"

curl --fail --location --retry 3 \
    "$URL" -o "$ROOT/$TARBALL"

# Extract into the working directory
tar -xJf "$ROOT/$TARBALL" \
    -C "$WORK" --strip-components=1

# Apply the distro's kernel configuration
cp "$ROOT/linconf" "$WORK/.config"

make -C "$WORK" \
    ARCH="$arch" \
    CROSS_COMPILE="${toolarch}-linux-gnu-" \
    olddefconfig

make -C "$WORK" \
    ARCH="$arch" \
    CROSS_COMPILE="${toolarch}-linux-gnu-" \
    -j"$(nproc)" vmlinux modules
