#!/bin/bash
set -e -o pipefail

############################################### CHECK ENVIRONMENT AND DEPENDENCIES #######################################

# Check if conda environment is activated
if [[ -z "$CONDA_PREFIX" ]] || [[ "$CONDA_DEFAULT_ENV" == "base" ]]; then
        echo "Please activate your Conda environment first."
        echo "-> conda activate basecaller"
        exit 1
fi

# Define dependencies
declare -a dependencies_list=(
        "samtools"
        "dorado"
#       "NanoPlot"
	"multiqc"
        "pigz"
        "pod5"
        "sequali"
        "jq"
)

echo "Checking for dependencies in the current conda environment $CONDA_PREFIX"

declare -a missing_dependencies

# Check for missing dependencies
for dep in "${dependencies_list[@]}"; do
        dep_path="$CONDA_PREFIX/bin/$dep"
        if [[ ! -x "$dep_path" ]]; then
                missing_dependencies+=("$dep")
        fi
done

if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
        echo "The following dependencies are missing:"
        for dep in "${missing_dependencies[@]}"; do
                case "$dep" in
                        "samtools")
                                echo "- samtools (conda install -c bioconda samtools)"
                                ;;
                        "dorado")
                                echo "- dorado (run update_dorado.sh script)"
                                ;;
#			"NanoPlot")
#				echo "- NanoPlot (conda install -c bioconda nanoplot)"
#				;;
                        "pigz")
                                echo "- pigz (conda install -c conda-forge pigz)"
                                ;;
                        "pod5")
                                echo "- pod5 (pip install pod5)"
                                ;;
                        "sequali")
                                echo "- sequali (pip install sequali)"
                                ;;
                        "jq")
                                echo "- jq (conda install -c conda-forge jq)"
                                ;;
                	"multiqc")
				echo "- multiqc (conda install -c bioconda multiqc)"
				;;
		        *)
                                echo "- $dep"
                                ;;
                esac
        done
        exit 1
else
        echo "All required dependencies are installed."
fi
echo ""

##########################################################################################################################

# check if stats-generating file is here
if [ ! -f "$(dirname "$0")/get_stats.sh" ]; then
    echo "Error: get_stats.sh not found in $(dirname "$0")" >&2
    exit 1
fi

#################################################### HELPER DOCUMENTATION FUNCTION #######################################

usage() {
	cat <<EOF
Usage: $(basename "$0") --input <input_file.bam> --sample-sheet <sample_sheet.csv|.txt> [options]

Demultiplexes barcoded reads from a BAM file using Dorado’s demux.

Required arguments:
	--input <file.bam>          Input BAM file
	--sample-sheet <file.csv>   Sample sheet (CSV or TXT)

Optional arguments:
	--qscore <int>              Minimum qscore filter. Default: 10
	--greedy                    Enable greedy duplex demux mode. Default: false
	--barcode-both-ends         Require barcodes on both ends. Default: false
	-h, --help                  Show this help message and exit

Notes:
  • Sample sheet can be generated using: ./format_sample_sheet.sh
  • Script auto-detects simplex/duplex mode
  • Creates submission-ready folder structure
  • Generates QC metrics
  • Supports duplex mode with false-positive filtering
EOF
}


##########################################################################################################################
#################################################### CHECK INPUT PARAMETERS ##############################################

sample_sheet=""
input_file=""
force_classification=false
qscore=10
both_ends=false

if [[ $# -eq 0 ]]; then
	usage
	exit 1
fi

while [[ "$#" -gt 0 ]]; do
	case $1 in
        	--sample-sheet)
			sample_sheet="$2"
			shift 2
			;;
        	--input)
            		input_file="$2"
			shift 2
    			;;
		--qscore)
			qscore="$2"
			shift 2
			;;
		--greedy)
			force_classification=true
			shift
			;;
		--barcode-both-ends)
			both_ends=true
	      		shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		-*)
            		echo "Unknown option: $1"
	            	exit 1
	            	;;
	        *)
	            	echo "Unexpected argument: $1"
			echo "Script usage: ./demux.sh --input <input_file.bam> --sample-sheet <sample_sheet.csv|.txt>"
         		exit 1
            		;;
    	esac
done


# input BAM file checks
if [[ -z "$input_file" ]]; then
	echo "Error: --input <input_file.bam> is required."
	exit 1
elif [[ ! -f "$input_file" ]]; then
        echo "Error: '${input_file}' is not a file or file not found."
        exit 1
elif [[ "$input_file" != *.bam ]]; then
        echo "Error: '${input_file}' is not a BAM file."
        exit 1
fi
echo "Input file: $input_file"

if [[ -z "$sample_sheet" ]]; then
	echo "Error: --sample-sheet <sample_sheet.csv|.txt> is required."
	exit 1
elif [[ ! -f "$sample_sheet" ]]; then
	echo "Error: sample sheet '${sample_sheet}' not found."
	exit 1
