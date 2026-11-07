/// Shell prologue the setup runs share.
const termuxSetupBaseScript = r'''set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if command -v proot-distro >/dev/null 2>&1 &&
   proot-distro login opencode-ubuntu -- /bin/true >/dev/null 2>&1; then exit 0; fi
apt-get update
apt-get -y --no-remove -o Dpkg::Options::="--force-confold" --fix-broken install
apt-get -y --no-remove -o Dpkg::Options::="--force-confold" install proot-distro curl openssl
case "$(uname -m)" in
  aarch64|arm64) arch=arm64; sha=5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd ;;
  arm|armv7l|armv8l) arch=armhf; sha=a40848e9c4ed72c22bdcb6a7bc9832e1ca8a30e5a3e2a0543dc56ed14e2e38b7 ;;
  x86_64|amd64) arch=amd64; sha=a496a960472ce474a59590b8987d3a1135d3cbef1991f3b1abe8cacfea8bf85a ;;
  *) exit 64 ;;
esac
mkdir -p "$HOME/.oc/setup-v2"
archive="$HOME/.oc/setup-v2/ubuntu-base.tar.gz"
root="$PREFIX/var/lib/proot-distro/installed-rootfs/opencode-ubuntu"
# Never erase an existing container, including one from an interrupted setup.
# A damaged extraction needs explicit recovery rather than risking projects.
[ ! -d "$root" ] &&
  [ ! -d "$PREFIX/var/lib/proot-distro/containers/opencode-ubuntu/rootfs" ] || exit 65
curl --fail --location --retry 5 --connect-timeout 20 \
  "https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04.1-base-$arch.tar.gz" -o "$archive"
printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
proot-distro install "$archive" --name opencode-ubuntu
proot-distro login opencode-ubuntu -- /bin/true
rm -f "$archive"
''';
