#!/usr/bin/env bash
# =============================================================================
# Batch 1 Taxonomy — Run MAGUS taxonomy on the 5 QC-complete BioProjects
# Instance: r6a.16xlarge (64 vCPU, 512 GB RAM)
#
# This script:
#   1. Activates the MAGUS conda environment
#   2. Pre-loads the 440 GB GTDB/XTree DB into RAM once
#   3. Runs magus taxonomy on the 5 successful BioProjects
#   4. Writes taxonomy outputs into /data/{BIOPROJECT}/taxonomy
# =============================================================================
set -euo pipefail

DATA_DIR="/data"
LOG_DIR="${DATA_DIR}/logs"
DB_PATH="${DATA_DIR}/gtdb_index/gtdbr226_29_comp2.xtr2"
THREADS=64
MAX_WORKERS=1

# Only the 5 projects that completed QC successfully
BIOPROJECTS=(
    "PRJNA484096"
    "PRJEB42339"
    "PRJNA1205709"
    "PRJNA1180576"
    "PRJNA783767"
)

mkdir -p "${LOG_DIR}"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "${LOG_DIR}/batch1_taxonomy.log"; }

die() { log "FATAL: $*"; exit 1; }

setup_env() {
    log "Setting up environment..."

    if [[ -f "${DATA_DIR}/.miniconda3/etc/profile.d/conda.sh" ]]; then
        source "${DATA_DIR}/.miniconda3/etc/profile.d/conda.sh"
    elif [[ -f "${DATA_DIR}/miniconda3/etc/profile.d/conda.sh" ]]; then
        source "${DATA_DIR}/miniconda3/etc/profile.d/conda.sh"
    else
        die "conda.sh not found under ${DATA_DIR}/.miniconda3 or ${DATA_DIR}/miniconda3"
    fi

    if conda env list | awk '{print $1}' | grep -qx "magus"; then
        conda activate magus
    else
        die "Conda environment 'magus' not found"
    fi

    export PATH="${DATA_DIR}/2FP_MAGUS/bin:${PATH}"

    command -v magus >/dev/null || die "magus not found on PATH"
    command -v shi7_trimmer >/dev/null || die "shi7_trimmer not found on PATH"
    command -v minigzip >/dev/null || die "minigzip not found on PATH"

    [[ -f "${DB_PATH}" ]] || die "XTREE DB not found: ${DB_PATH}"

    log "Environment ready ✓"
}

preload_db() {
    log "Pre-loading XTREE DB into RAM (this can take a while)..."
    cat "${DB_PATH}" > /dev/null
    log "DB pre-load complete ✓"
}

run_taxonomy() {
    local bioproject="$1"
    local projdir="${DATA_DIR}/${bioproject}"
    local config="${projdir}/post_qc_config"
    local output_dir="${projdir}/taxonomy"
    local summary_file="${output_dir}/merged_xtree.csv"

    [[ -d "${projdir}" ]] || { log "  ✗ SKIP: missing project dir ${projdir}"; return 1; }
    [[ -f "${config}" ]] || { log "  ✗ SKIP: missing QC config ${config}"; return 1; }

    local n_samples
    n_samples=$(tail -n +2 "${config}" | wc -l | tr -d ' ')
    if [[ "${n_samples}" -eq 0 ]]; then
        log "  ✗ SKIP: ${bioproject} has no QC samples in ${config}"
        return 1
    fi

    if [[ -f "${summary_file}" ]]; then
        log "  ✓ SKIP: taxonomy already exists at ${summary_file}"
        return 0
    fi

    mkdir -p "${output_dir}"

    log "  Running taxonomy on ${n_samples} samples"
    log "  Config: ${config}"
    log "  Output: ${output_dir}"

    magus taxonomy \
        --config "${config}" \
        --output "${output_dir}" \
        --db "${DB_PATH}" \
        --threads "${THREADS}" \
        --max-workers "${MAX_WORKERS}" \
        2>&1 | tee -a "${LOG_DIR}/taxonomy_${bioproject}.log"

    if [[ -f "${summary_file}" ]]; then
        log "  ✓ Taxonomy complete for ${bioproject}"
    else
        log "  ✗ Taxonomy may have failed — missing ${summary_file}"
        return 1
    fi
}

main() {
    log "═══════════════════════════════════════════════════════════════"
    log "  Batch 1 Taxonomy — 5 BioProjects on r6a.16xlarge"
    log "═══════════════════════════════════════════════════════════════"

    setup_env
    preload_db

    local total=${#BIOPROJECTS[@]}
    local current=0
    local passed=0
    local failed=0

    for bioproject in "${BIOPROJECTS[@]}"; do
        current=$((current + 1))
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "[${current}/${total}] Taxonomy: ${bioproject}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if run_taxonomy "${bioproject}"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "  TAXONOMY SUMMARY: ${passed} passed, ${failed} failed (${total} total)"
    log "═══════════════════════════════════════════════════════════════"

    if [[ "${failed}" -gt 0 ]]; then
        log "  ⚠ Check logs in ${LOG_DIR}/taxonomy_*.log for failures"
    else
        log "  ✓ All taxonomy jobs complete!"
    fi
}

main "$@"