elif [[ "$sample_sheet" != *.csv && "$sample_sheet" != *.txt ]]; then
	echo "Error: sample_sheet must be a .csv or .txt file."
	exit 1
fi

# check if qscore is an integer and in range ]0;60]
if [[ "$qscore" =~ ^[0-9]+$ ]]; then
	if (( qscore > 0 && qscore <= 60 )); then
		echo "Qscore filter: ${qscore}"
	else
		echo "Error: Qscore must be an integer between 1 and 60."
		exit 1
	fi
else
	echo "Error: Qscore value provided is not an integer."
	exit 1
fi

root_path_temp=$(realpath -e "$input_file" | xargs dirname)
run_name=$(tail -n +2 "$sample_sheet" | awk -F ',' '{print $1}'| sort -u)
root_path="${root_path_temp}/demultiplexed_data_${run_name}"

# this part will check if a demultiplexed data folder already exists
# and if so it will just create a demultiplexed_data_2 to avoid overwriting the existing one
if [[ -d "$root_path" ]]; then
	i=2
	while [[ -d "${root_path}_$i" ]]; do
		((i++))
	done
	root_path="${root_path}_$i"
fi

file=$(basename "$input_file")
filename="${file%.bam}"
kit_name=$(tail -n +2 "$sample_sheet" | awk -F ',' '{print $2}' | sort -u)

##########################################################################################################################
########################################################## MAIN SCRIPT ###################################################

# create project tree
mkdir -p "$root_path"
mkdir -p "$root_path"/{fastq_files,ubam_files,QC_reports,logs,temp}
mkdir -p "$root_path"/summaries/{all,fail,pass}

log="${root_path}/logs/log_demultiplexing_${run_name}_$(date '+%Y%m%d_%H%M%S').txt"

{
        echo ""
        echo "╔════════════════════════════════════╗"
        echo "║     Starting demultiplexing...     ║"
        echo "╚════════════════════════════════════╝"
        echo ""
} | tee -a "$log"

echo "Run started at: $(date '+%d-%m-%Y %H:%M:%S')" | tee -a "$log"
echo "Run name: ${run_name}" | tee -a "$log"
echo "Kit name: ${kit_name}" | tee -a "$log"
echo "Qscore filter value: ${qscore}" | tee -a "$log"
if [[ $both_ends == true ]]; then
	echo "Both ends barcodes mode activated" | tee -a "$log"
fi
echo "Sample sheet content:" | tee -a "$log"
cat "$sample_sheet" | tee -a "$log"
echo | tee -a "$log"

echo "" | tee -a "$log"
{
        echo ">>>>>>>>>> PACKAGE VERSIONS <<<<<<<<<<"
        echo ""
        echo "> dorado    $(dorado --version 2>&1)"
        echo "> samtools  $(samtools --version | head -1 | awk '{print $NF}')"
#        echo "> NanoPlot  $(NanoPlot --version | awk '{print $NF}')"
	echo "> multiqc   $(multiqc --version | awk '{print $NF}')"
        echo "> pigz      $(pigz --version | awk '{print $NF}')"
        echo "> pod5      $(pod5 --version | awk '{print $NF}')"
        echo "> sequali   $(sequali --version)"
        echo "> jq        $(jq --version | awk -F '-' '{print $2}')"
        echo ""
} | tee -a "$log"

# separate input file into duplex parents (dx=-1), simplex (dx=0) and duplex (dx=1)
echo "Splitting $file based on the duplex (dx) tag..." | tee -a "$log"
total_cores=$(nproc --all)
cores=$((total_cores - 2))
simplex_only=false

# if files already exist don't split again (mostly for debug)
# Extract dx:1 (duplex)
if [[ ! -f "${root_path}/${filename}_duplex.bam" ]]; then
	samtools view -@ "$cores" -e '[dx] == 1' --output "${root_path}/${filename}_duplex.bam" -b "${root_path_temp}/$file"
	n_reads=$(samtools view -@ "$cores" -c "${root_path}/${filename}_duplex.bam")
	if (( n_reads == 0 )); then
		echo "No duplex reads detected." | tee -a "$log"
		echo "Switching to simplex-only demultiplexing." | tee -a "$log"
		simplex_only=true
	else
		echo "Extracted duplex reads from $file" | tee -a "$log"
	fi
else
	echo "Skipped: ${filename}_duplex.bam already exists." | tee -a "$log"
fi


# Extract dx:-1 (parents)
if [[ $simplex_only == false ]]; then
	if [[ ! -f "${root_path}/${filename}_parents.bam" ]]; then
		samtools view -@ "$cores" -e '[dx] == -1' --output "${root_path}/${filename}_parents.bam" -b "${root_path_temp}/$file"
		echo "Extracted duplex parent reads from $file" | tee -a "$log"
	else
		echo "Skipped: ${filename}_parents.bam already exists." | tee -a "$log"
	fi
