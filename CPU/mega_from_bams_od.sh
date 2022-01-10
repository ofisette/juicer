#!/bin/bash
{
#### Description: Wrapper script to phase genomic variants from ENCODE DCC hic-pipeline.
#### Usage: bash ./mega.sh [-v|--vcf <path_to_vcf>] <path_to_merged_dedupped_bam_1> ... <path_to_merged_dedup_bam_N>.
#### Input: list of merged_dedup.bam files corresponding to individual Hi-C experiments.
#### Output: "mega" hic map and "mega" chromatin accessibility bw file.
#### Optional input: phased vcf file. When passed launches generation of diploid versions of output.
#### Dependencies: Java, Samtools, GNU Parallel, KentUtils, Juicer, 3D-DNA (for diploid portion only).
#### Written by:

echo "*****************************************************" >&1
echo "cmd log: "$0" "$* >&1
echo "*****************************************************" >&1

USAGE="
*****************************************************
Simplified mega script for ENCODE DCC hic-pipeline.

USAGE: ./mega.sh -c|--chrom-sizes <path_to_chrom_sizes_file> [-g|--genome-id genome_id] [-r|--resolutions resolutions_string] [-v|--vcf <path_to_vcf>] [-C|--exclude-chr-from-diploid chr_list]  [--separate-homologs] [-p|--psf <path_to_psf>] [--reads-to-homologs <path_to_reads_to_homologs_file>] [--juicer-dir <path_to_juicer_dir>] [--phaser-dir <path_to_phaser_dir>] [-t|--threads thread_count] [-T|--threads-hic hic_thread_count] [--from-stage stage] [--to-stage stage] <path_to_merged_dedup_bam_1> ... <path_to_merged_dedup_bam_N>

DESCRIPTION:
This is a simplied mega.sh script to produce aggregate Hi-C maps and chromatic accessibility tracks from multiple experiments. The pipeline includes optional diploid steps which produce diploid versions of the contact maps and chromatin accessibility tracks.

ARGUMENTS:
path_to_merged_dedup_bam
						Path to bam file containing deduplicated alignments of Hi-C reads in bam format (output by Juicer2). Multiple bam files are expected to be passed as arguments.

OPTIONS:
-h|--help
						Shows this help.

HAPLOID PORTION
-g|--genome-id [genome_id]
                        Genome id, e.g. hg38, for some of the common references used by Juicer. Used to run the motif finder.

-c|--chrom-sizes [path_to_chrom_sizes_file]                         
                        Path to chrom.sizes file for the reference used when processing the individual Hi-C experiments.

-r|--resolutions    [string]
                        Comma-separated resolutions at which to build the hic files. Default: 2500000,1000000,500000,250000,100000,50000,25000,10000,5000,2000,1000,500,200,100,50,20,10.

DIPLOID PORTION:
-v|--vcf [path_to_vcf]
						Path to a Variant Call Format (vcf) file containing phased sequence variation data, e.g. as generated by the ENCODE DCC Hi-C variant calling & phasing pipeline. Passing a vcf file invokes a diploid section of the script.

-C|--exclude-chr-from-diploid [chr_list]
						Remove specific molecules from the chromosome list (default: chrY). Note that -c and -C are incompatible in that if both are invoked, only the last listed option will be taken into account. Deafult: chrY.

--separate-homologs
						Build two separate contact maps & two separate accessibility tracks for homologs as opposed to a single diploid contact map with interleaved homologous chromosomes. This is the preferred mode for comparing contacts across homologs using the \"Observed over Control\" view for map comparison in Juicebox. Importantly, assignment of chromosomes to homologs is arbitrary. Default: not invoked.
-p|--psf [path_to_psf]
						Path to a 3D-DNA phaser psf file containing heterozygous variant and phasing information. Optional input to fast-forward some steps & save compute on processing the vcf file.

--reads-to-homologs [path_to_reads_to_homologs_file]
                        Path to a reads_to_homologs file generated by the phasing pipeline. Optional input to fast-forward some steps & save compute on diploid processing (assumes the input bams were used for phasing).

WORKFLOW CONTROL:
-t|--threads [num]
        				Indicate how many threads to use. Default: half of available cores as calculated by parallel --number-of-cores.

-T|--threads-hic [num]
						Indicate how many threads to use when generating the Hi-C file. Default: 24.

--juicer-dir [path_to_juicer_dir]
                        Path to Juicer directory, contains scripts/, references/, and restriction_sites/

--phaser-dir [path_to_3ddna_dir]
                        Path to 3D-DNA directory, contains phase/

--from-stage [pipeline_stage]
						Fast-forward to a particular stage of the pipeline. The pipeline_stage argument can be \"prep\", \"hic\", \"hicnarrow\", \"dhs\", \"diploid_hic\", \"diploid_dhs\", \"cleanup\".

--to-stage [pipeline_stage]
						Exit after a particular stage of the pipeline. The argument can be \"prep\", \"hic\", \"hicnarrow\", \"dhs\", \"diploid_hic\", \"diploid_dhs\", \"cleanup\".

*****************************************************
"

# defaults:
resolutionsToBuildString="-r 2500000,1000000,500000,250000,100000,50000,25000,10000,5000,2000,1000,500,200,100,50,20,10"
exclude_chr="Y|chrY|MT|chrM"
separate_homologs=false
mapq=1 ##lowest mapq of interest

# multithreading
threads=`parallel --number-of-cores`
threads=$((threads/2))
# adjust for mem usage
tmp=`awk '/MemTotal/ {threads=int($2/1024/1024/2/6-1)}END{print threads+0}' /proc/meminfo 2>/dev/null`
tmp=$((tmp+0))
([ $tmp -gt 0 ] && [ $tmp -lt $threads ]) && threads=$tmp
threadsHic=$threads

## Create temporary directory for parallelization
# tmpdir="HIC_tmp"
# if [ ! -d "$tmpdir" ]; then
#     mkdir "$tmpdir"
#     chmod 777 "$tmpdir"
# fi
# export TMPDIR=${tmpdir}

#staging
first_stage="prep"
last_stage="cleanup"
declare -A stage
stage[prep]=0
stage[hic]=1
stage[hicnarrow]=2
stage[dhs]=3
stage[diploid_hic]=4
stage[diploid_dhs]=5
stage[cleanup]=6

############### HANDLE OPTIONS ###############

while :; do
	case $1 in
		-h|--help)
			echo "$USAGE" >&1
			exit 0
        ;;
