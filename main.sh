#!/bin/bash

# ================= CONFIGURATION =================

# 1. Update this to your local conda path (use 'conda info --base' to find it)
# Example: /home/username/miniconda3 or /Users/username/miniforge3
CONDA_BASE_DIR="$HOME/miniforge3"

# 2. Set Paths
READS_DIR="/home/marabr/kursinio_projektas/data/testukas"
WORK_DIR="/home/marabr/kursinio_projektas/pipeline"
REF_GENOME="/home/marabr/kursinio_projektas/data/h37rv/GCF_000195955.2_ASM19595v2_genomic.fna"

# 3.
THREADS=4
set -e

# ================= SETUP CONDA =================
#source "${CONDA_BASE_DIR}/etc/profile.d/conda.sh"
source /root/miniconda3/etc/profile.d/conda.sh
# ================= MAIN LOOP =================

# Find all fastq files
shopt -s nullglob
FILES=(${READS_DIR}/*.fastq*)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files found in $READS_DIR"
    exit 1
fi

echo "Found ${#FILES[@]} samples. Starting pipeline..."

for INPUT_FILE in "${FILES[@]}"; do

    # --- PREPARE VARIABLES ---
    PREFIX=$(basename "$INPUT_FILE" | sed -E 's/(\.fastq|\.fq)(\.gz)?$//')

    # Define directories
    TBPROF_DIR="$WORK_DIR/tbprofiler_results/${PREFIX}" # Note: Nested inside folder to keep it clean
    FILT_DIR="$WORK_DIR/filtered_reads"
    ASSEMBLY_DIR="$WORK_DIR/assemblies/${PREFIX}"
    SNIPPY_DIR="$WORK_DIR/snippy_vs_assembly/${PREFIX}"
    LOGS_DIR="$WORK_DIR/logs/${PREFIX}"
    AUTO_OUT="$WORK_DIR/autocycler_out_${PREFIX}"

    mkdir -p "$TBPROF_DIR" "$FILT_DIR" "$ASSEMBLY_DIR" "$SNIPPY_DIR" "$LOGS_DIR"

    # Define Log files
    TBPROF_LOG="$LOGS_DIR/tbprofiler.log"
    FILT_LOG="$LOGS_DIR/nanofilt.log"
    SNIPPY_LOG="$LOGS_DIR/snippy.log"
    AUTO_LOG="$LOGS_DIR/autocycler_full.log"

    echo "=================================================="
    echo "Processing: $PREFIX"
    echo "=================================================="

    cd "$WORK_DIR"

    # ================= STEP 1: TB-PROFILER =================
    # Checkpoint: Check if the JSON result exists
    if [ -f "$TBPROF_DIR/results/${PREFIX}_nano.results.json" ]; then
        echo "[SKIP] TB-Profiler already done for $PREFIX"
    else
        echo "[RUN] TB-Profiler..."
        conda activate tbprofiler
        {
            tb-profiler profile -m nanopore -1 "$INPUT_FILE" -p "${PREFIX}_nano" --dir "$TBPROF_DIR" --txt --call_whole_genome
        } > "$TBPROF_LOG" 2>&1
        conda deactivate
    fi

# ================= STEP 2: NANOFILT =================
    FILTERED_READS="$FILT_DIR/filtered_${PREFIX}.fastq.gz"

    # Checkpoint: Check if filtered file exists and is not empty
    if [ -s "$FILTERED_READS" ]; then
         # Extra check: ensure it's not just an empty gzip header
         if [ -z "$(gunzip -c "$FILTERED_READS" | head -n 1)" ]; then
             echo "[RE-RUN] File exists but contains 0 reads. Re-running NanoFilt..."
             SHOULD_RUN_NANOFILT=true
         else
             echo "[SKIP] NanoFilt already done for $PREFIX"
             SHOULD_RUN_NANOFILT=false
         fi
    else
        SHOULD_RUN_NANOFILT=true
    fi

    if [ "$SHOULD_RUN_NANOFILT" = true ]; then
        echo "[RUN] NanoFilt (Strict params: -q 17 -l 2500)..."
        conda activate tbprofiler
        # Using zcat/gunzip locally to ensure pipe works
        gunzip -c "$INPUT_FILE" | NanoFilt -q 17 -l 2500 | gzip > "$FILTERED_READS"
        conda deactivate
    fi

    # === CRITICAL SAFETY CHECK ===
    # Check if we have any reads left after filtering
    # gunzip -c reads content; head -n 1 checks first line.
    FIRST_LINE=$(gunzip -c "$FILTERED_READS" | head -n 1)

    if [ -z "$FIRST_LINE" ]; then
        echo "----------------------------------------------------------------"
        echo "   FAILURE: NanoFilt removed ALL reads for $PREFIX."
        echo "   Reason: Parameters (-q 17 -l 2500) are too strict for this sample."
        echo "   Action: SKIPPING $PREFIX and moving to the next sample."
        echo "----------------------------------------------------------------"
        continue  # <--- THIS IS THE MAGIC WORD. It jumps to the next loop item.
    fi

    # ================= STEP 3: AUTOCYCLER =================
    FINAL_ASSEMBLY="$AUTO_OUT/final_assembly/final_assembly.fasta"

    # Checkpoint: Check if final assembly exists
    if [ -s "$FINAL_ASSEMBLY" ]; then
        echo "[SKIP] Autocycler already done for $PREFIX"
    else
        echo "[RUN] Autocycler..."
        conda activate autocycler

        # We wrap the Autocycler logic in a subshell or block to capture logs easily
        {
            echo "--- Starting Autocycler ---"
            GENOME_SIZE=$(autocycler helper genome_size --reads "$FILTERED_READS" --threads "$THREADS" 2>&1 | tail -1)

            SUBSAMPLE_DIR="subsampled_reads_${PREFIX}"
            autocycler subsample --reads "$FILTERED_READS" --out_dir "$SUBSAMPLE_DIR" --genome_size "$GENOME_SIZE"

            for i in 01 02 03 04; do
                [ -f "$SUBSAMPLE_DIR/sample_${i}.fastq" ] || continue
                # Skip flye run if output exists
                if [ ! -f "$ASSEMBLY_DIR/flye_${i}/assembly.fasta" ]; then
                     autocycler helper flye --reads "$SUBSAMPLE_DIR/sample_${i}.fastq" \
                        --out_prefix "$ASSEMBLY_DIR/flye_${i}" \
                        --threads "$THREADS" --genome_size "$GENOME_SIZE" \
                        --read_type "ont_r10" --min_depth_rel 0.1
                fi
            done

            # Tag weights
            for f in "$ASSEMBLY_DIR"/flye*.fasta; do
                [ -f "$f" ] && sed -i 's/^>.*$/& Autocycler_consensus_weight=2/' "$f"
            done
            rm -rf "$SUBSAMPLE_DIR" # Clean up space on laptop

            # Merge steps
            autocycler compress -i "$ASSEMBLY_DIR" -a "$AUTO_OUT"
            autocycler cluster -a "$AUTO_OUT"

            for c in "$AUTO_OUT"/clustering/qc_pass/cluster_*; do
                [ -d "$c" ] || continue
                autocycler trim -c "$c"
                autocycler resolve -c "$c"
            done

            autocycler combine -a "$AUTO_OUT" -i "$AUTO_OUT"/clustering/qc_pass/cluster_*/5_final.gfa

            if [ -f "$AUTO_OUT/final_assembly/final_assembly.gfa" ]; then
                autocycler gfa2fasta "$AUTO_OUT/final_assembly/final_assembly.gfa" "$AUTO_OUT/final_assembly/final_assembly.fasta"
            fi
        } >> "$AUTO_LOG" 2>&1
        conda deactivate
    fi

    # ================= STEP 4: SNIPPY =================
    # Checkpoint: Check if VCF exists
    if [ -s "$SNIPPY_DIR/snps.vcf" ]; then
        echo "[SKIP] Snippy already done for $PREFIX"
    else
        echo "[RUN] Snippy..."
        conda activate tbprofiler
        {
            snippy --cpus "$THREADS" --outdir "$SNIPPY_DIR" \
                --ref "$REF_GENOME" --se "$FILTERED_READS" --force
        } > "$SNIPPY_LOG" 2>&1
        conda deactivate
    fi

    echo "Finished processing $PREFIX"
    echo "--------------------------------------------------"

done

echo "ALL JOBS COMPLETED."