else
	echo "Skipped duplex parent read extraction in simplex-only mode." | tee -a "$log"
fi


# Extract dx:0 (simplex)
if [[ ! -f "${root_path}/${filename}_simplex.bam" ]]; then
	samtools view -@ "$cores" -e '[dx] == 0' --output "${root_path}/${filename}_simplex.bam" -b "${root_path_temp}/$file"
	echo "Extracted simplex reads from $file" | tee -a "$log"
else
	echo "Skipped: ${filename}_simplex.bam already exists." | tee -a "$log"
fi

if [[ $force_classification == true ]]; then
	if [[ $simplex_only == true ]]; then
		echo "Simplex basecalled data detected — the --greedy parameter is not applicable in this mode." | tee -a "$log"
	else
		echo "Greedy mode on: Duplex reads will be classified using only one parent if the other is 'unclassified'." | tee -a "$log"
	fi
elif [[ $simplex_only == false ]]; then
	echo "Greedy mode off: If one of the two parent reads is 'unclassified', the associated duplex read will not be classified." | tee -a "$log"
fi
echo "" | tee -a "$log"

echo ">>>>>>>>>> DEMULTIPLEXING STEPS <<<<<<<<<<" | tee -a "$log"
echo "" | tee -a "$log"
echo "Demultiplexing simplex reads..." | tee -a "$log"

if [[ $both_ends == true ]]; then
	dorado demux \
		--kit-name "$kit_name" \
		--sample-sheet "$sample_sheet" \
		--barcode-both-ends \
		--verbose \
		--output-dir "${root_path}/ubam_files" \
		"${root_path}/${filename}_simplex.bam" 2> >(tee -a "$log" >&2)
else
	dorado demux \
                 --kit-name "$kit_name" \
                 --sample-sheet "$sample_sheet" \
                 --verbose \
                 --output-dir "${root_path}/ubam_files" \
                 "${root_path}/${filename}_simplex.bam" 2> >(tee -a "$log" >&2)
fi

# OLD: dorado demux output gives an hash prefix to files: (2991b72f-14d9-4a85-aab7-d648176e3853_sample5.bam, for example)
# From dorado v1.2.0: Match MinKNOW output structure from Dorado aligner or demux if output path defined
# From dorado v1.2.0: new file name structure: PBE31366_pass_[BARCODE ALIAS]_445edd93_00000000_0.bam
# I decided to remove them to only keep the barcode aliases
find "${root_path}/ubam_files" -name "*.bam" | while read -r f; do
    	base=$(basename "$f")
	parent_path=$(dirname "$f")
    	parent_dir=$(basename "$parent_path")

	if [[ "$parent_path" == "${root_path}/ubam_files" ]]; then
        	continue
    	fi

	# check for unclassified
	if [[ "$parent_dir" == "unclassified" ]] || [[ "$base" == *unclassified* ]]; then
        	echo "Moving unclassified file from $parent_dir..." | tee -a "$log"
        	mv "$f" "${root_path}/ubam_files/${run_name}_unclassified.bam"
        	continue
	fi

	# remove hash
	# the following line removes everything that is not an underscore "_" until the first "_" is met
	# depending on how ONT will change their file namings, this might not work in the future.
	newbase="${parent_dir}.bam"

	echo "Flattening: $(basename "$f") -> $newbase" | tee -a "$log"
	mv "$f" "${root_path}/ubam_files/$newbase"
done

# Clean up empty Dorado-created directories
find "${root_path}/ubam_files" -maxdepth 10 -type d -empty -delete

# formatting log file (remove progress lines created by demux function)
tmpfile=$(mktemp) && tr -d '\r' < "$log" | sed -E '/Processed [0-9]+ reads/ d; s/> Output records written: [0-9]+//g' > "$tmpfile" && mv "$tmpfile" "$log"