## HAPLOID PORTION        
        -g|--genome-id) OPTARG=$2
            genome_id=$OPTARG
            shift
        ;;
        -c|--chrom-sizes) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.chrom.sizes ]]; then
                echo "... -c|--chrom-sizes flag was triggered with $OPTARG value." >&1
                chrom_sizes=$OPTARG
            else
                echo " :( Chrom.sizes file is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
                exit 1
            fi            
            shift
        ;;
        -r|--resolutions) OPTARG=$2
            resolutionsToBuildString="-r "$OPTARG
            shift
        ;;
## DIPLOID PORTION
        -v|--vcf) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.vcf ]]; then
                echo "... -v|--vcf flag was triggered, will try to generate diploid versions of the hic file and accessibility track based on phasing data in $OPTARG." >&1
                vcf=$OPTARG
            else
                	echo " :( Vcf file is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
					exit 1
            fi            
            shift
        ;;
        -C|--exclude-chr-from-diploid) OPTARG=$2
			echo "... -C|--exclude-chr-from-diploid flag was triggered, will ignore variants on $OPTARG." >&1
			exclude_chr=$OPTARG
        	shift
        ;;
        --separate-homologs)
			echo "... --separate-homologs flag was triggered, will build two separate contact maps and two separate accessibility tracks (_r.hic/_a.hic and _r.bw/_a.bw) for chromosomal homologs with identical chromosomal labels." >&1
			separate_homologs=true
		;;
        -p|--psf) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.psf ]]; then
                echo "... -p|--psf flag was triggered, will try to generate diploid versions of the hic file and accessibility track based on phasing data in $OPTARG." >&1
                psf=$OPTARG
            else
                	echo " :( Psf file is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
					exit 1
            fi            
            shift
        ;;
        --reads-to-homologs) OPTARG=$2
            if [ -s $OPTARG ] && [[ $OPTARG == *.txt ]]; then
                echo "... --reads-to-homologs flag was triggered, will try to generate diploid versions of the hic file and accessibility track based on reads-to-homolog data in $OPTARG." >&1
                reads_to_homologs=$OPTARG
            else
                	echo " :( File is not found at expected location, is empty or does not have the expected extension. Exiting!" >&2
					exit 1
            fi      
            shift
        ;;
