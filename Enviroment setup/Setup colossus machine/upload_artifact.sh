#!/bin/bash


export USER="jjang"
export TOKEN="cmVmdGtuOjAxOjE4MTcwMzYwNjg6eEI4VzRFOGg2anI4OTM3cmJ4UzBQdE9NMFJK"



export LOCAL_F1="/root/remote_fs/scratch/gpu_test_package/4.0.2/fn10x/rnlit1/"
export F1="manifest.json"

SRC="${LOCAL_F1%/}/${F1}"
DEST="https://artifactory.nvidia.com/artifactory/sw-systemsim-generic-local/rf/gpu-fmodel/4.0.2/fn10x/rnlit1/${F1}"

# -T must point at the FILE, not its directory: passing the directory uploads
# a zero-byte object that Artifactory still accepts (size 0, sha256 e3b0c442…).
[ -f "$SRC" ] || { echo "ERROR: source file not found: $SRC" >&2; exit 1; }
[ -s "$SRC" ] || { echo "ERROR: source file is empty: $SRC" >&2; exit 1; }

# Let Artifactory verify the upload server-side, so a truncated/empty PUT is
# rejected instead of silently stored.
SHA256=$(sha256sum "$SRC" | cut -d' ' -f1)
echo "uploading $SRC ($(stat -c%s "$SRC") bytes, sha256=${SHA256})"

curl -u "${USER}:${TOKEN}" -j -L --fail-with-body \
     -H "X-Checksum-Sha256: ${SHA256}" \
     -T "$SRC" "$DEST" | cat
