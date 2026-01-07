FROM continuumio/miniconda3:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    curl \
    procps \
    libpcre3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN conda install mamba -n base -c conda-forge -y && \
    conda config --set channel_priority strict

RUN mamba create -n tb-profiler -c bioconda -c conda-forge tb-profiler -y

RUN mamba create -n nanofilt -c bioconda -c conda-forge nanofilt -y

RUN mamba create -n autocycler -c bioconda -c conda-forge \
  autocycler flye raven-assembler miniasm metamdbg necat plassembler nextdenovo -y

RUN mamba create -n snippy -c conda-forge -c bioconda -c defaults snippy perl-bioperl samtools=1.15

RUN echo "source /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc

WORKDIR /data

CMD ["/bin/bash"]