if [[ $simplex_only == false ]]; then
	echo "" | tee -a "$log"
	echo "+----------------------------------------------+" | tee -a "$log"
	echo "|    Starting duplex read demultiplexing...    |" | tee -a "$log"
	echo "+----------------------------------------------+" | tee -a "$log"
	echo "" | tee -a "$log"

	echo "Demultiplexing duplex parent reads..." | tee -a "$log"

	# demultiplexing parent reads with sample sheet
	if [[ $both_ends == true ]]; then
	        dorado demux "${root_path}/${filename}_parents.bam" \
			--kit-name "$kit_name" \
			--sample-sheet "$sample_sheet" \
			--barcode-both-ends \
			--verbose \
			--output-dir "${root_path}/demux_files/parents" 2> >(tee -a "$log" >&2)
	else
		dorado demux "${root_path}/${filename}_parents.bam" \
                        --kit-name "$kit_name" \
                        --sample-sheet "$sample_sheet" \
                        --verbose \
                        --output-dir "${root_path}/demux_files/parents" 2> >(tee -a "$log" >&2)
	fi
	# formatting log file (remove progress lines created by demux function)
	tmpfile=$(mktemp) && tr -d '\r' < "$log" | sed -E '/Processed [0-9]+ reads/ d; s/> Output records written: [0-9]+//g' > "$tmpfile" && mv "$tmpfile" "$log"

	# remove hash prefix
        find "${root_path}/demux_files/parents" -name "*.bam" | while read -r f; do
		parent_dir=$(basename "$(dirname "$f")")
                mv "$f" "${root_path}/demux_files/parents/${parent_dir}.bam"
        done

        # Clean up empty folders
        #find "${root_path}/demux_files/parents" -type d -empty -delete

	# regroup all parent reads into a single .BAM file
	samtools cat -o "${root_path}/temp/${filename}_parents_demux_merged.bam" "${root_path}/demux_files/parents/"*.bam
	rm -r "${root_path}/demux_files/parents"

	# Associate barcode to duplex read
	echo "Attributing barcodes to duplex reads based on their simplex parent reads..." | tee -a "$log"

	# extracting duplex ids
	samtools view -@ "$cores" "${root_path}/${filename}_duplex.bam" | cut -f1 > "${root_path}/temp/duplex_ids.txt"

	# extract parent read ids and barcodes
	declare -A barcode_map
        # for performance, we load in memory
	while read -r id bc; do
		barcode_map["$id"]="$bc"
	done < <(samtools view -@ "$cores" "${root_path}/temp/${filename}_parents_demux_merged.bam" |
			awk '{
	        		read_id = $1
	        		barcode = "BC:Z:unclassified"
			        for (i = 12; i <= NF; i++) {
					if ($i ~ /^BC:Z:/) {
			                	barcode = $i
			                	break
					}
				}
				print read_id "\t" barcode
			}'
		)
	# make a buffer array to store output in memory instead of writing file at each iteration which slows down the process
	buffer=()
	count=0
        total_reads=$(wc -l < "${root_path}/temp/duplex_ids.txt")
	# could rewrite all in awk for performance - check later
	while IFS=";" read -r read1 read2; do
		count=$((count+1))
		# update each 1000 reads, for performance
		if (( count % 1000 == 0 )); then
			percent=$(( 100 * count / total_reads ))
			echo -ne "Progress: ${percent}% (${count} reads/${total_reads} reads)	\r"
		fi
		barcode1="${barcode_map[$read1]}"
		barcode2="${barcode_map[$read2]}"
		if [[ -z "$barcode1" || -z "$barcode2" ]]; then
			duplex_barcode="BC:Z:unclassified"
			# echo -e "${read1};${read2}\t${duplex_barcode}" >> "${root_path}/temp/duplex_barcodes.txt"
			buffer+=("${read1};${read2}"$'\t'"${duplex_barcode}")
			continue
		fi

		# Assign a barcode to the duplex read
		if [[ "$barcode1" == "$barcode2" && -n "$barcode1" ]]; then # Overkill second condition but we never know
			duplex_barcode="$barcode1"
		elif [[ "$barcode1" == "BC:Z:unclassified" || "$barcode2" == "BC:Z:unclassified" ]]; then
			if $force_classification; then
				if [[ "$barcode1" != "BC:Z:unclassified" ]]; then
					duplex_barcode="$barcode1"
				elif [[ "$barcode2" != "BC:Z:unclassified" ]]; then
					duplex_barcode="$barcode2"
				else
					duplex_barcode="BC:Z:unclassified" # Overkill condition once again because already covered but it's ok.
				fi
			else
				duplex_barcode="BC:Z:unclassified"
			fi
		else
	    		# barcode1 != barcode2 AND none are "BC:Z:unclassified"
	    		duplex_barcode="BC:Z:false_duplex"
		fi
		# echo -e "${read1};${read2}\t${barcode1};${barcode2}\t${duplex_barcode}"
		buffer+=("${read1};${read2}"$'\t'"${duplex_barcode}")
	done < "${root_path}/temp/duplex_ids.txt"
	printf "%s\n" "${buffer[@]}" > "${root_path}/temp/duplex_barcodes.txt"
	echo -e "\nDone. Processed ${count} reads."

	echo "" | tee -a "$log"
	echo "Updating duplex read BAM file metadata with barcode information..." | tee -a "$log"

	samtools view -@ "$cores" -h "${root_path}/${filename}_duplex.bam" | \
	awk -v barcode_file="${root_path}/temp/duplex_barcodes.txt" '
	BEGIN {
		FS = OFS = "\t"
		# read barcode mapping into memory (performance)
		while ((getline < barcode_file) > 0) {
			split($0, arr, "\t")
			# arr[1] is the duplex read_id and arr[2] is the barcode
	        	bc[arr[1]] = arr[2]
		}
	}
	{
		if ($0 ~ /^@/) {
			# pass the header
	        	print $0
	    	} else {
	        	read_id = $1
	        	if (read_id in bc) {
				print $0, bc[read_id]
	        	} else {
	            		print $0, "BC:Z:unclassified"
	        	}
	    	}
	}' | samtools view -b -o "${root_path}/temp/raw_duplex_tagged.bam"

	echo "+----------------------------------------------+" | tee -a "$log"
	echo "|                     Done                     |" | tee -a "$log"
	echo "+----------------------------------------------+" | tee -a "$log"
	echo "" | tee -a "$log"
	echo "+----------------------------------------------+" | tee -a "$log"
	echo "|          False Duplex Read Handling          |" | tee -a "$log"
	echo "+----------------------------------------------+" | tee -a "$log"

	echo "Identified false duplex reads are discarded, and their corresponding parent simplex reads are returned to the read pool." | tee -a "$log"

	# false duplex reads detected by parent reads barcodes
	samtools view -@ "$cores" -e '[BC] == "false_duplex"' "${root_path}/temp/raw_duplex_tagged.bam" | cut -f1 > "${root_path}/temp/false_duplex_ids_demux.txt"
	####

	# false duplex reads detected by non unique simplex parent read ids
	awk -F';' '{print $1; print $2}' "${root_path}/temp/duplex_ids.txt" | sort | uniq -c | awk '$1 > 1' > "${root_path}/temp/reused_parents.txt"
	awk '{print $2}' "${root_path}/temp/reused_parents.txt" > "${root_path}/temp/reused_ids.txt"
	####

	if [[ ! -s "${root_path}/temp/reused_ids.txt" || ! -s "${root_path}/temp/false_duplex_ids_demux.txt" ]]; then
		if [[ -s "${root_path}/temp/reused_ids.txt" ]]; then
			grep -Ff "${root_path}/temp/reused_ids.txt" "${root_path}/temp/duplex_ids.txt" > "${root_path}/temp/false_positive_duplex.txt"
			sort -u "${root_path}/temp/false_positive_duplex.txt" > "${root_path}/temp/all_unique_false_positive_duplex_ids.txt"
		else
			sort -u "${root_path}/temp/false_duplex_ids_demux.txt" > "${root_path}/temp/all_unique_false_positive_duplex_ids.txt"
		fi
	else
		grep -Ff "${root_path}/temp/reused_ids.txt" "${root_path}/temp/duplex_ids.txt" > "${root_path}/temp/false_positive_duplex.txt"
		cat "${root_path}/temp/false_duplex_ids_demux.txt" "${root_path}/temp/false_positive_duplex.txt" | sort -u > "${root_path}/temp/all_unique_false_positive_duplex_ids.txt"
	fi


	# clean demultiplexed duplex reads from false positive reads
	samtools view -@ "$cores" -N ^"${root_path}/temp/all_unique_false_positive_duplex_ids.txt" --output "${root_path}/temp/duplex_tagged.bam" "${root_path}/temp/raw_duplex_tagged.bam"
	all_raw_reads=$(samtools view -@ "$cores" -c "${root_path}/temp/raw_duplex_tagged.bam")
	clean_reads=$(samtools view -@ "$cores" -c "${root_path}/temp/duplex_tagged.bam")
	removed_duplex_reads=$((all_raw_reads - clean_reads))
	echo "Removed ${removed_duplex_reads} false positive duplex reads" | tee -a "$log"

	# get all parents present in false positive duplex reads
	awk -F';' '{print $1; print $2}' "${root_path}/temp/all_unique_false_positive_duplex_ids.txt" | sort -u > "${root_path}/temp/unique_reads.txt"

	# extract parent reads to reintroduce them in all reads
	samtools view -N "${root_path}/temp/unique_reads.txt" --output "${root_path}/temp/parents_to_reintroduce_raw.bam" "${root_path}/temp/${filename}_parents_demux_merged.bam"

	# change dx tag from -1 to 0
	samtools view -h "${root_path}/temp/parents_to_reintroduce_raw.bam" | \
		awk '{if ($0 ~ /^@/) {print} else {gsub("dx:i:-1", "dx:i:0"); print}}' | \
		samtools view -b -o "${root_path}/temp/parents_to_reintroduce.bam"
	n_parent_reads=$(samtools view -c "${root_path}/temp/parents_to_reintroduce.bam")
	echo "Reintroducing ${n_parent_reads} parent reads as simplex reads"  | tee -a "$log"

	# this part we could also merge parent and duplex and run 'dorado demux' once but have to check which one is faster - check later
	# split parent reads into barcode-specific bams
	dorado demux "${root_path}/temp/parents_to_reintroduce.bam" \
		--output-dir "${root_path}/demux_files/parents_to_reintroduce" \
		--no-classify \
		--verbose 2> >(tee -a "$log" >&2)

	# remove hash prefix
	for f in "${root_path}/demux_files/parents_to_reintroduce/"*.bam; do
    		base=$(basename "$f")
    		newbase=$(echo "$base" | sed 's/^[^_]*_//')
    		if [[ "$base" != "$newbase" ]]; then
        		mv "$f" "${root_path}/demux_files/parents_to_reintroduce/$newbase"
		fi
	done
	# split duplex reads into barcode-specific bams
	echo "Separating duplex reads into barcode-specific BAM files" | tee -a "$log"
	dorado demux "${root_path}/temp/duplex_tagged.bam" \
		--output-dir "${root_path}/demux_files/duplex" \
		--no-classify \
		--verbose 2> >(tee -a "$log" >&2)

	# remove hash prefix
	for f in "${root_path}/demux_files/duplex/"*.bam; do
		base=$(basename "$f")
    		newbase=$(echo "$base" | sed 's/^[^_]*_//')
    		if [[ "$base" != "$newbase" ]]; then
        		mv "$f" "${root_path}/demux_files/duplex/$newbase"
		fi
	done

	# formatting log file (remove progress lines created by demux function)
	tmpfile=$(mktemp) && tr -d '\r' < "$log" | sed -E '/Processed [0-9]+ reads/ d; s/> Output records written: [0-9]+//g' > "$tmpfile" && mv "$tmpfile" "$log"

	echo "Merging reads by barcode" | tee -a "$log"

	# this is like temporary folder for debugging
	mkdir -p "${root_path}/simplex_barcode_bams/"

	for simplex_bam in "${root_path}/ubam_files/"*.bam; do

		[[ "$simplex_bam" == *unclassified* ]] && continue

		simplex_file_name=$(basename "$simplex_bam" .bam)

		if [[ "$simplex_file_name" =~ barcode[0-9]{2} ]]; then
			barcode="${BASH_REMATCH[0]}"
		else
			barcode="$simplex_file_name"
		fi
		duplex_bam=$(find "${root_path}/demux_files/duplex/" -type f -name "*${barcode}.bam")
		parent_bam=$(find "${root_path}/demux_files/parents_to_reintroduce/" -type f -name "*${barcode}.bam")
		output_bam="${root_path}/ubam_files/${run_name}_${barcode}/${barcode}_final.bam" # change final when we are sure everything is ok

		mkdir -p "${root_path}/fastq_files/${run_name}_${barcode}"
		mkdir -p "${root_path}/ubam_files/${run_name}_${barcode}"

		merge_inputs=("$simplex_bam")

		if [[ -f "$duplex_bam" ]]; then
			merge_inputs+=("$duplex_bam")
			echo "Merging ${simplex_bam} with ${duplex_bam}"
		fi
		if [[ -f "$parent_bam" ]]; then
			merge_inputs+=("$parent_bam")
			echo "Merging ${simplex_bam} with ${parent_bam}"
	    	fi
		echo -n "Merging ${barcode}..." | tee -a "$log"
	    	samtools cat -o "$output_bam" "${merge_inputs[@]}"
		mv "$simplex_bam" "${root_path}/simplex_barcode_bams/"
	    	for processed_bam in "${merge_inputs[@]:1}"; do
  			mv "$processed_bam" "${processed_bam%.bam}_done.bam"
		done
		echo "Done" | tee -a "$log"
		# logically at this point we should have only _final files in ubam_files and all non _final files in simplex_barcode_bams/
	done

	# do the same for unclassified
	echo -n "Merging unclassified simplex and duplex reads..." | tee -a "$log"
	output="${root_path}/ubam_files/${run_name}_unclassified_final.bam"
	input1="${root_path}/ubam_files/${run_name}_unclassified.bam"

	# check if input1 exists
	if [[ ! -f "$input1" ]]; then
		echo "Missing file: $input1"
		exit 1
	fi

	# find all *_unclassified.bam files under demux_files/
	mapfile -t input2 < <(find "${root_path}/demux_files/" -type f -name "*unclassified.bam")

	# run samtools cat
	samtools cat -o "$output" "$input1" "${input2[@]}"

	for processed_file in "${input2[@]}"; do
	  mv "$processed_file" "${processed_file%.bam}_done.bam"
	done

	mv "$input1" "${root_path}/simplex_barcode_bams/"
	echo "Done" | tee -a "$log"

	echo "+----------------------------------------------+" | tee -a "$log"
	echo "|                     Done                     |" | tee -a "$log"
	echo "+----------------------------------------------+" | tee -a "$log"
