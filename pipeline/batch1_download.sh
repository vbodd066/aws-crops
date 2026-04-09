#!/usr/bin/env bash
# =============================================================================
# Batch 1 Download Script — 7 small BioProjects (~81 GB uncompressed total)
# Run on: c6a.large EC2 instance (2 vCPU, 4 GB RAM)
# Volume: /data (2 TB gp3, already has xtree DB + MAGUS)
#
# This script:
#   1. Installs SRA Toolkit (if needed)
#   2. Creates /data/{BIOPROJECT}/ folders
#   3. Fetches run accession lists from ENA API
#   4. Downloads SRA → converts to FASTQ via prefetch + fasterq-dump
#   5. Generates MAGUS-compatible config TSVs (filename / pe1 / pe2)
#
# After this completes, switch to r6a.16xlarge to run QC + taxonomy.
# =============================================================================
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
DATA_DIR="/data"
TMP_DIR="${DATA_DIR}/tmp"
SRA_CACHE="${DATA_DIR}/sra_cache"
LOG_DIR="${DATA_DIR}/logs"

# c6a.large has 2 vCPU — keep fasterq-dump threads low
FASTERQ_THREADS=2

# Batch 1: 7 small bioprojects (all under ~63 GB uncompressed)
BIOPROJECTS=(
    "PRJNA484096"    # Hyper-Arid Desert (Negev)          — 112 runs,  8.2 GB
    "PRJNA527658"    # Antarctic Dry Valleys (McMurdo)     —  38 runs,  1.2 GB
    "PRJNA827358"    # Antarctic Dry Valleys (McMurdo)     —  40 runs,  1.0 GB
    "PRJEB42339"     # Volcanic/Basaltic (Surtsey)        —  59 runs,  6.6 GB
    "PRJNA1205709"   # Volcanic/Basaltic (Fagradalsfjall)  — 126 runs, 62.4 GB
    "PRJNA1180576"   # Glacial Forefield (Deglaciated)     —  60 runs,  1.4 GB
    "PRJNA783767"    # Iron-Rich Lateritic Soils (Kerala)  —   2 runs,  0.3 GB
)

# ── Helper functions ─────────────────────────────────────────────────────────
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log() { echo "[$(timestamp)] $*" | tee -a "${LOG_DIR}/batch1_download.log"; }

die() { log "FATAL: $*"; exit 1; }

check_disk_space() {
    local avail_gb
    avail_gb=$(df -BG "${DATA_DIR}" | awk 'NR==2 {gsub("G",""); print $4}')
    if (( avail_gb < 50 )); then
        die "Only ${avail_gb} GB free on ${DATA_DIR}. Need at least 50 GB."
    fi
    log "Disk space available: ${avail_gb} GB"
}

