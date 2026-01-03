Sita direktorija paruosta google hpc paleidimui.
 - nebent reiketu dar sutvarkyti resursu naudojima

Yra pridetas dockerfile, kuris sutvarko ir suruosa visas conda envs.
Tada reikes jungtis i dockerfile ir paleisti failus sia tvarka:
1. data direktorijoje download.sh
2. pipeline direktorijoje main.sh

---------------------------------------------------------------------
Su docker issprestos problemos su tb-profiler aplinka ir nanofilt.
Sios dvi aplinkos atskirtos.
Snippy isspresta kodo problema
 - downgradinau samtools i 1.7 versija

---------------------------------------------------------------------
Testinis raw read, kuris praeina visus testus yra:
 - SRR34323118

---------------------------------------------------------------------
Kad visi envs butu tvarkingi, naudoti mamba, ir pagaliau issprendziau dependencies problemas del snippy ir samtools.

---------------------------------------------------------------------
Jei leisti paprastai (ne ant google hpc, nenaudojant docker):

    $ conda install mamba -n base -c conda-forge -y && conda config --set channel_priority strict
    $ mamba create -n tb-profiler -c bioconda -c conda-forge tb-profiler -y
    $ mamba create -n nanofilt -c bioconda -c conda-forge nanofilt -y
    $ mamba create -n autocycler -c bioconda -c conda-forge autocycler -y
    $ mamba create -n snippy -c conda-forge -c bioconda -c defaults snippy perl-bioperl samtools=1.15