## WORKFLOW
        -t|--threads) OPTARG=$2
        	re='^[0-9]+$'
			if [[ $OPTARG =~ $re ]]; then
					echo "... -t|--threads flag was triggered, will try to parallelize across $OPTARG threads." >&1
					threads=$OPTARG
			else
					echo " :( Wrong syntax for thread count parameter value. Exiting!" >&2
					exit 1
			fi        	
        	shift
        ;;
        -T|--threads-hic) OPTARG=$2
        	re='^[0-9]+$'
			if [[ $OPTARG =~ $re ]]; then
					echo "... -T|--threads-hic flag was triggered, will try to parallelize across $OPTARG threads when building hic map." >&1
					threadsHic=$OPTARG
			else
					echo " :( Wrong syntax for hic thread count parameter value. Exiting!" >&2
					exit 1
			fi        	
        	shift
        ;;
        --juicer-dir) OPTARG=$2
            if [ -d $OPTARG ]; then
                echo "... --juicer-dir flag was triggered with $OPTARG." >&1
                juicer_dir=$OPTARG
            else
				exit 1
                echo " :( Juicer folder not found at expected location. Exiting!" >&2
            fi    
            shift
        ;;
        --phaser-dir) OPTARG=$2
            if [ -d $OPTARG ]; then
                echo "... --phaser-dir flag was triggered with $OPTARG." >&1
                phaser_dir=$OPTARG
            else
				exit 1
                echo " :( Juicer folder not found at expected location. Exiting!" >&2
            fi    
            shift
        ;;
		--from-stage) OPTARG=$2
			if [ "$OPTARG" == "prep" ] || [ "$OPTARG" == "hic" ] || [ "$OPTARG" == "hicnarrow" ] || [ "$OPTARG" == "dhs" ] || [ "$OPTARG" == "diploid_hic" ] || [ "$OPTARG" == "diploid_dhs" ] || [ "$OPTARG" == "cleanup" ]; then
        		echo "... --from-stage flag was triggered. Will fast-forward to $OPTARG." >&1
        		first_stage=$OPTARG
			else
				echo " :( Whong syntax for pipeline stage. Please use prep/hic/hicnarrow/dhs/diploid_hic/diploid_dhs/cleanup. Exiting!" >&2
				exit 1
			fi
			shift
        ;;
		--to-stage) OPTARG=$2
			if [ "$OPTARG" == "prep" ] || [ "$OPTARG" == "hic" ] || [ "$OPTARG" == "hicnarrow" ] || [ "$OPTARG" == "dhs" ] || [ "$OPTARG" == "diploid_hic" ] || [ "$OPTARG" == "diploid_dhs" ] || [ "$OPTARG" == "cleanup" ]; then
				echo "... --to-stage flag was triggered. Will exit after $OPTARG." >&1
				last_stage=$OPTARG
			else
				echo " :( Whong syntax for pipeline stage. Please use prep/hic/hicnarrow/dhs/diploid_hic/diploid_dhs/cleanup. Exiting!" >&2
				exit 1			
			fi
			shift
		;;
### utilitarian
        --) # End of all options
			shift
			break
		;;
		-?*)
			echo ":| WARNING: Unknown option. Ignoring: ${1}" >&2
		;;
		*) # Default case: If no more options then break out of the loop.
			break
	esac
	shift
done

## optional TODO: give error if diploid options are invoked without a vcf file

if [[ "${stage[$first_stage]}" -gt "${stage[$last_stage]}" ]]; then
	echo >&2 ":( Please make sure that the first stage requested is in fact an earlier stage of the pipeline to the one requested as last. Exiting!"
	exit 1
fi

[ -z $chrom_sizes ] && { echo >&2 ":( Chrom.sizes file is not optional. Please use the -c flag to point to the chrom.sizes file used when running Juicer. Exiting!"; exit 1; }

[ -z $genome_id ] && { echo >&2 ":| Warning: no genome_id is provided. Please provide a genome_id if using one of the common references to be able to run the motif finder. Ignoring motif finder!"; }

############### HANDLE DEPENDENCIES ###############

## Juicer & Phaser

[ -z $juicer_dir ] && { echo >&2 ":( Juicer directory is not specified. Exiting!"; exit 1; } 
([ ! -z $vcf ] && [ -z $phaser_dir ]) && { echo >&2 ":( Phaser directory is not specified. Exiting!"; exit 1; } 

##	Java Dependency
type java >/dev/null 2>&1 || { echo >&2 ":( Java is not available, please install/add to path Java. Exiting!"; exit 1; }

##	GNU Parallel Dependency
type parallel >/dev/null 2>&1 || { echo >&2 ":( GNU Parallel support is set to true (default) but GNU Parallel is not in the path. Please install GNU Parallel or set -p option to false. Exiting!"; exit 1; }
[ $(parallel --version | awk 'NR==1{print $3}') -ge 20150322 ] || { echo >&2 ":( Outdated version of GNU Parallel is installed. Please install/add to path v 20150322 or later. Exiting!"; exit 1; }

## Samtools Dependency
type samtools >/dev/null 2>&1 || { echo >&2 ":( Samtools are not available, please install/add to path. Exiting!"; exit 1; }
ver=`samtools --version | awk 'NR==1{print \$NF}'`
[[ $(echo "$ver < 1.13" |bc -l) -eq 1 ]] && { echo >&2 ":( Outdated version of samtools is installed. Please install/add to path v 1.13 or later. Exiting!"; exit 1; }