# ── Install SRA Toolkit if not present ───────────────────────────────────────
install_sra_toolkit() {
    if command -v fasterq-dump &>/dev/null; then
        log "SRA Toolkit already installed: $(fasterq-dump --version 2>&1 | head -1)"
        return 0
    fi

    log "Installing SRA Toolkit..."
    if command -v conda &>/dev/null; then
        conda install -y -c bioconda sra-tools
    else
        # Manual install
        cd /tmp
        wget -q https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz
        tar -xzf sratoolkit.current-ubuntu64.tar.gz
        cp -r sratoolkit.*/bin/* /usr/local/bin/ 2>/dev/null || \
            sudo cp -r sratoolkit.*/bin/* /usr/local/bin/
        rm -rf sratoolkit.* 
    fi

    command -v fasterq-dump &>/dev/null || die "fasterq-dump not found after install"
    log "SRA Toolkit installed: $(fasterq-dump --version 2>&1 | head -1)"
}

# ── Fetch run accessions from ENA API ────────────────────────────────────────
fetch_run_list() {
    local bioproject="$1"
    local outfile="$2"
    local url="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${bioproject}&result=read_run&fields=run_accession,library_layout&format=tsv&limit=0"

    log "Fetching run list for ${bioproject} from ENA..."
    curl -sS --retry 3 --retry-delay 5 "${url}" > "${outfile}"

    local count
    count=$(tail -n +2 "${outfile}" | wc -l | tr -d ' ')
    log "  Found ${count} runs for ${bioproject}"

    if [[ "${count}" -eq 0 ]]; then
        die "No runs found for ${bioproject} — check ENA API"
    fi
}

# ── Download and convert a single run ────────────────────────────────────────
download_run() {
    local run_acc="$1"
    local outdir="$2"
    local run_tmp="${TMP_DIR}/${run_acc}"

    # Skip if already downloaded
    if [[ -f "${outdir}/${run_acc}_1.fastq" && -f "${outdir}/${run_acc}_2.fastq" ]] || \
       [[ -f "${outdir}/${run_acc}.fastq" ]]; then
        log "    ✓ ${run_acc} already exists, skipping"
        return 0
    fi

    mkdir -p "${run_tmp}" "${SRA_CACHE}"

    # Step 1: prefetch (download .sra to cache — more reliable than streaming)
    log "    ↓ prefetch ${run_acc}..."
    prefetch "${run_acc}" \
        --output-directory "${SRA_CACHE}" \
        --max-size 100G \
        --progress 2>&1 | tail -1 || {
        log "    ⚠ prefetch failed for ${run_acc}, trying fasterq-dump directly..."
    }

    # Step 2: fasterq-dump (SRA → FASTQ)
    log "    ⇄ fasterq-dump ${run_acc}..."
    local sra_file="${SRA_CACHE}/${run_acc}/${run_acc}.sra"
    local input_arg="${run_acc}"

    # Use local .sra file if prefetch succeeded, otherwise let fasterq-dump fetch
    if [[ -f "${sra_file}" ]]; then
        input_arg="${sra_file}"
    fi

    fasterq-dump "${input_arg}" \
        --outdir "${outdir}" \
        --temp "${run_tmp}" \
        --threads "${FASTERQ_THREADS}" \
        --split-3 \
        --skip-technical \
        --progress 2>&1 | tail -3 || {
        log "    ✗ FAILED: fasterq-dump ${run_acc}"
        echo "${run_acc}" >> "${LOG_DIR}/failed_downloads.txt"
        rm -rf "${run_tmp}"
        return 1
    }

    # Step 3: Clean up SRA cache + temp for this run
    rm -rf "${SRA_CACHE}/${run_acc}" "${run_tmp}"

    log "    ✓ ${run_acc} done"
    return 0
}

# ── Generate MAGUS config TSV for a bioproject ───────────────────────────────
generate_config() {
    local bioproject="$1"
    local fastq_dir="$2"
    local config_file="${fastq_dir}/${bioproject}_config.tsv"

    log "Generating MAGUS config: ${config_file}"

    # Header
    printf "filename\tpe1\tpe2\n" > "${config_file}"

    local pe_count=0
    local se_count=0

    # Find all paired-end FASTQs (_1.fastq + _2.fastq)
    for f1 in "${fastq_dir}"/*_1.fastq; do
        [[ -f "$f1" ]] || continue
        local base
        base=$(basename "$f1" _1.fastq)
        local f2="${fastq_dir}/${base}_2.fastq"

        if [[ -f "$f2" ]]; then
            printf "%s\t%s\t%s\n" "${base}" "${f1}" "${f2}" >> "${config_file}"
            pe_count=$((pe_count + 1))
        fi
    done

    # Also create a single-end config if any SE-only files exist
    local se_config="${fastq_dir}/${bioproject}_config_SE.tsv"
    printf "filename\tpe1\n" > "${se_config}"

    for f in "${fastq_dir}"/*.fastq; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f" .fastq)
        # Skip PE files (ending in _1 or _2)
        if [[ "$base" =~ _[12]$ ]]; then
            continue
        fi
        printf "%s\t%s\n" "${base}" "${f}" >> "${se_config}"
        se_count=$((se_count + 1))
    done

    # Remove SE config if empty
    if [[ "${se_count}" -eq 0 ]]; then
        rm -f "${se_config}"
    fi

    log "  Config written: ${pe_count} paired-end, ${se_count} single-end samples"
    if [[ "${se_count}" -gt 0 ]]; then
        log "  ⚠ WARNING: ${se_count} single-end samples found — these need separate MAGUS handling"
        log "  SE config saved to: ${se_config}"
    fi

    if [[ "${pe_count}" -eq 0 && "${se_count}" -eq 0 ]]; then
        log "  ✗ ERROR: No FASTQ files found in ${fastq_dir}!"
        return 1
    fi
}

# ── Print summary ────────────────────────────────────────────────────────────
print_summary() {
    log ""
    log "═══════════════════════════════════════════════════════════════════"
    log "                    BATCH 1 DOWNLOAD SUMMARY"
    log "═══════════════════════════════════════════════════════════════════"

    local total_size=0

    for bioproject in "${BIOPROJECTS[@]}"; do
        local projdir="${DATA_DIR}/${bioproject}"
        if [[ -d "${projdir}" ]]; then
            local fastq_count pe_count size_gb config_status
            fastq_count=$(find "${projdir}" -name "*.fastq" | wc -l | tr -d ' ')
            pe_count=$(find "${projdir}" -name "*_1.fastq" | wc -l | tr -d ' ')
            size_gb=$(du -sh "${projdir}" 2>/dev/null | awk '{print $1}')
            config_status="✗"
            [[ -f "${projdir}/${bioproject}_config.tsv" ]] && config_status="✓"
            log "  ${bioproject}: ${fastq_count} files (${pe_count} PE pairs), ${size_gb}, config: ${config_status}"

            local dir_bytes
            dir_bytes=$(du -sb "${projdir}" 2>/dev/null | awk '{print $1}')
            total_size=$((total_size + dir_bytes))
        else
            log "  ${bioproject}: ✗ NOT DOWNLOADED"
        fi
    done

    local total_gb=$((total_size / 1073741824))
    log ""
    log "  Total disk used by Batch 1 FASTQs: ~${total_gb} GB"
    log ""

    # Check for failures
    if [[ -f "${LOG_DIR}/failed_downloads.txt" ]]; then
        local fail_count
        fail_count=$(sort -u "${LOG_DIR}/failed_downloads.txt" | wc -l | tr -d ' ')
        log "  ⚠ ${fail_count} runs failed — see ${LOG_DIR}/failed_downloads.txt"
        log "  Re-run this script to retry failed downloads (existing files are skipped)"
    else
        log "  ✓ All downloads completed successfully!"
    fi

    log ""
    log "  NEXT STEPS:"
    log "    1. Stop this c6a.large instance"
    log "    2. Launch r6a.16xlarge, attach this volume, mount /data"
    log "    3. source /data/miniconda3/etc/profile.d/conda.sh && conda activate magus"
    log "    4. export PATH=/data/2FP_MAGUS/bin:\$PATH"
    log "    5. Pre-load xtree DB: cat /data/gtdb_index/gtdbr226_29_comp2.xtr2 > /dev/null"
    log "    6. Run QC + taxonomy for each bioproject"
    log "═══════════════════════════════════════════════════════════════════"
}

# ══════════════════════════════════════════════════════════════════════════════
#                                  MAIN
# ══════════════════════════════════════════════════════════════════════════════
main() {
    # Create dirs first so logging works
    mkdir -p "${TMP_DIR}" "${SRA_CACHE}" "${LOG_DIR}"

    log "Starting Batch 1 download (7 BioProjects, ~81 GB uncompressed)"
    log "Host: $(hostname), Instance: c6a.large"
    check_disk_space
    install_sra_toolkit

    # Process each bioproject
    for bioproject in "${BIOPROJECTS[@]}"; do
        log ""
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "Processing: ${bioproject}"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local projdir="${DATA_DIR}/${bioproject}"
        local run_list="${projdir}/run_list.tsv"
        mkdir -p "${projdir}"

        # Fetch run accessions from ENA
        fetch_run_list "${bioproject}" "${run_list}"

        # Download each run
        local total_runs done_runs failed_runs
        total_runs=$(tail -n +2 "${run_list}" | wc -l | tr -d ' ')
        done_runs=0
        failed_runs=0

        while IFS=$'\t' read -r run_acc layout; do
            done_runs=$((done_runs + 1))
            log "  [${done_runs}/${total_runs}] ${run_acc} (${layout})"

            if download_run "${run_acc}" "${projdir}"; then
                : # success
            else
                failed_runs=$((failed_runs + 1))
            fi
        done < <(tail -n +2 "${run_list}")

        log "${bioproject}: ${done_runs} processed, ${failed_runs} failed"

        # Generate MAGUS config TSV
        generate_config "${bioproject}" "${projdir}"
    done

    # Final cleanup
    rm -rf "${TMP_DIR}" "${SRA_CACHE}"

    # Print summary
    print_summary

    log "Batch 1 download complete!"
}

main "$@"