else
	for simplex_bam in "${root_path}/ubam_files/"*.bam; do
		# skip unclassified reads because we don't need to create a folder for this one
                [[ "$simplex_bam" == *unclassified* ]] && continue
		# skip if it's a directory. Just a check because dorado can create nested folders
		[[ -d "$simplex_bam" ]] && continue

		barcode=$(basename "$simplex_bam" .bam)
                output_bam="${root_path}/ubam_files/${run_name}_${barcode}/${barcode}.bam"

                mkdir -p "${root_path}/fastq_files/${run_name}_${barcode}"
                mkdir -p "${root_path}/ubam_files/${run_name}_${barcode}"

                mv "$simplex_bam" "$output_bam"
        done
fi

############################################################################
#                          SUBMISSION CREATION                             #
############################################################################



echo "" | tee -a "$log"
echo ">>>>>>>>>> SUBMISSION CREATION <<<<<<<<<<" | tee -a "$log"
echo "" | tee -a "$log"

find "${root_path}/ubam_files" -type f -name "*.bam" | while read bamfile; do
	bamname=$(basename "$bamfile")
	dirname=$(dirname "$bamfile")

	echo -n "Creating sequencing summary for ${bamname}..." | tee -a "$log"
	dorado summary "$bamfile" > "${root_path}/summaries/all/${bamname%.bam}_sequencing_summary.txt" 2>/dev/null
	echo "Done" | tee -a "$log"

	echo -n "Splitting ${bamname} by quality score (qscore = ${qscore})..." | tee -a "$log"
	# here you can change the qscore parameter if needed (also change the echo above to keep consistency in the log file)
	samtools view -e "[qs] >= $qscore" -@ "$cores" "$bamfile" --output "${bamfile%.bam}.pass.bam" --unoutput "${bamfile%.bam}.fail.bam" -O BAM
	echo "Done" | tee -a "$log"

	echo -n "Creating sequencing summaries for ${bamname%.bam}.pass and ${bamname%.bam}.fail..." | tee -a "$log"
        dorado summary "${bamfile%.bam}.pass.bam" > "${root_path}/summaries/pass/${bamname%.bam}.pass_sequencing_summary.txt" 2>/dev/null
	dorado summary "${bamfile%.bam}.fail.bam" > "${root_path}/summaries/fail/${bamname%.bam}.fail_sequencing_summary.txt" 2>/dev/null
        echo "Done" | tee -a "$log"

	# Change NanoPlot to Sequali...
	echo -n "Creating Sequali reports for ${bamname} and ${bamname%.bam}.pass..." | tee -a "$log"
	sequali "$bamfile" \
		--json "${bamname%.bam}_all.json" \
		--html "${bamname%.bam}_all.html" \
        	--outdir "${root_path}/QC_reports/${bamname%.bam}/sequali_all"

        sequali "${bamfile%.bam}.pass.bam" \
		--json "${bamname%.bam}_pass.json" \
		--html "${bamname%.bam}_pass.html" \
        	--outdir "${root_path}/QC_reports/${bamname%.bam}/sequali_pass"

