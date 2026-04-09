#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash pipeline/scp_download_bioproject_results.sh <EC2_IP>
#
# Example:
#   bash pipeline/scp_download_bioproject_results.sh 3.218.152.149

EC2_IP="${1:-}"
if [[ -z "${EC2_IP}" ]]; then
  echo "Usage: $0 <EC2_IP>"
  exit 1
fi

KEY_PATH="/Users/victorboddy/aws-crops/MyFirstKeyPair.pem"
REMOTE_USER="ubuntu"
LOCAL_ROOT="/Users/victorboddy/aws-crops"
REMOTE_ROOT="/data"

# Edit this list as needed
BIOPROJECTS=(
  "PRJEB42339"
  "PRJNA1205709"
  "PRJNA1180576"
  "PRJNA783767"
)

ssh_base=(ssh -o StrictHostKeyChecking=no -i "${KEY_PATH}" "${REMOTE_USER}@${EC2_IP}")

sync_project_outputs() {
  local project="$1"
  local local_root="$2"
  local project_local="${local_root}/${project}"
  local remote_project="${REMOTE_USER}@${EC2_IP}:${REMOTE_ROOT}/${project}/"

  if ! "${ssh_base[@]}" "test -d '${REMOTE_ROOT}/${project}'"; then
    echo "  - missing project dir: ${REMOTE_ROOT}/${project}"
    return 0
  fi

  mkdir -p "${project_local}"

  # rsync is much faster than many scp calls for lots of small files.
  # It pulls only the bioinformatics outputs we care about and excludes raw sequencing.
  rsync -a -z --prune-empty-dirs \
    -e "ssh -o StrictHostKeyChecking=no -i ${KEY_PATH}" \
    --include='*/' \
    --include='merged_xtree.csv' \
    --include='post_qc_config' \
    --include='qc_read_counts.tsv' \
    --include='*config*.tsv' \
    --include='*.cov' \
    --include='*.ref' \
    --include='*.perq' \
    --exclude='*.fastq' \
    --exclude='*.fq' \
    --exclude='*.fastq.gz' \
    --exclude='*.fq.gz' \
    --exclude='*.sra' \
    --exclude='fastq_out/' \
    --exclude='tmp/' \
    --exclude='tmp_*/' \
    --exclude='*' \
    "${remote_project}" \
    "${project_local}/"

  local cov_count
  cov_count=$(find "${project_local}" -type f -name '*.cov' 2>/dev/null | wc -l | tr -d ' ')

  if [[ -f "${project_local}/qc_read_counts.tsv" ]]; then
    echo "  ✓ copied project (qc_read_counts.tsv present, ${cov_count} .cov files)"
  else
    echo "  ✓ copied project (${cov_count} .cov files; qc_read_counts.tsv not found remotely)"
  fi
}

echo "Downloading BioProject outputs from ${REMOTE_USER}@${EC2_IP}:${REMOTE_ROOT}"

for p in "${BIOPROJECTS[@]}"; do
  echo
  echo "=== ${p} ==="

  sync_project_outputs "${p}" "${LOCAL_ROOT}"

done

echo
echo "Done. Local folders created/updated under: ${LOCAL_ROOT}"
