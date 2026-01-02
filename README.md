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
 - 