#!/bin/bash

INPUT_FILE="access_sra.tsv"     # input assembly ir sra
OUTPUT_TABLE="reads/run_info.tsv"     # Rezultatu lentele
LOG_FILE="reads/download_ena.log"     # Log failas
DOWNLOAD_DIR="reads/"             # runs direktorija

# NAUJI KINTAMIEJI H37RV
H37RV_DIR="h37rv"
H37RV_URL="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/195/955/GCF_000195955.2_ASM19595v2/GCF_000195955.2_ASM19595v2_genomic.fna.gz"
H37RV_OUT_FILE="${H37RV_DIR}/GCF_000195955.2_ASM19595v2_genomic.fna"

exec > >(tee -a "${LOG_FILE}") 2>&1

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_msg "--- Skripto pradžia (ENA/EMBL rezimas) ---"

# Patikros
if ! command -v wget &> /dev/null; then
    log_msg "KLAIDA: 'wget' nerastas. idiekite ji arba naudokite curl."
    exit 1
fi

if [ ! -d "$DOWNLOAD_DIR" ]; then
    log_msg "Sukuriama direktorija: $DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"
fi

# ========================================================
# H37Rv parsiuntimas
# ========================================================
if [ ! -d "$H37RV_DIR" ]; then
    log_msg "Sukuriama H37Rv direktorija: $H37RV_DIR"
    mkdir -p "$H37RV_DIR"
fi

if [ -f "$H37RV_OUT_FILE" ]; then
    log_msg "H37Rv referencinis failas jau egzistuoja, praleidžiama."
else
    log_msg "Siunčiamas H37Rv referencinis genomas..."
    # NCBI saugo suspaustus .gz failus, todėl parsiunčiame ir iškart išarchyvuojame
    wget -qO- "$H37RV_URL" | gunzip > "$H37RV_OUT_FILE"
    
    if [ $? -eq 0 ]; then
        log_msg "H37Rv sėkmingai parsiųstas: $H37RV_OUT_FILE"
    else
        log_msg "KLAIDA: Nepavyko parsiųsti H37Rv referencinio genomo."
    fi
fi
# ========================================================

# header
if [ ! -f "$OUTPUT_TABLE" ]; then
    echo -e "Run_ID\tSRA_Input_ID\tAssembly_ID" > "$OUTPUT_TABLE"
fi

while read -r assembly sra_id; do
    # tuscios eilutes
    if [ -z "$assembly" ] || [ -z "$sra_id" ]; then
        continue
    fi

    log_msg "Apdorojama: $sra_id (Assembly: $assembly)"

    # 1. Kreipiamės į ENA API
    log_msg "  Ieškoma failų ENA duomenų bazėje..."

    api_url="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${sra_id}&result=read_run&fields=run_accession,fastq_ftp&format=tsv&download=true&limit=0"

    api_response=$(wget -qO- "$api_url" | tail -n +2)

    if [ -z "$api_response" ]; then
        log_msg "  ĮSPĖJIMAS: Nerasta duomenų ENA bazėje kodui $sra_id (arba nėra interneto ryšio)"
        continue
    fi

    # 2. Skaitome API atsakymą
    while IFS=$'\t' read -r run_id ftp_links; do

        if [ -z "$run_id" ] || [ -z "$ftp_links" ]; then
            log_msg "  Pastaba: Run ID $run_id neturi FASTQ nuorodų, praleidžiama."
            continue
        fi

        log_msg "  -> Rastas Run: $run_id. Nuorodos gautos."

        IFS=';' read -ra LINKS <<< "$ftp_links"

        download_success=true

        for link in "${LINKS[@]}"; do
            if [[ "$link" != http* ]] && [[ "$link" != ftp* ]]; then
                url="ftp://$link"
            else
                url="$link"
            fi

            filename=$(basename "$url")

            if [ -f "${DOWNLOAD_DIR}/${filename}" ]; then
                 log_msg "     Failas ${DOWNLOAD_DIR}/${filename} jau egzistuoja, nesisiunčiama."
            else
                 log_msg "     Siunčiama: $filename į $DOWNLOAD_DIR/"
                 wget -c -nv -P "$DOWNLOAD_DIR" "$url"

                 if [ $? -ne 0 ]; then
                     log_msg "     KLAIDA siunčiant $url"
                     download_success=false
                 fi
            fi
        done

        # 3. Įrašome į lentelę
        if [ "$download_success" = true ]; then
            if ! grep -q "$run_id" "$OUTPUT_TABLE"; then
                echo -e "$run_id\t$sra_id\t$assembly" >> "$OUTPUT_TABLE"
                log_msg "     Informacija įrašyta į $OUTPUT_TABLE"
            fi
        fi

    done <<< "$api_response"

done < "$INPUT_FILE"

log_msg "--- Skripto pabaiga ---"