## kentUtils Dependency
type bedGraphToBigWig >/dev/null 2>&1 || { echo >&2 ":( bedGraphToBigWig is not available, please install/add to path, e.g. from kentUtils. Exiting!"; exit 1; }

############### HANDLE ARGUMENTS ###############

bam=`echo "${@:1}"`
##TODO: check file extentions

############### MAIN #################
## 0. PREP BAM FILE

if [ "$first_stage" == "prep" ]; then

	echo "...Extracting unique paired alignments from bams and sorting..." >&1

	# make header for the merged file pipe
	parallel --will-cite "samtools view -H {} > {}_header.bam" ::: $bam
	header_list=`parallel --will-cite "printf %s' ' {}_header.bam" ::: $bam`
	samtools merge --no-PG -f mega_header.bam ${header_list}
	rm ${header_list}

	samtools cat -@ $((threads * 2)) -h mega_header.bam $bam | samtools view -u -d "rt:0" -d "rt:1" -d "rt:2" -d "rt:3" -d "rt:4" -d "rt:5" -@ $((threads * 2)) -F 0x400 -q $mapq - |  samtools sort -@ $threads -m 6G -o reads.sorted.bam
	[ `echo "${PIPESTATUS[@]}" | tr -s ' ' + | bc` -eq 0 ] || { echo ":( Pipeline failed at bam sorting. See stderr for more info. Exiting!" | tee -a /dev/stderr && exit 1; }
	rm mega_header.bam

	samtools index -@ $threads reads.sorted.bam	
	[ $? -eq 0 ] || { echo ":( Failed at bam indexing. See stderr for more info. Exiting!" | tee -a /dev/stderr && exit 1; }		
	# e.g. will fail with chr longer than ~500Mb. Use samtools index -c -m 14 reads.sorted.bam

	echo ":) Done extracting unique paired alignments from bam and sorting." >&1

	[ "$last_stage" == "prep" ] && { echo "Done with the requested workflow. Exiting after prepping bam!"; exit; }
	first_stage="hic"

fi

## I. HIC

