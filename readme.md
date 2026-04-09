# AWS Crops MAGUS Pipeline Notes

## Overview

This repository tracks MAGUS processing for selected BioProjects, including:

- QC outputs (`post_qc_config`, `qc_read_counts.tsv`)
- Taxonomy outputs (`merged_xtree.csv`, `raw_alignments/*.cov|*.ref|*.perq`)
- Pipeline scripts in [pipeline]

## Pipeline scripts

Scripts in [pipeline]:

- [pipeline/batch1_download.sh]
    - Downloads SRA, converts to FASTQ, and prepares project config TSVs.
- [pipeline/batch1_qc.sh]
    - Runs `magus qc` and writes `post_qc_config`.
- [pipeline/count_reads.sh]
    - Computes before/after QC read counts.
- [pipeline/batch1_taxonomy.sh]
    - Runs `magus taxonomy` and writes taxonomy outputs.
- [pipeline/scp_download_bioproject_results.sh]
    - Pulls relevant output files from EC2 to local project folders.

Each script includes its own usage section.

## Output structure (per BioProject)

Expected local structure per project:

- `*_config.tsv`
- `post_qc_config`
- `qc_read_counts.tsv`
- `merged_xtree.csv`
- `taxonomy/raw_alignments/` with:
    - `*.cov`
    - `*.ref`
    - `*.perq`

## Current local status snapshot

From the current local workspace:

- [PRJNA665391](PRJNA665391): `merged_xtree.csv`, `post_qc_config`, `qc_read_counts.tsv`, `raw_alignments/`
- [PRJNA971922](PRJNA971922): `merged_xtree.csv`, `post_qc_config`, `qc_read_counts.tsv`, `raw_alignments/`
- [PRJNA484096](PRJNA484096): `post_qc_config`, `qc_read_counts.tsv`, `taxonomy/merged_xtree.csv`, `taxonomy/raw_alignments/`
- [PRJEB42339](PRJEB42339): `post_qc_config`, `qc_read_counts.tsv`, `taxonomy/merged_xtree.csv`, `taxonomy/raw_alignments/`
- [PRJNA1180576](PRJNA1180576): `post_qc_config`, `qc_read_counts.tsv`, `taxonomy/merged_xtree.csv`, `taxonomy/raw_alignments/`
- [PRJNA783767](PRJNA783767): `post_qc_config`, `qc_read_counts.tsv`, `taxonomy/merged_xtree.csv`, `taxonomy/raw_alignments/`

## Remaining BioProjects to process

Still pending full end-to-end pipeline execution:

- `PRJNA527658`
- `PRJNA827358`
- `PRJEB10725`
- `PRJNA825700`
- `PRJNA1019501`
- `PRJNA1205709`