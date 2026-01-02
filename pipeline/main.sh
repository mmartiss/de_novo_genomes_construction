#!/bin/bash

# ================= CONFIGURATION =================
CONDA_PATH=$(conda info --base)/etc/profile.d/conda.sh

READS_DIR="/home/ubuntu/data/reads"
WORK_DIR="/home/ubuntu/pipeline"
REF_GENOME="/home/ubuntu/data/h37rv/GCF_000195955.2_ASM19595v2_genomic.fna"

THREADS=4

set -e
set -u

# ================= SETUP CONDA =================
if [ -f "$CONDA_PATH" ]; then
    source "$CONDA_PATH"
else
    echo "KLAIDA: Nerastas conda.sh faile $CONDA_PATH"
    exit 1
fi

# ================= MAIN LOOP =================
shopt -s nullglob
FILES=(${READS_DIR}/*.fastq*)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files found in $READS_DIR"
    exit 1
fi

echo "Found ${#FILES[@]} samples. Starting pipeline..."

for INPUT_FILE in "${FILES[@]}"; do

    PREFIX=$(basename "$INPUT_FILE" | sed -E 's/(\.fastq|\.fq)(\.gz)?$//')

    TBPROF_DIR="$WORK_DIR/tbprofiler_results/${PREFIX}"
    FILT_DIR="$WORK_DIR/filtered_reads"
    ASSEMBLY_DIR="$WORK_DIR/assemblies/${PREFIX}"
    SNIPPY_DIR="$WORK_DIR/snippy_results/${PREFIX}"
    LOGS_DIR="$WORK_DIR/logs/${PREFIX}"
    AUTO_OUT="$WORK_DIR/autocycler_out_${PREFIX}"

    mkdir -p "$TBPROF_DIR" "$FILT_DIR" "$ASSEMBLY_DIR" "$SNIPPY_DIR" "$LOGS_DIR"

    TBPROF_LOG="$LOGS_DIR/tbprofiler.log"
    FILT_LOG="$LOGS_DIR/nanofilt.log"
    SNIPPY_LOG="$LOGS_DIR/snippy.log"
    AUTO_LOG="$LOGS_DIR/autocycler_full.log"

    echo "=================================================="
    echo "PROCESSING: $PREFIX"
    echo "=================================================="

    # ================= STEP 1: TB-PROFILER =================
    if [ -f "$TBPROF_DIR/results/${PREFIX}_nano.results.json" ]; then
        echo "[SKIP] TB-Profiler already done"
    else
        echo "[RUN] TB-Profiler..."
        conda activate tb-profiler
        tb-profiler profile -m nanopore -1 "$INPUT_FILE" -p "${PREFIX}_nano" --dir "$TBPROF_DIR" --txt --call_whole_genome > "$TBPROF_LOG" 2>&1
        conda deactivate
    fi

    # ================= STEP 2: NANOFILT =================
    FILTERED_READS="$FILT_DIR/filtered_${PREFIX}.fastq.gz"

    if [ -s "$FILTERED_READS" ]; then
         echo "[SKIP] NanoFilt already done"
    else
        echo "[RUN] NanoFilt (-q 17 -l 2500)..."
        conda activate nanofilt
        zcat "$INPUT_FILE" | NanoFilt -q 17 -l 2500 | gzip > "$FILTERED_READS"
        conda deactivate
    fi

    if [ ! -s "$FILTERED_READS" ] || [ $(zcat "$FILTERED_READS" | head -n 1 | wc -l) -eq 0 ]; then
        echo "FAILURE: NanoFilt removed ALL reads for $PREFIX. Skipping sample."
        continue
    fi

    # ================= STEP 3: AUTOCYCLER =================
    FINAL_ASSEMBLY="$AUTO_OUT/final_assembly/final_assembly.fasta"

    if [ -s "$FINAL_ASSEMBLY" ]; then
        echo "[SKIP] Autocycler already done"
    else
        echo "[RUN] Autocycler..."
        conda activate autocycler
        {
            GENOME_SIZE=$(autocycler helper genome_size --reads "$FILTERED_READS" --threads "$THREADS" | tail -1)

            SUBSAMPLE_DIR="$WORK_DIR/subsampled_${PREFIX}"
            mkdir -p "$SUBSAMPLE_DIR"
            autocycler subsample --reads "$FILTERED_READS" --out_dir "$SUBSAMPLE_DIR" --genome_size "$GENOME_SIZE"

            for i in 01 02 03 04; do
                READS_FILE="$SUBSAMPLE_DIR/sample_${i}.fastq"
                [ -f "$READS_FILE" ] || continue

                if [ ! -f "$ASSEMBLY_DIR/flye_${i}/assembly.fasta" ]; then
                     autocycler helper flye --reads "$READS_FILE" \
                        --out_prefix "$ASSEMBLY_DIR/flye_${i}" \
                        --threads "$THREADS" --genome_size "$GENOME_SIZE" \
                        --read_type "ont_r10" --min_depth_rel 0.1
                fi
            done

            for f in "$ASSEMBLY_DIR"/flye_*/assembly.fasta; do
                [ -f "$f" ] && sed -i 's/^>.*$/& Autocycler_consensus_weight=2/' "$f"
            done
            rm -rf "$SUBSAMPLE_DIR"

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
    if [ -s "$SNIPPY_DIR/snps.vcf" ]; then
        echo "[SKIP] Snippy already done"
    else
        echo "[RUN] Snippy vs Reference..."
        conda activate snippy
        snippy --cpus "$THREADS" --outdir "$SNIPPY_DIR" \
               --ref "$REF_GENOME" --se "$FILTERED_READS" --force > "$SNIPPY_LOG" 2>&1
        conda deactivate
    fi

    echo "DONE with $PREFIX"
done

echo "ALL SAMPLES COMPLETED."