#	echo -n "Creating NanoPlot for ${bamname} and ${bamname%.bam}.pass..." | tee -a "$log"
#	NanoPlot --summary "${root_path}/summaries/all/${bamname%.bam}_sequencing_summary.txt" \
#			--outdir "${root_path}/QC_reports/${bamname%.bam}/nanoplot_all" \
#			--prefix "${bamname%.bam}_all_" \
#			-t "$cores" --only-report
#
#	NanoPlot --summary "${root_path}/summaries/pass/${bamname%.bam}.pass_sequencing_summary.txt" \
#			--outdir "${root_path}/QC_reports/${bamname%.bam}/nanoplot_pass" \
#			--prefix "${bamname%.bam}_pass_" \
#			-t "$cores" --only-report
	echo "Done" | tee -a "$log"

	rm "$bamfile"
done

echo -n "Creating MultiQC report for all reads across all samples..." | tee -a "$log"
multiqc \
	$(find "${root_path}/QC_reports" -type d -name "sequali_all") \
	--outdir "${root_path}/QC_reports/multiqc_all" \
	--filename "all_reads_multiqc_report" \
	--force \
	2>&1 | tee -a "$log"
echo "Done" | tee -a "$log"

echo -n "Creating MultiQC report for pass reads across all samples..." | tee -a "$log"
multiqc \
	$(find "${root_path}/QC_reports" -type d -name "sequali_pass") \
	--outdir "${root_path}/QC_reports/multiqc_pass" \
	--filename "pass_reads_multiqc_report" \
	--force \
	2>&1 | tee -a "$log"