if [ "$first_stage" == "hic" ]; then

	echo "...Generating mega hic file..." >&1
    
    ([ -f reads.sorted.bam ] && [ -f reads.sorted.bam.bai ]) || { echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr; exit 1; }

    export SHELL=$(type -p bash)
    doit () {
            mapq=$2
            samtools view -@ 2 -h -q $mapq reads.sorted.bam $1 | awk -F '\t' -v mapq=$mapq '{for(i=12;i<=NF;i++){if($i~/^ip:i:/){ip=substr($i,6)}else if ($i~/^mp:i:/){mp=substr($i,6)}else if ($i~/^MQ:i:/){mq=substr($i,6)}}}(mq<mapq){next}$7=="="{if(ip>mp){next}else if (ip==mp){keep[$1]=$0}else{print 0, $3, ip, 0, 0, $3, mp, 1};next}$7<$3{next}{print 0, $3, ip, 0, 0, $7, mp, 1 > "/dev/stderr"}END{for(i in keep){n=split(keep[i],a,"\t"); for(s=12;s<=n;s++){if(a[s]~"^ip:i:"){ip=substr(a[s],6)}}; print 0, a[3], ip, 0, 0, a[3], ip, 1}}'
    }

    export -f doit
    
    ## opt1
    ## extra variable contains all (small) sequences that are not already in the chrom.sizes file. There is no use in them for generating the hic file, they are generated only for consistensy (and potentially stats)
    extra=`samtools view -H reads.sorted.bam | grep '^@SQ' | sed "s/.*SN:\([^\t]*\).*/\1/g" | awk 'FILENAME==ARGV[1]{drop[$1]=1;next}!($1 in drop)' ${chrom_sizes} - | xargs`

    #merged1.txt
    awk -v extra="$extra" '{print $1}END{print extra}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log -k doit {} 1 >merged1.txt 2>merged1.tmp.txt
    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	[ $exitval -eq 0 ] || { echo ":( Pipeline failed at generating the mega mnd file. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
    rm temp.log
    sort -k2,2 -k6,6 -S 6G --parallel=${threads} merged1.tmp.txt >> merged1.txt && rm merged1.tmp.txt

    #merged30.txt
    ## @MUHAMMAD: why do we have two now rather than running pre from the same one?
    awk -v extra="$extra" '{print $1}END{print extra}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log -k doit {} 30 >merged30.txt 2>merged30.tmp.txt
    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	[ $exitval -eq 0 ] || { echo ":( Pipeline failed at generating the mega mnd file. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
    rm temp.log
    sort -k2,2 -k6,6 -S 6G --parallel=${threads} merged30.tmp.txt >> merged30.txt && rm merged30.tmp.txt

    ## opt2
    # awk -v extra=$extra '{print $1}END{print extra}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log "doit {} 1 >out.{#}.txt 2>err.{#}.txt"
    # exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	# [ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
	# awk '{print NR}END{print NR+1}' $chrom_sizes | parallel --will-cite -k "cat out.{}.txt" >merged1.txt
    # awk '{print NR}END{print NR+1}' $chrom_sizes | parallel --will-cite -k "sort -k6,6 -S6G err.{}.txt" >>merged1.txt
    # awk '{print NR}END{print NR+1}' $chrom_sizes | parallel --will-cite "rm out.{}.txt err.{}.txt"
    # rm temp.log
    
    touch inter.txt inter_hists.m inter_30.txt inter_hists_30.m

    if [[ $threadsHic -gt 1 ]] && [[ ! -s merged1_index.txt ]]
    then
        "${juicer_dir}"/scripts/index_by_chr.awk merged1.txt 500000 > merged1_index.txt
        tempdirPre="HIC_tmp" && mkdir $tempdirPre
        threadHicString="--threads $threadsHic -i merged1_index.txt -t ${tempdirPre}"
    else
        threadHicString=""
    fi

    if [[ $threadsHic -gt 1 ]] && [[ ! -s merged30_index.txt ]]
	then
	    "${juicer_dir}"/scripts/common/index_by_chr.awk merged30.txt 500000 > merged30_index.txt
        tempdirPre30="HIC30_tmp" && mkdir "${tempdirPre30}"
	    threadHic30String="--threads $threadsHic -i merged30_index.txt -t ${tempdirPre30}"
    else
        threadHic30String=""
	fi

    ##@MUHAMMAD:
    export IBM_JAVA_OPTIONS="-Xmx50000m -Xgcthreads1"
    export _JAVA_OPTIONS="-Xmx50000m -Xms50000m"
    ##@MUHAMMAD:

    "${juicer_dir}"/scripts/juicer_tools pre -n -s inter.txt -g inter_hists.m -q 1 "$resolutionsToBuildString" "$threadHicString" merged1.txt inter.hic "$chrom_sizes"
    "${juicer_dir}"/scripts/juicer_tools addNorm --threads $threadsHic inter.hic
	rm -Rf "${tempdirPre}"
    ## TODO: check for failure

    "${juicer_dir}"/scripts/juicer_tools pre -n -s inter_30.txt -g inter_30_hists.m -q 30 "$resolutionsToBuildString" "$threadHic30String" merged30.txt inter_30.hic "$chrom_sizes"
	"${juicer_dir}"/scripts/juicer_tools addNorm --threads $threadsHic "${outputDir}"/inter_30.hic
    rm -Rf "${tempdirPre30}"
    ## TODO: check for failure

    echo ":) Done building mega hic files." >&1

	[ "$last_stage" == "hic" ] && { echo "Done with the requested workflow. Exiting after generating the mega.hic file!"; exit; }
	first_stage="hicnarrow"
fi

## II. HICNARROW.
if [ "$first_stage" == "hicnarrow" ]; then
	
	echo "...Annotating loops and domains..." >&1

    [ -f inter_30.hic ] || { echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr; exit 1; }

    [ -z $genome_id ] && { echo ":( This step requires a genome ID. Please provide (e.g. \"-g hg38\") or skip this step. Exiting!" | tee -a /dev/stderr; exit 1; }

    # Create loop lists file for MQ > 30
    "${juicer_dir}"/scripts/juicer_hiccups.sh -j "${juicer_dir}"/scripts/juicer_tools -i inter_30.hic -m "${juicer_dir}"/references/motif -g "$genome_id"

    ##TODO: check for failure

    "${juicer_dir}"/scripts/juicer_arrowhead.sh -j "${juicer_dir}"/scripts/juicer_tools -i inter_30.hic

    ##TODO: check for failure

	echo ":) Done annotating loops and domains." >&1

	[ "$last_stage" == "hicnarrow" ] && { echo "Done with the requested workflow. Exiting after generating loop and domain annotations!"; exit; }
	first_stage="dhs"

fi

## III. BUILD HAPLOID ACCESSIBILITY TRACKS 
if [ "$first_stage" == "dhs" ]; then

	echo "...Building accessibility tracks..." >&1

    ([ -f reads.sorted.bam ] && [ -f reads.sorted.bam.bai ]) || { echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr; exit 1; }

    ## figure out platform
    pl=`samtools view -H reads.sorted.bam | grep '^@RG' | sed "s/.*PL:\([^\t]*\).*/\1/g" | sed "s/ILM/ILLUMINA/g;s/Illumina/ILLUMINA/g;s/LS454/454/g" | uniq`
	([ "$pl" == "ILLUMINA" ] || [ "$pl" == "454" ]) || { echo ":( Platform name is not recognized or data from different platforms seems to be mixed. Can't handle this case. Exiting!" | tee -a /dev/stderr && exit 1; }
	[ "$pl" == "ILLUMINA" ] && junction_rt_string="-d rt:2 -d rt:3 -d rt:4 -d rt:5" || junction_rt_string="-d rt:0 -d rt:1"

    export SHELL=$(type -p bash)
    export junction_rt_string=${junction_rt_string}
    doit () {
            mapq=$2
            samtools view -@ 2 ${junction_rt_string} -q $mapq -h reads.sorted.bam $1 | awk 'BEGIN{OFS="\t"}{for (i=12; i<=NF; i++) {if ($i ~ /^ip/) {split($i, ip, ":"); locus[ip[3]]++; break}}}END{for (i in locus) {print $3, i-1, i, locus[i]}}' | sort -k2,2n -S6G
    }
    export -f doit

    # mapq1 accessibility track
    awk '{print $1}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log -k doit {} 1 > tmp.bedgraph
    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	[ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
	rm temp.log
    bedGraphToBigWig tmp.bedgraph $chrom_sizes inter.bw
    rm tmp.bedgraph

    # mapq30 accessibility track
    awk '{print $1}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log -k doit {} 30 > tmp.bedgraph
    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	[ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
	rm temp.log
    bedGraphToBigWig tmp.bedgraph $chrom_sizes inter_30.bw
    rm tmp.bedgraph

    echo ":) Done building accessibility tracks." >&1
	
	[ "$last_stage" == "dhs" ] && { echo "Done with the requested workflow. Exiting after building haploid accessibility tracks!"; exit; }
	([ -z $vcf ] && [ -z $psf ] && [ -z ${reads_to_homologs} ]) && first_stage="cleanup" || first_stage="diploid_hic"

fi

## IV. BUILD DIPLOID CONTACT MAPS
if [ "$first_stage" == "diploid_hic" ]; then

	echo "...Building diploid contact maps from reads overlapping phased SNPs..." >&1

	if [ ! -s reads.sorted.bam ] || [ ! -s reads.sorted.bam.bai ] ; then
		echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr
		exit 1
	fi
    ## @PAUL: which chrom.sizes file is used? Maybe it's fine..?

    chr=`awk -v exclude_chr=${exclude_chr} 'BEGIN{split(exclude_chr,a,"|"); for(i in a){ignore[a[i]]=1}}!($1 in ignore){str=str"|"$1}END{print substr(str,2)}' ${chrom_sizes}`

    if [ -z $reads_to_homologs ]; then

        if [ -z $psf ]; then
            echo "  ... Parsing vcf..."
            awk -v chr=${chr} -v output_prefix="out" -f ${phaser_dir}/phase/vcf-to-psf-and-assembly.awk ${vcf}
            echo "  ... :) Done parsing vcf!"
            psf=out.psf
            rm out.assembly
        fi

        echo "  ... Extracting reads overlapping SNPs..."
        export SHELL=$(type -p bash)
		export psf=${psf}
		export pipeline=${phaser_dir}
		doit () { 
			samtools view -@ 2 reads.sorted.bam $1 | awk -f ${pipeline}/phase/extract-SNP-reads-from-sam-file.awk ${psf} -
		}
		export -f doit
		echo $chr | tr "|" "\n" | parallel -j $threads --will-cite --joblog temp.log doit > dangling.sam
		exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
		[ $exitval -eq 0 ] || { echo ":( Pipeline failed at parsing bam. Check stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
		rm temp.log

        bash ${phaser_dir}/phase/assign-reads-to-homologs.sh -t ${threads} -c ${chr} $psf dangling.sam
        reads_to_homologs=reads_to_homologs.txt
        echo "  ... :) Done extracting reads overlapping SNPs!"

    fi

    # build mnd file: can do without sort -n, repeat what was done in hic stage.
    export SHELL=$(type -p bash)
	export psf=${psf}
	export pipeline=${phaser_dir}
    export reads_to_homologs=$reads_to_homologs
    doit () { 
        samtools view -@ 2 -h reads.sorted.bam $1 | awk -v chr=$1 'BEGIN{OFS="\t"}FILENAME==ARGV[1]{if($2==chr"-r"||$2==chr"-a"){if(keep[$1]&&keep[$1]!=$2){delete keep[$1]}else{keep[$1]=$2}};next}$0~/^@SQ/{$2=$2"-r"; print; $2=substr($2,1,length($2)-2)"-a";print;next}$0~/^@/{print;next}($1 in keep)&&($7=="="||$7=="*"){$3=keep[$1];print}' $reads_to_homologs - | samtools sort -n -m 1G -O sam | awk '$0~/^@/{next}($1!=prev){if(n==2){sub("\t","",str); print str}; str=""; n=0}{for(i=12;i<=NF;i++){if($i~/^ip:i:/){$4=substr($i,6);break;}};str=str"\t"n"\t"$3"\t"$4"\t"n; n++; prev=$1}END{if(n==2){sub("\t","",str); print str}}' | sort -k 2,2 -S 6G

    }
    export -f doit
    echo $chr | tr "|" "\n" | parallel -j $threads --will-cite --joblog temp.log -k doit > diploid.mnd.txt
    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
    [ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
    rm temp.log


    ## TODO: talk with Muhammad about adding VC norm

    # build hic file(s)
    if [ "$separate_homologs" == "true" ]; then
		{ awk '$2~/-r$/{gsub("-r","",$2); gsub("-r","",$6); print}' diploid.mnd.txt > tmp1.mnd.txt && "${juicer_dir}"/scripts/juicer_tools pre -n "$resolutionsToBuildString" tmp1.mnd.txt "diploid_inter_r.hic" ${chrom_sizes}; "${juicer_dir}"/scripts/juicer_tools addNorm diploid_inter_r.hic -k VC,VC_SQRT; } #&
        { awk '$2~/-a$/{gsub("-a","",$2); gsub("-a","",$6); print}' diploid.mnd.txt > tmp2.mnd.txt && "${juicer_dir}"/scripts/juicer_tools pre -n "$resolutionsToBuildString" tmp2.mnd.txt "diploid_inter_a.hic" ${chrom_sizes}; "${juicer_dir}"/scripts/juicer_tools addNorm diploid_inter_a.hic -k VC,VC_SQRT;  } #&
		#wait
		rm tmp1.mnd.txt tmp2.mnd.txt
		## TODO: check if successful
	else
		"${juicer_dir}"/scripts/juicer_tools pre -n "$resolutionsToBuildString" diploid.mnd.txt "diploid_inter.hic" <(awk 'BEGIN{OFS="\t"}{print $1"-r", $2; print $1"-a", $2}' ${chrom_sizes})
        "${juicer_dir}"/scripts/juicer_tools addNorm diploid_inter.hic -k VC,VC_SQRT
		## TODO: check if successful
	fi

    rm -f diploid.mnd.txt out.psf dangling.sam

	echo ":) Done building diploid contact maps from reads overlapping phased SNPs." >&1
	
	[ "$last_stage" == "diploid_hic" ] && { echo "Done with the requested workflow. Exiting after building diploid contact maps!"; exit; }
	first_stage="diploid_dhs"

fi

## V. BUILD DIPLOID ACCESSIBILITY TRACKS
if [ "$first_stage" == "diploid_dhs" ]; then

	echo "...Building diploid accessibility tracks from reads overlapping phased SNPs..." >&1

	if [ ! -s reads.sorted.bam ] || [ ! -s reads.sorted.bam.bai ] || [ -z $reads_to_homologs ] || [ ! -s $reads_to_homologs ]; then
		echo ":( Files from previous stages of the pipeline appear to be missing. Exiting!" | tee -a /dev/stderr
		exit 1
	fi

    ## figure out platform
    pl=`samtools view -H reads.sorted.bam | grep '^@RG' | sed "s/.*PL:\([^\t]*\).*/\1/g" | sed "s/ILM/ILLUMINA/g;s/Illumina/ILLUMINA/g;s/LS454/454/g" | uniq`
	([ "$pl" == "ILLUMINA" ] || [ "$pl" == "454" ]) || { echo ":( Platform name is not recognized or data from different platforms seems to be mixed. Can't handle this case. Exiting!" | tee -a /dev/stderr && exit 1; }
	[ "$pl" == "ILLUMINA" ] && junction_rt_string="-d rt:2 -d rt:3 -d rt:4 -d rt:5" || junction_rt_string="-d rt:0 -d rt:1"

## @SUHAS
    export SHELL=$(type -p bash)
    export junction_rt_string=${junction_rt_string}
    export reads_to_homologs=${reads_to_homologs}
    doit () {
samtools view -@2 ${junction_rt_string} -h reads.sorted.bam $1 | awk -v chr=$1 'BEGIN{
        OFS="\t"}FILENAME==ARGV[1]{
                if($2==chr"-r"||$2==chr"-a"){
                        if(keep[$1]&&keep[$1]!=$2){
                                delete keep[$1]
                        }else{
                                keep[$1]=$2;
                                if ($3%2==0){
                                        keepRT[$1 " " $3+1]++;
                                } else{
                                        keepRT[$1 " " $3-1]++;
                                }
                        }
                };
                next
        }
        $0~/^@/{next}
        ($1 in keep){
                $3=keep[$1];                 
                for (i=12; i<=NF; i++) {
                        if ($i~/^ip/) {
                                split($i, ip, ":");
                        }
                        else if ($i ~ /^rt:/) {
                                split($i, rt, ":");
                        }
                }
                raw_locus[$3" "ip[3]]++
                if (keepRT[$1" "rt[3]]!="") {
                        locus[$3" "ip[3]]++;
                }
        }END{
                for (i in raw_locus) {
                    split(i, a, " ")
                        print a[1], a[2]-1, a[2], raw_locus[i]
                }
                for (i in locus) {
                        split(i, a, " "); 
                        print a[1], a[2]-1, a[2], locus[i] > "/dev/stderr"
                }
        }' ${reads_to_homologs} -
}

    export -f doit
    awk '{print $1}' $chrom_sizes | parallel -j $threads --will-cite --joblog temp.log -k doit >tmp_raw.bedgraph 2>tmp_corrected.bedgraph

    exitval=`awk 'NR>1{if($7!=0){c=1; exit}}END{print c+0}' temp.log`
	[ $exitval -eq 0 ] || { echo ":( Pipeline failed at building diploid contact maps. See stderr for more info. Exiting! " | tee -a /dev/stderr && exit 1; }
	rm temp.log

    sort -k1,1 -k2,2n -S6G --parallel=${treads} tmp_raw.bedgraph > tmp_raw.bedgraph.sorted && mv tmp_raw.bedgraph.sorted tmp_raw.bedgraph
    sort -k1,1 -k2,2n -S6G --parallel=${treads} tmp_corrected.bedgraph > tmp_corrected.bedgraph.sorted && mv tmp_corrected.bedgraph.sorted tmp_corrected.bedgraph

    # build bw file(s)
    if [ "$separate_homologs" == "true" ]; then
        awk 'BEGIN{OFS="\t"}$1~/-r$/{$1=substr($1,1,length($1)-2); print}' tmp_raw.bedgraph > tmp1.bedgraph
        bedGraphToBigWig tmp1.bedgraph ${chrom_sizes} diploid_inter_raw_r.bw && rm tmp1.bedgraph
        awk 'BEGIN{OFS="\t"}$1~/-a$/{$1=substr($1,1,length($1)-2); print}' tmp_raw.bedgraph > tmp2.bedgraph
        bedGraphToBigWig tmp2.bedgraph ${chrom_sizes} diploid_inter_raw_a.bw && rm tmp2.bedgraph

        awk 'BEGIN{OFS="\t"}$1~/-r$/{$1=substr($1,1,length($1)-2); print}' tmp_corrected.bedgraph > tmp1.bedgraph
        bedGraphToBigWig tmp1.bedgraph ${chrom_sizes} diploid_inter_corrected_r.bw && rm tmp1.bedgraph
        awk 'BEGIN{OFS="\t"}$1~/-a$/{$1=substr($1,1,length($1)-2); print}' tmp_corrected.bedgraph > tmp2.bedgraph
        bedGraphToBigWig tmp2.bedgraph ${chrom_sizes} diploid_inter_corrected_a.bw && rm tmp2.bedgraph
		## TODO: check if successful
	else
        bedGraphToBigWig tmp_raw.bedgraph <(awk 'BEGIN{OFS="\t"}{print $1"-r", $2; print $1"-a", $2}' ${chrom_sizes}) diploid_inter_raw.bw
        bedGraphToBigWig tmp_corrected.bedgraph <(awk 'BEGIN{OFS="\t"}{print $1"-r", $2; print $1"-a", $2}' ${chrom_sizes}) diploid_inter_corrected.bw
	fi

    #rm tmp_raw.bedgraph tmp_corrected.bedgraph

    echo ":) Done building diploid accessibility tracks from reads overlapping phased SNPs." >&1

	[ "$last_stage" == "diploid_dhs" ] && { echo "Done with the requested workflow. Exiting after building diploid accessibility tracks!"; exit; }
	first_stage="cleanup"

fi

# ## IX. CLEANUP
# 	echo "...Starting cleanup..." >&1
# 	#rm reads.sorted.bam reads.sorted.bam.bai
# 	#rm reads_to_homologs.txt
# 	echo ":) Done with cleanup. This is the last stage of the pipeline. Exiting!"
# 	exit

}