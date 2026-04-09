#!/bin/bash

# ==============================================================================
# USAGE & DOCUMENTATION
# ==============================================================================
# DESCRIPTION:
#   Calculates read counts before and after MAGUS Quality Control (QC)
#   for all specified BioProjects.
#
#   - Raw counts: Scanned from uncompressed .fastq in project dir
#   - QC counts:  Scanned from gzipped .fa.gz in qc/ using zgrep
#
# PREREQUISITES:
#   1. Raw data: /data/{BIOPROJECT}/*_1.fastq
#   2. QC data:  /data/{BIOPROJECT}/qc/*.R1.fa.gz
#   3. Tools:    'bc' for math, 'zgrep' for compressed search (standard on Ubuntu)
#
# EXECUTION:
#   chmod +x count_reads.sh
#   ./count_reads.sh
# ==============================================================================

DATA_DIR="/data"

# Batch 1 projects that completed QC successfully
BIOPROJECTS=(
    "PRJNA484096"
    "PRJEB42339"
    "PRJNA1205709"
    "PRJNA1180576"
    "PRJNA783767"
    "PRJNA665391_rerun"
)

for bioproject in "${BIOPROJECTS[@]}"; do
    PROJ_DIR="${DATA_DIR}/${bioproject}"
    QC_DIR="${PROJ_DIR}/qc"
    OUTPUT_TSV="${PROJ_DIR}/qc_read_counts.tsv"

    # Find raw FASTQs — could be in project root or fastq_out/
    RAW_DIR="${PROJ_DIR}"
    if [[ -d "${PROJ_DIR}/fastq_out" ]]; then
        RAW_DIR="${PROJ_DIR}/fastq_out"
    fi

    # Check for raw files
    raw_files=( "${RAW_DIR}"/*_1.fastq )
    if [[ ! -f "${raw_files[0]}" ]]; then
        echo "⚠ ${bioproject}: No raw *_1.fastq files found in ${RAW_DIR}, skipping"
        continue
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ${bioproject} — counting reads"
    echo "═══════════════════════════════════════════════════════════"

    # Create TSV Header
    echo -e "Run_ID\tRaw_Reads\tQC_Filtered_Reads\tSurvival_Rate" > "$OUTPUT_TSV"

    total_raw=0
    total_qc=0
    n_samples=0

    for f in "${RAW_DIR}"/*_1.fastq; do
        [[ -f "$f" ]] || continue

        # Extract Run ID
        run_id=$(basename "$f" _1.fastq)
        n_samples=$((n_samples + 1))

        # Count Raw Reads (FASTQ: every 4th line starting with @)
        raw_count=$(awk 'NR % 4 == 1' "$f" | wc -l | tr -d ' ')
        total_raw=$((total_raw + raw_count))

        # Count QC Reads (Compressed FASTA)
        qc_file="${QC_DIR}/${run_id}.R1.fa.gz"

        if [[ -f "$qc_file" ]]; then
            qc_count=$(zgrep -c "^>" "$qc_file")
            total_qc=$((total_qc + qc_count))

            if [[ "$raw_count" -gt 0 ]]; then
                percent=$(echo "scale=2; ($qc_count / $raw_count) * 100" | bc)
            else
                percent="0.00"
            fi
        else
            qc_count="MISSING"
            percent="N/A"
        fi

        echo -e "${run_id}\t${raw_count}\t${qc_count}\t${percent}%" >> "$OUTPUT_TSV"
        echo "  ${run_id}: ${raw_count} → ${qc_count} (${percent}%)"
    done

    # Summary line
    if [[ "$total_raw" -gt 0 ]]; then
        overall_pct=$(echo "scale=2; ($total_qc / $total_raw) * 100" | bc)
    else
        overall_pct="0.00"
    fi

    echo ""
    echo "  TOTAL: ${n_samples} samples, ${total_raw} raw → ${total_qc} QC (${overall_pct}% survival)"
    echo "  Saved: ${OUTPUT_TSV}"
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  All done!"
echo "═══════════════════════════════════════════════════════════"
