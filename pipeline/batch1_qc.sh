#!/usr/bin/env bash
# =============================================================================
# Batch 1 QC — Run MAGUS QC on all 7 BioProjects
# Instance: r6a.16xlarge (64 vCPU, 512 GB RAM)
# =============================================================================
set -euo pipefail

DATA_DIR="/data"
LOG_DIR="${DATA_DIR}/logs"
mkdir -p "${LOG_DIR}"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "${LOG_DIR}/batch1_qc.log"; }

# ── Setup environment ────────────────────────────────────────────────────────
setup_env() {
    log "Setting up environment..."

    # Conda (check both hidden and non-hidden paths)
    if [[ -f "${DATA_DIR}/.miniconda3/etc/profile.d/conda.sh" ]]; then
        source "${DATA_DIR}/.miniconda3/etc/profile.d/conda.sh"
    elif [[ -f "${DATA_DIR}/miniconda3/etc/profile.d/conda.sh" ]]; then
        source "${DATA_DIR}/miniconda3/etc/profile.d/conda.sh"
        conda activate magus
        log "Conda env: magus activated"
    else
        log "WARNING: miniconda3 not found, assuming magus is already on PATH"
    fi

    # MAGUS binaries
    export PATH="${DATA_DIR}/2FP_MAGUS/bin:${PATH}"

    # Verify tools
    command -v shi7_trimmer &>/dev/null || { log "FATAL: shi7_trimmer not found"; exit 1; }
    command -v minigzip     &>/dev/null || { log "FATAL: minigzip not found"; exit 1; }
    command -v magus        &>/dev/null || { log "FATAL: magus not found"; exit 1; }
    log "All tools verified ✓"
}

# ── Run QC for a single bioproject ───────────────────────────────────────────
run_qc() {
    local bioproject="$1"
    local projdir="${DATA_DIR}/${bioproject}"
    local config="${projdir}/${bioproject}_config.tsv"
    local qc_out="${projdir}/qc"

    if [[ ! -f "${config}" ]]; then
        log "  ✗ SKIP: Config not found: ${config}"
        return 1
    fi

    # Count samples
    local n_samples
    n_samples=$(tail -n +2 "${config}" | wc -l | tr -d ' ')

    # Check if QC already done (post_qc_config exists and has all samples)
    local post_qc="${projdir}/post_qc_config"
    if [[ -f "${post_qc}" ]]; then
        local done_count
        done_count=$(tail -n +2 "${post_qc}" | wc -l | tr -d ' ')
        if [[ "${done_count}" -ge "${n_samples}" ]]; then
            log "  ✓ SKIP: QC already complete (${done_count}/${n_samples} samples)"
            return 0
        fi
        log "  ⚠ Partial QC found (${done_count}/${n_samples}), re-running..."
    fi

    log "  Running QC: ${n_samples} samples, 16 workers × 4 threads"

    magus qc \
        --config "${config}" \
        --outdir "${qc_out}" \
        --max-workers 16 \
        --seqtype short \
        2>&1 | tee -a "${LOG_DIR}/qc_${bioproject}.log"

    # Verify output
    if [[ -f "${post_qc}" ]]; then
        local done_count
        done_count=$(tail -n +2 "${post_qc}" | wc -l | tr -d ' ')
        log "  ✓ QC complete: ${done_count}/${n_samples} samples"
    else
        log "  ✗ QC may have failed — post_qc_config not found"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#                                  MAIN
# ══════════════════════════════════════════════════════════════════════════════
BIOPROJECTS=(
    "PRJNA484096"
    "PRJNA527658"
    "PRJNA827358"
    "PRJEB42339"
    "PRJNA1205709"
    "PRJNA1180576"
    "PRJNA783767"
)

main() {
    log "═══════════════════════════════════════════════════════════════"
    log "  Batch 1 QC — 7 BioProjects on r6a.16xlarge"
    log "═══════════════════════════════════════════════════════════════"

    setup_env

    local total=${#BIOPROJECTS[@]}
    local current=0
    local passed=0
    local failed=0

    for bioproject in "${BIOPROJECTS[@]}"; do
        current=$((current + 1))
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "[${current}/${total}] QC: ${bioproject}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if run_qc "${bioproject}"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "  QC SUMMARY: ${passed} passed, ${failed} failed (${total} total)"
    log "═══════════════════════════════════════════════════════════════"

    if [[ "${failed}" -gt 0 ]]; then
        log "  ⚠ Check logs in ${LOG_DIR}/qc_*.log for failures"
    else
        log "  ✓ All QC complete! Ready for taxonomy."
        log ""
        log "  NEXT: Run taxonomy with DB preloaded into RAM:"
        log "    cat /data/gtdb_index/gtdbr226_29_comp2.xtr2 > /dev/null"
        log "    bash /data/batch1_taxonomy.sh"
    fi
}

main "$@"
