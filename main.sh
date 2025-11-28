#!/bin/bash

set -e

# ================= 1. NUSTATYMAI =================
THREADS=$(($(nproc) - 2))
if [ "$THREADS" -lt 1 ]; then THREADS=1; fi

CURRENT_DIR=$(pwd)
READS_DIR="$CURRENT_DIR/files/runs"
WORK_DIR="$CURRENT_DIR/output"
REF_GENOME="$CURRENT_DIR/files/h37rv/GCF_000195955.2_ASM19595v2_genomic.fna"

# source /scratch/lustre/home/maab9325/miniforge3/etc/profile.d/conda.sh

mkdir -p "$WORK_DIR"

# --- BENDRO LOGO NUSTATYMAS ---
MASTER_LOG="$WORK_DIR/pipeline_overall.log"
# master log, i ekrana ir i faila
exec > >(tee -a "$MASTER_LOG") 2>&1

echo "=========================================================="
echo "Pipeline Start: $(date)"
echo "Work Directory: $WORK_DIR"
echo "Master Log: $MASTER_LOG"
echo "Threads per sample: $THREADS"
echo "=========================================================="

# ================= 2. PAGRINDINIS CIKLAS =================

shopt -s nullglob

for INPUT_FILE in "${READS_DIR}"/*.fastq*; do

    [ -f "$INPUT_FILE" ] || continue

    PREFIX=$(basename "$INPUT_FILE" | sed -E 's/(\.fastq|\.fq)(\.gz)?$//')

    echo "----------------------------------------------------------"
    echo "Processing Sample: $PREFIX"
    echo "Started at: $(date)"
    echo "----------------------------------------------------------"

    TBPROF_DIR="$WORK_DIR/tbprofiler_results"
    FILT_DIR="$WORK_DIR/filtered_reads"
    ASSEMBLY_DIR="$WORK_DIR/assemblies/${PREFIX}"
    SNIPPY_DIR="$WORK_DIR/snippy_vs_assembly/${PREFIX}"
    LOGS_DIR="$WORK_DIR/logs/${PREFIX}"
    
    AUTO_OUT="$WORK_DIR/autocycler_out_${PREFIX}"

    mkdir -p "$TBPROF_DIR" "$FILT_DIR" "$ASSEMBLY_DIR" "$SNIPPY_DIR" "$LOGS_DIR"

    TBPROF_LOG="$LOGS_DIR/tbprofiler.log"
    FILT_LOG="$LOGS_DIR/nanofilt.log"
    SNIPPY_LOG="$LOGS_DIR/snippy.log"
    AUTO_LOG="$LOGS_DIR/autocycler_full.log"

    # ================= 4. TB-PROFILER =================
    conda activate tbprofiler

    echo "Running TB-Profiler..."
    {
        echo "=== TBprofiler started: $(date) ==="
        tb-profiler profile -m nanopore \
            -1 "$INPUT_FILE" \
            -p "${PREFIX}_nano" \
            --dir "$TBPROF_DIR" \
            --txt \
            --call_whole_genome \
            -t "$THREADS"
        echo "=== TBprofiler finished: $(date) ==="
    } > "$TBPROF_LOG" 2>&1

    # ================= 5. NANOFILT =================
    echo "Running NanoFilt..."
    {
        echo "=== NanoFilt started: $(date) ==="
        FILTERED_READS="$FILT_DIR/filtered_${PREFIX}.fastq.gz"
        NanoFilt -q 17 -l 2500 "$INPUT_FILE" | gzip > "$FILTERED_READS"
        echo "Output: $FILTERED_READS"
        echo "=== NanoFilt finished: $(date) ==="
    } > "$FILT_LOG" 2>&1

    if [[ ! -s "$FILTERED_READS" ]]; then
        echo "ERROR: Filtered file empty for $PREFIX!"
        conda deactivate
        continue 
    fi

    # ================= 6. AUTOCYCLER =================
    conda deactivate
    conda activate autocycler
    
    echo "Running Autocycler..."
    READ_TYPE="ont_r10"

    echo "=== Autocycler started: $(date) ===" > "$AUTO_LOG"

    GENOME_SIZE=$(autocycler helper genome_size --reads "$FILTERED_READS" --threads "$THREADS" 2>&1 | tail -1)
    echo "Genome size: $GENOME_SIZE" >> "$AUTO_LOG"

    SUBSAMPLE_DIR="$WORK_DIR/subsampled_reads_${PREFIX}"
    autocycler subsample --reads "$FILTERED_READS" --out_dir "$SUBSAMPLE_DIR" --genome_size "$GENOME_SIZE" >> "$AUTO_LOG" 2>&1

    for i in 01 02 03 04; do
        [ -f "$SUBSAMPLE_DIR/sample_${i}.fastq" ] || continue
        autocycler helper flye \
            --reads "$SUBSAMPLE_DIR/sample_${i}.fastq" \
            --out_prefix "$ASSEMBLY_DIR/flye_${i}" \
            --threads "$THREADS" \
            --genome_size "$GENOME_SIZE" \
            --read_type "$READ_TYPE" \
            --min_depth_rel 0.1 \
            >> "$AUTO_LOG" 2>&1
    done

    for f in "$ASSEMBLY_DIR"/flye*.fasta; do
        [ -f "$f" ] && sed -i 's/^>.*$/& Autocycler_consensus_weight=2/' "$f"
    done
    rm -rf "$SUBSAMPLE_DIR"

    autocycler compress -i "$ASSEMBLY_DIR" -a "$AUTO_OUT" >> "$AUTO_LOG" 2>&1
    autocycler cluster -a "$AUTO_OUT" >> "$AUTO_LOG" 2>&1

    for c in "$AUTO_OUT"/clustering/qc_pass/cluster_*; do
        [ -d "$c" ] || continue
        autocycler trim -c "$c" >> "$AUTO_LOG" 2>&1
        autocycler resolve -c "$c" >> "$AUTO_LOG" 2>&1
    done

    autocycler combine -a "$AUTO_OUT" -i "$AUTO_OUT"/clustering/qc_pass/cluster_*/5_final.gfa >> "$AUTO_LOG" 2>&1

    if [ -f "$AUTO_OUT/final_assembly/final_assembly.gfa" ]; then
        autocycler gfa2fasta \
            "$AUTO_OUT/final_assembly/final_assembly.gfa" \
            "$AUTO_OUT/final_assembly/final_assembly.fasta" >> "$AUTO_LOG" 2>&1
    fi

    FINAL_ASSEMBLY="$AUTO_OUT/final_assembly/final_assembly.fasta"

    if [ -f "$FINAL_ASSEMBLY" ]; then
        CONTIGS=$(grep -c "^>" "$FINAL_ASSEMBLY")
        echo "Autocycler finished. Final assembly: $CONTIGS contigs" >> "$AUTO_LOG"
        echo "Autocycler Success: $CONTIGS contigs generated."
    else
        echo "Autocycler failed for $PREFIX. Check log: $AUTO_LOG"
        conda deactivate
        continue
    fi

    # ================= 7. SNIPPY =================
    conda deactivate
    conda activate tbprofiler 

    echo "Running Snippy..."
    {
        echo "=== Snippy started: $(date) ==="
        snippy \
            --cpus "$THREADS" \
            --outdir "$SNIPPY_DIR" \
            --ref "$REF_GENOME" \
            --reads "$FILTERED_READS" \
            --force
        echo "=== Snippy finished: $(date) ==="
    } > "$SNIPPY_LOG" 2>&1

    echo "Finished processing $PREFIX at $(date)"
    
    conda deactivate

done

echo "=========================================================="
echo "All samples processed!"
echo "Master log saved to: $MASTER_LOG"
echo "=========================================================="
exit 0