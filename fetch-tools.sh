#!/bin/zsh
# Downloads the command-line engines MacRAR bundles, from their official sources, into tools/.
#   rar / unrar / default.sfx / rarfiles.lst  → https://www.rarlab.com   (RAR for macOS, arm64)
#   7zz                                        → https://www.7-zip.org   (7-Zip for macOS, universal)
set -e
cd "$(dirname "$0")"
RAR_VERSION="${RAR_VERSION:-723}"          # RAR 7.23
SEVENZIP_VERSION="${SEVENZIP_VERSION:-2604}" # 7-Zip 26.04
ARCH="${RAR_ARCH:-arm}"                    # arm (Apple Silicon) or x64 (Intel)
RAR_SHA256="${RAR_SHA256:-}"
SEVENZIP_SHA256="${SEVENZIP_SHA256:-}"
if [[ "$RAR_VERSION" == 723 && "$ARCH" == arm && -z "$RAR_SHA256" ]]; then
  RAR_SHA256=68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d
fi
if [[ "$SEVENZIP_VERSION" == 2604 && -z "$SEVENZIP_SHA256" ]]; then
  SEVENZIP_SHA256=bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578
fi
[[ -n "$RAR_SHA256" && -n "$SEVENZIP_SHA256" ]] || { echo 'Custom engine versions/architectures require RAR_SHA256 and SEVENZIP_SHA256.'; exit 1; }
verify_download() {
  local digest=$(shasum -a 256 "$1")
  [[ "${digest%% *}" == "$2" ]] || { echo "Checksum mismatch: $1"; exit 1; }
}

mkdir -p tools && cd tools
echo "▸ Downloading RAR ${RAR_VERSION} for macOS (${ARCH})"
curl -fL -o rar.tar.gz "https://www.rarlab.com/rar/rarmacos-${ARCH}-${RAR_VERSION}.tar.gz"
verify_download rar.tar.gz "$RAR_SHA256"
rm -rf _rar && mkdir -p _rar
tar -xzf rar.tar.gz -C _rar
cp _rar/rar/rar _rar/rar/unrar _rar/rar/default.sfx _rar/rar/rarfiles.lst .
cp _rar/rar/license.txt rar-license.txt
rm -rf _rar rar.tar.gz

echo "▸ Downloading 7-Zip ${SEVENZIP_VERSION} for macOS"
curl -fL -o 7z.tar.xz "https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION:0:2}.${SEVENZIP_VERSION:2:2}/7z${SEVENZIP_VERSION}-mac.tar.xz"
verify_download 7z.tar.xz "$SEVENZIP_SHA256"
rm -rf _7z && mkdir -p _7z
tar -xJf 7z.tar.xz -C _7z
cp _7z/7zz .
cp _7z/License.txt 7zip-license.txt
rm -rf _7z 7z.tar.xz

chmod +x rar unrar default.sfx 7zz
xattr -c rar unrar default.sfx 7zz 2>/dev/null || true
echo "✔ Tools ready in $(pwd):"; ls -1