echo "Done" | tee -a "$log"

# make a sequencing summary for "all" and "all pass" reads
echo -n "Creating sequencing summaries for all reads and all pass reads..." | tee -a "$log"

pass_summaries=$(find "${root_path}/summaries/pass/" -type f -name "*.txt")
all_summaries=$(find "${root_path}/summaries/all/" -type f -name "*.txt")

first=1
while read -r txt_file; do
	if [[ $first -eq 1 ]]; then
		cat "$txt_file"
		first=0
	else
		tail -n +2 "$txt_file"
	fi
done <<< "$pass_summaries" > "${root_path}/summaries/pass/${run_name}_all_pass_reads_sequencing_summary.txt"

first=1
while read -r txt_file; do
        if [[ $first -eq 1 ]]; then
                cat "$txt_file"
                first=0
        else
                tail -n +2 "$txt_file"
        fi
done <<< "$all_summaries" > "${root_path}/summaries/all/${run_name}_all_reads_sequencing_summary.txt"

echo "Done" | tee -a "$log"

mapfile -t all_bams < <(find "${root_path}/ubam_files" -type f -name "*.bam")
if [[ ${#all_bams[@]} -eq 0 ]]; then
	echo "Error: No BAM files found in ubam_files." >&2
	exit 1
fi

mapfile -t pass_bams < <(find "${root_path}/ubam_files" -type f -name "*.pass.bam")
if [[ ${#pass_bams[@]} -eq 0 ]]; then
	echo "Error: No pass BAM files found in ubam_files." >&2
	exit 1
fi

temp_pass_bam="${root_path}/temp/all_pass_reads.bam"
temp_all_bam="${root_path}/temp/all_reads.bam"
samtools cat "${all_bams[@]}" -o "$temp_all_bam"
samtools cat "${pass_bams[@]}" -o "$temp_pass_bam"

echo -n "Creating Sequali reports for all reads and all pass reads..." | tee -a "$log"
sequali "$temp_all_bam" \
	--json "${run_name}_all_reads.json" \
	--html "${run_name}_all_reads.html" \
        --outdir "${root_path}/QC_reports/${run_name}_all_reads/sequali_all"

sequali "$temp_pass_bam" \
	--json "${run_name}_all_pass_reads.json" \
	--html "${run_name}_all_pass_reads.html" \
        --outdir "${root_path}/QC_reports/${run_name}_all_reads/sequali_pass"

#echo -n "Creating NanoPlot for all reads and all pass reads..." | tee -a "$log"
#NanoPlot --summary "${root_path}/summaries/all/${run_name}_all_reads_sequencing_summary.txt" \
#                --outdir "${root_path}/QC_reports/${run_name}_all_reads/nanoplot_all" \
#                --prefix "${run_name}_all_reads_" \
#                -t "$cores" --only-report

#NanoPlot --summary "${root_path}/summaries/pass/${run_name}_all_pass_reads_sequencing_summary.txt" \
#                --outdir "${root_path}/QC_reports/${run_name}_all_reads/nanoplot_pass" \
#                --prefix "${run_name}_all_pass_reads_" \
#                -t "$cores" --only-report

echo "Done" | tee -a "$log"


find "${root_path}/ubam_files" -type f -name "*.bam" | while read bamfile_2; do
	bamname_2=$(basename "$bamfile_2")
	outfastq=$(echo "$bamfile_2" | sed "s|\(.*\)ubam_files|\1fastq_files|")
	outfastq="${outfastq%.bam}.fq"

	echo -n "Creating compressed fastq file for ${bamname_2}..." | tee -a "$log"
        samtools fastq -@ "$cores" "$bamfile_2" > "$outfastq" 2>/dev/null
	pigz "$outfastq"
        echo "Done" | tee -a "$log"
done

############################################################################
#				STATISTICS	    	 		   #
############################################################################
echo "" | tee -a "$log"
echo ">>>>>>>>>> STATISTICS <<<<<<<<<<" | tee -a "$log"
echo "" | tee -a "$log"

if [[ $simplex_only == false ]]; then
	duplex_read_count=$(samtools view -c -@ "$cores" "${root_path}/temp/duplex_tagged.bam")
        classified_read_count=$(samtools view -c -@ "$cores" -e '[BC]!="unclassified"' "${root_path}/temp/duplex_tagged.bam")
        percent_classified_duplex=$(( 100 * classified_read_count/duplex_read_count ))
        echo "${percent_classified_duplex}% of ${duplex_read_count} duplex reads are classified." | tee -a "$log"
        false_duplex=$(wc -l < "${root_path}/temp/all_unique_false_positive_duplex_ids.txt")
        echo "$false_duplex false positive duplex reads detected and removed. ${n_parent_reads} duplex parent reads reintroduced as simplex reads." | tee -a "$log"
fi

bash "$(dirname "$0")/get_stats.sh" "$temp_all_bam" | tee -a "$log"

bash "$(dirname "$0")/get_stats.sh" "$temp_pass_bam" | tee -a "$log"

############################################################################
#                               CLEANING                                   #
############################################################################
echo "" | tee -a "$log"
echo -n "Cleaning directory from temporary files..." | tee -a "$log"
rm -r "${root_path}/temp/"
rm -f "${root_path}/${filename}_simplex.bam"
rm -f "${root_path}/${filename}_duplex.bam"
rm -f "${root_path}/${filename}_parents.bam"
rm -rf "${root_path}/simplex_barcode_bams"
rm -rf "${root_path}/demux_files"
echo "Done" | tee -a "$log"
echo "" | tee -a "$log"
echo "Run finished at: $(date '+%d-%m-%Y %H:%M:%S')" | tee -a "$log"

{
        echo ""
        echo "╔════════════════════════════════════╗"
        echo "║       Demultiplexing done...       ║"
        echo "╚════════════════════════════════════╝"
        echo ""
} | tee -a "$log"

# END SCRIPT
