#!/bin/bash
set -e -o pipefail

on_exit () {
    echo "This script has exited in error (on line $1)"
}

trap 'on_exit $LINENO' ERR

########################################## CHECK DEPENDENCIES ###########################################

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
#	"NanoPlot"
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
				echo "- jq (conda install conda-forge::jq)"
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

#########################################################################################################
############################################## MAIN SCRIPT ##############################################

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> USER PROMPT <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

# set default values
qscore=10
show_legacy_models=false

# set number of cores as total-2
total_cores=$(nproc --all)
cores=$((total_cores - 2))

# iterate over command line parameters
while [[ $# -gt 0 ]]; do
        case "$1" in
                --qscore)
                        if [[ -z "$2" || "$2" == --* || ! "$2" =~ ^[0-9]+$ ]]; then
                                echo "Error: --qscore requires an integer value."
                                exit 1
                        fi
                        qscore="$2"
                        shift 2
                        ;;
                --legacy)
                        show_legacy_models=true
                        echo "Legacy mode activated — older models are now available."
                        shift
                        ;;
                *)
                        echo "Unknown option: $1"
                        exit 1
                        ;;
        esac
done

# here the script will automatically autofill 'p2sid00' but you can change it below by editing this part: -i "p2sid00"
read -e -i "p2sid00" -p "Enter the project name (e.g., p2sidXXXX): " run_name

while true; do
	read -ep "Enter the pod5 directory path: " input_path
    	pod5_directory=$(realpath -e "${input_path/#\~/$HOME}" 2>/dev/null || true)
    	if [[ -n "$pod5_directory" ]] && [[ -d "$pod5_directory" ]]; then
        	echo "Directory exists: $pod5_directory"
        	break
    	else
        	echo "Directory does not exist. Please try again."
    	fi
done

project_root_path=$(dirname "$pod5_directory")
submission_folder="${project_root_path}/SUP_basecalling_${run_name}"

# if the submission folder already exists, create a new one to avoid conflicts
if [[ -d "$submission_folder" ]]; then
        i=2
        while [[ -d "${submission_folder}_$i" ]]; do
                ((i++))
        done
        submission_folder="${submission_folder}_$i"
fi

mkdir -p "${submission_folder}/logs"
log="${submission_folder}/logs/log_basecalling_${run_name}_$(date '+%Y%m%d_%H%M%S').txt"

# Get models
model_list="$(dorado download --list-yaml | sed 's/ - /\n - /g')"

# Ask for simplex or duplex
PS3="Select a basecalling mode: "
select mode in simplex duplex; do
        if [[ -n "$mode" ]]; then
                echo "Basecalling mode selected: $mode"
                break
        else
                echo "Invalid selection. Try again."
        fi
done

# Format models as category:model
models=$(echo "$model_list" | awk '
	/^[a-z]+ models:/ {
		gsub(" models:","",$1);
		category=$1;
	}
	/^ - / {
		model=substr($0, 4);
		gsub(/"/, "",model);
		print category ":" model;
	}
')

PS3="Select accuracy mode: "
select accuracy in fast hac sup; do
	if [[ -n "$accuracy" ]]; then
		echo "Accuracy mode selected: $accuracy"
		break
	else
		echo "Invalid selection. Try again"
	fi
done

case "$mode" in
    simplex)
        models_sub=$(echo "$models" | grep "^simplex:" | grep "$accuracy")
        ;;
    duplex)
        # duplex basecaller requires simplex + stereo models
        models_sub=$(echo "$models" | grep "^simplex:" | grep "$accuracy")
        models_stereo=$(echo "$models" | grep "^stereo:")
        ;;
    *)
        echo "Error: $mode is not a valid mode."
        ;;
esac

model_names=$(echo "$models_sub" | sed 's/^[^:]*://')
if [[ "$mode" == "duplex" ]]; then
	model_stereo=$(echo "$models_stereo" | sed 's/^[^:]*://')
fi

# legacy mode activated shows all models in case you want to rebasecall using an old model for consistency.
if $show_legacy_models; then
	model_selection="$model_names"
	[[ -n "$model_stereo" ]] && model_stereo_selection="$model_stereo"
else
	# cool code line. It sorts all models by version and keep only the latest to avoid printing > 20 old models.
	model_selection=$(echo "$model_names" | sort -rV | awk -F '@' '!seen[$1]++')
	[[ -n "$model_stereo" ]] && model_stereo_selection=$(echo "$model_stereo" | sort -rV | awk -F '@' '!seen[$1]++')
fi

IFS=$'\n' read -r -d '' -a models_array < <(printf '%s\0' "$model_selection")
[[ -n "$model_stereo_selection" ]] && IFS=$'\n' read -r -d '' -a models_stereo_array < <(printf '%s\0' "$model_stereo_selection")

PS3="Choose a simplex model: "
select model in "${models_array[@]}"; do
	if [[ -n "$model" ]]; then
		echo "Model selected: $model"
		break
	else
		echo "Invalid selection. Try again."
	fi
done

while true; do
	read -ep "Do you want to basecall modified bases (5mC, 5hmC, 6mA...) (y/n): " ans_modif
	case "$ans_modif" in
		[Nn])
			echo "Got it! No modified bases basecalling."
			break
			;;
		[Yy])
			model_prefix="${model}_"
			models_sub_modif=$(echo "$models" | grep "^modification:" | grep "$accuracy")
			model_names_modif=$(echo "$models_sub_modif" | sed 's/^[^:]*://')
			variants=$(echo "$model_names_modif" | grep "^${model_prefix}")

			if [[ -z "$variants" ]]; then
				echo "No modified base variants available for $model."
				break
			fi

			# format variant list
			IFS=$'\n' read -r -d '' -a variants_array < <(printf '%s\0' "$variants")

			echo "Available modified base variants for $model:"
			for i in "${!variants_array[@]}"; do
				printf "%3d) %s\n" $((i+1)) "${variants_array[i]}"
			done

			# this part allows the selection of multiple variants
			read -ep "Enter the numbers of the variants you want to select (comma-separated, e.g. 1,3): " selected_indices
			selected_variants=()
			IFS=',' read -ra indices <<< "$selected_indices"
			for idx in "${indices[@]}"; do
				idx=$((idx-1))
				if (( $idx >= 0 && $idx < ${#variants_array[@]} )); then
					selected_variants+=("${variants_array[idx]}")
				else
					echo "Warning: index $((idx+1)) is invalid, skipping."
				fi
			done

			if [[ ${#selected_variants[@]} -eq 0 ]]; then
				echo "No valid variants selected. Skipping modified base basecalling."
			else
				echo "Selected variants: ${selected_variants[*]}"
			fi

			break
			;;
		*)
            		echo "Please enter y or n."
            		;;
	esac
done

# if duplex mode activated let the user choose a stereo model but only in legacy mode
# otherwise, there is only one model so the script picks it automatically without user prompt
if [[ "${#models_stereo_array[@]}" -gt 1 ]]; then
	PS3="Choose a stereo model for duplex basecalling: "
	if [[ "$mode" == "duplex" ]]; then
		select model_stereo in "${models_stereo_array[@]}"; do
			if [[ -n "$model_stereo" ]]; then
				echo "Stereo model selected: $model_stereo"
				break
			else
				echo "Invalid stereo model selection. Try again."
			fi
		done
	fi
else
	model_stereo="${models_stereo_array[0]}"
fi

# detect sequencing kit from pod5 metadata
# IDEA: pod5 file metadata can be used to output non trimmed raw files for duplex and either directly do the demultiplexing using the basecaller for simplex reads
# or format files so they are ready-to-use for the demux.sh script. Additionally, don't create a submission for multiplexed reads in this script (do it in demux.sh).
echo "Detecting sequencing kit..."
first_pod5_file=$(find "$pod5_directory" -type f -name "*.pod5" -printf "%s %p\n" | sort -n | head -n 1 | awk '{print $2}')

# Extract sequencing kit
kit_name=$(pod5 inspect debug "$first_pod5_file" | \
           awk '/^[ \t]*sequencing_kit:/ { print toupper($2) }')

# this should give us '1' for barcoded or '0' for non-barcode
is_barcoded=1
#is_barcoded=$(pod5 inspect debug "$first_pod5_file" | \
#              grep -o "'barcoding_enabled': *'[^']*'" | sed -E "s/.*'([^']+)'$/\1/")

if [[ -z "${kit_name:-}" ]]; then
	read -ep "The program was not able to detect the sequencing kit. Please enter a sequencing kit name (e.g. SQK-LSK114): " kit_name
	read -ep "Are the reads multiplexed (barcoded) ?" is_barcoded
else
	echo "Detected kit: $kit_name"
	echo "Barcoded status: $([ "${is_barcoded:-0}" = "0" ] && echo false || echo true)"
fi

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> END USER PROMPT <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> DOWNLOAD MODELS <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# create raw files for duplex mode only

tmp_models_dir=$(mktemp -d -t dorado_models_XXXX)

if [[ "$mode" == "simplex" ]]; then
	ubam_folder="${submission_folder}/ubam_files"
else
	ubam_folder="${submission_folder}/raw_ubam_files"
fi
mkdir -p "$ubam_folder"

echo "Downloading the selected model $model"
dorado download --model "$model" --models-directory "$tmp_models_dir"

if [[ ${#selected_variants[@]} -ne 0 ]]; then
	for var in "${selected_variants[@]}"; do
		dorado download --model "$var" --models-directory "$tmp_models_dir"
	done
fi

if [[ -n "$model_stereo" ]]; then
	dorado download --model "$model_stereo" --models-directory "$tmp_models_dir"
fi

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> END DOWNLOAD MODELS <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> START BASECALLING <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
{
	echo ""
  	echo "╔════════════════════════════════════╗"
  	echo "║        Starting basecalling...     ║"
  	echo "╚════════════════════════════════════╝"
  	echo ""
} | tee -a "$log"

{
        echo "Run started at: $(date '+%d-%m-%Y %H:%M:%S')"
        echo ""
        echo ">>>>>>>>>> INPUT PARAMETERS <<<<<<<<<<"
        echo ""
        echo "> Run name: ${run_name:-N/A}"
        echo "> Sequencing kit: ${kit_name:-N/A}"

	if [[ "${is_barcoded:-0}" = "0" ]]; then
		echo "> Barcoded status: false"
        else
            	echo "> Barcoded status: true"
        fi

        echo "> Selected mode: ${mode:-N/A}"
        echo "> Selected model: ${model:-N/A}"

        if [[ -n "${model_stereo:-}" ]]; then
            	echo "> Selected stereo model: $model_stereo"
        fi

	if [[ -n "${selected_variants+x}" ]] && [[ "${#selected_variants[@]}" -ne 0 ]]; then
    		echo "> Selected variants: ${selected_variants[*]}"
	fi

        if [[ "${is_barcoded:-0}" = "0" ]]; then
		echo "> Filtering reads using a Q${qscore:-0} qscore"
        fi

        if [[ "${show_legacy_models:-false}" = "true" ]]; then
		echo "> Legacy mode activated"
        fi
} | tee -a "$log"


echo "" | tee -a "$log"
{
	echo ">>>>>>>>>> PACKAGE VERSIONS <<<<<<<<<<"
	echo ""
	echo "> dorado    $(dorado --version 2>&1)"
	echo "> samtools  $(samtools --version | head -1 | awk '{print $NF}')"
	echo "> NanoPlot  $(NanoPlot --version | awk '{print $NF}')"
	echo "> pigz      $(pigz --version | awk '{print $NF}')"
	echo "> pod5      $(pod5 --version | awk '{print $NF}')"
	echo "> sequali   $(sequali --version)"
	echo "> jq        $(jq --version | awk -F '-' '{print $2}')"
	echo ""
} | tee -a "$log"

model_path="${tmp_models_dir}/${model}"
if [[ -n "${selected_variants[*]}" ]]; then
	selected_variants=("${selected_variants[@]/#/$tmp_models_dir/}")
	modified_models_arg=$(IFS=, ; echo "${selected_variants[*]}")
fi

# this is the core of the script, it initialize the basecalling using dorado
# simplex or duplex basecalling with possibility to do modified bases basecalling but only in simplex mode
dorado_args=("$model_path" "$pod5_directory" --models-directory "$tmp_models_dir" --recursive)

# modified bases
if [[ -n "${selected_variants[*]}" ]]; then
	dorado_args+=(--modified-bases-models "$modified_models_arg")
fi

# Add poly-A estimation for direct RNA simplex basecalling
# there is no duplex basecalling with direct RNA protocol as we never sequence the complementary read
if [[ "$model" =~ rna  && "$mode" != "duplex" ]]; then
	dorado_args+=(--estimate-poly-a)
fi

if [[ "$mode" == "simplex" ]]; then
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> SIMPLEX <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> SIMPLEX NO BARCODES <<<<<<<<<<<<<<<<<<<<<<<<<<<<<
	if [[ "$is_barcoded" -eq 0 ]]; then
		# simplex + not barcoded
		dorado basecaller "${dorado_args[@]}" | \
                	samtools view \
				-e "[qs] >= ${qscore}" - \
                        	--output "${ubam_folder}/${run_name}.pass.bam" \
                        	--unoutput "${ubam_folder}/${run_name}.fail.bam" \
				-O BAM
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
	else
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> SIMPLEX AND BARCODES <<<<<<<<<<<<<<<<<<<<<<<<<<<<<
		# simplex + barcoded
        	dorado basecaller "${dorado_args[@]}" \
			--no-trim > "${ubam_folder}/${run_name}_untrimmed.all.bam"

		rm -r "$tmp_models_dir"

		echo "Barcoded reads using ${kit_name} kit detected. To demultiplex basecalled ${run_name}_untrimmed.all.bam file, use 'demux.sh' script." | tee -a "$log"
		echo "" | tee -a "$log"
		echo "Run ended at: $(date '+%d-%m-%Y %H:%M:%S')" | tee -a "$log"

		echo "" | tee -a "$log"
		echo ">>>>>>>> BASECALLED POD5 FILES <<<<<<<<" >> "$log"
		echo "" >> "$log"
		find "$pod5_directory" -type f -name "*.pod5" -exec basename {} \; >> "$log"
		{
		  echo ""
		  echo "╔═══════════════════════════════════════╗"
		  echo "║     Basecalling done successfully     ║"
		  echo "╚═══════════════════════════════════════╝"
		  echo ""
		} | tee -a "$log"
		exit 0
	fi
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
else
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> DUPLEX <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
	# in duplex mode, the basecalling is the same for multiplexed and non-multiplexed data
	# as basecaller in duplex mode doesn't automatically trim the reads
	# if they add automatical trimming, add --no-trim to the command below
	dorado duplex "${dorado_args[@]}" > "${ubam_folder}/${run_name}_raw.bam"

	# non-barcoded reads will enter a standard workflow:
	# basecalling -> trimming raw bam file -> remove duplex parent reads -> filter by qscore
	# then we can create the submission folder
	if [[ "$is_barcoded" -eq 0 ]]; then
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> DUPLEX NO BARCODES <<<<<<<<<<<<<<<<<<<<<<<<<<<<<
		echo "Starting trimming..."
		dorado trim "${ubam_folder}/${run_name}_raw.bam" --sequencing-kit "$kit_name" > "${ubam_folder}/${run_name}_raw_trimmed.bam"

		echo -n "Removing duplex parent reads..."
		samtools view -@ "$cores" -e '[dx] == 0 || [dx] == 1' -o "${ubam_folder}/${run_name}_clean_trimmed.bam" -b "${ubam_folder}/${run_name}_raw_trimmed.bam"
		echo "Done"

		echo -n "Qscore filtering..."
		clean_ubam_folder="${ubam_folder/raw_/}"
		mkdir -p "$clean_ubam_folder"
		samtools view \
			-@ "$cores" \
			-e "[qs] >= ${qscore}" "${ubam_folder}/${run_name}_clean_trimmed.bam" \
	                --output "${clean_ubam_folder}/${run_name}.pass.bam" \
	                --unoutput "${clean_ubam_folder}/${run_name}.fail.bam" \
			-O BAM
		echo "Done"
		ubam_folder="$clean_ubam_folder"

	# if reads are barcoded, this script stops as we need raw, untrimmed, and unfiltered data as input data for demux.sh script
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
	else
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> DUPLEX AND BARCODES <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
		rm -r "$tmp_models_dir"

                echo "Barcoded reads using ${kit_name} kit detected. To demultiplex basecalled ${run_name}_raw.bam file, use 'demux.sh' script." | tee -a "$log"
                echo "" | tee -a "$log"
                echo "Run ended at: $(date '+%d-%m-%Y %H:%M:%S')" | tee -a "$log"

                echo "" | tee -a "$log"
                echo ">>>>>>>> BASECALLED POD5 FILES <<<<<<<<" >> "$log"
                echo "" >> "$log"
                find "$pod5_directory" -type f -name "*.pod5" -exec basename {} \; >> "$log"
                {
                  echo ""
                  echo "╔═══════════════════════════════════════╗"
                  echo "║     Basecalling done successfully     ║"
                  echo "╚═══════════════════════════════════════╝"
                  echo ""
                } | tee -a "$log"
                exit 0
	fi
#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
fi

############## CREATE SUBMISSION ##############

mkdir -p "${submission_folder}/fastq_files"
mkdir -p "${submission_folder}/summaries"
mkdir -p "${submission_folder}/QC_outputs/${run_name}_all_reads"
mkdir -p "${submission_folder}/QC_outputs/${run_name}_pass_reads"
mkdir -p "${submission_folder}/temp"

# create fastq files, QC reports and summaries
find "$ubam_folder" -type f -name "*.bam" | while read -r bam_file; do
	bamfile_name=$(basename "$bam_file" .bam)
	# convert bams to compressed fastq files (.fq.gz)
	samtools fastq -@ "$cores" "$bam_file" > "${submission_folder}/fastq_files/${bamfile_name}.fq"
	pigz "${submission_folder}/fastq_files/${bamfile_name}.fq"
	if [[ "$bamfile_name" == *".pass"* ]]; then
		sequali "$bam_file" \
			--json "${bamfile_name}.json" \
			--html "${bamfile_name}.html" \
			--outdir "${submission_folder}/QC_outputs/${run_name}_pass_reads"
	fi
	dorado summary "$bam_file" > "${submission_folder}/summaries/sequencing_summary_${bamfile_name}.txt"
done

temp_all_reads="${submission_folder}/temp/${run_name}_all_reads.bam"
samtools cat "${ubam_folder}"/*.pass.bam "${ubam_folder}"/*.fail.bam -o "$temp_all_reads"

dorado summary "$temp_all_reads" > "${submission_folder}/summaries/sequencing_summary_${run_name}.all.txt"

sequali "$temp_all_reads" \
	--json "${run_name}_all.json" \
	--html "${run_name}_all.html" \
	--outdir "${submission_folder}/QC_outputs/${run_name}_all_reads"

############## SUMMARY FILE STATISTICS ##############

echo ">>>>>>>>>>> STATS & METRICS <<<<<<<<<<<" >> "$log"
echo "" >> "$log"

# changed logic to only open the sequencing summary file less times than before -> faster
awk -F'\t' '
NR==1 {
	for (i=1; i<=NF; i++) {
		if ($i=="mean_qscore_template") qcol=i;
	        if ($i=="sequence_length_template") lencol=i;
	        if ($i=="channel") chcol=i;
	}

	if (!qcol || !lencol || !chcol) {
        	print "Error: required column not found in header." > "/dev/stderr";
		exit 1;
    	}
	next
}

{
	q = $qcol;
	len = $lencol;
	ch = $chcol;

	qsum += 10^(-q/10);
	count++;

	if (len > 40000) over40k++;
	if (len > 100000) over100k++;
	channels[ch]++;
}

END {
	if (count > 0) {
        	meanQ = -10 * log(qsum / count) / log(10);
        	printf "Mean read quality: %.1f\n", meanQ;
	}

	printf "Number of reads > 40kb: %d reads\n", over40k;
	printf "Number of reads > 100kb: %d reads\n", over100k;
	printf "Active channels: %d\n", length(channels);
}
' "${submission_folder}/summaries/sequencing_summary_${run_name}.all.txt" >> "$log"

awk -F'\t' '
NR==1 {
	for (i=1; i<=NF; i++) {
		if ($i=="mean_qscore_template") qcol=i;
    	}
	if (!qcol) {
		print "Error: mean_qscore_template column not found." > "/dev/stderr";
		exit 1;
	}
	next
}
{
	print $qcol
}
' "${submission_folder}/summaries/sequencing_summary_${run_name}.all.txt" | sort -n \
| awk '{
	count[NR] = $1
}
END {
	if (NR == 0) {
		print "Median read quality: NA"
                exit
        }

        if (NR % 2 == 1) {
                printf "Median read quality: %.1f\n", count[(NR + 1) / 2]
        } else {
                printf "Median read quality: %.1f\n", (count[NR / 2] + count[NR / 2 + 1]) / 2
        }
}' >> "$log"

# total number of bases, mean and median read length, and N50
jq -r '.summary as $s | .sequence_length_distribution as $d |
	[$s.total_bases, $s.mean_length, $d.n50, $d.q50] | @tsv' \
	"${submission_folder}/QC_outputs/${run_name}_all_reads/${run_name}_all.json" |
awk -F'\t' '{
	printf "Total bases: %.2f Gb\n", $1/1e9
	printf "Mean read length: %.1f bases\n", $2
	printf "Read length N50: %.0f bases\n", $3
	printf "Median read length: %.0f bases\n", $4
}' >> "$log"

# number of pass reads
jq '.summary["total_reads"]' "${submission_folder}/QC_outputs/${run_name}_pass_reads/${run_name}.pass.json" | awk '{printf "Total pass reads: %.2f M\n", $1/1e6}' >> "$log"

# compute nubmer of failed reads
samtools view -c -@ "$cores" "${ubam_folder}/${run_name}.fail.bam" | awk '{printf "Total fail reads: %.2f M\n", $1/1e6}' >> "$log"

# print 5 longest reads with their associated qscores for all and pass reads
echo "Top 5 longest reads formated as: length qscore" >> "$log"
echo "for all reads:" >> "$log"
awk -F'\t' '
NR==1 {
	for (i=1; i<=NF; i++) {
        	if ($i=="sequence_length_template") lencol=i;
        	if ($i=="mean_qscore_template") qcol=i;
    	}

	if (!lencol || !qcol) {
        	print "Error: required column not found in header." > "/dev/stderr";
        	exit 1;
    	}
	next
}

{
	print $lencol, $qcol
}
' "${submission_folder}/summaries/sequencing_summary_${run_name}.all.txt" \
| sort -k1,1nr \
| awk 'NR<=5' >> "$log"

echo "for pass reads:" >> "$log"

awk -F'\t' '
NR==1 {
        for (i=1; i<=NF; i++) {
                if ($i=="sequence_length_template") lencol=i;
                if ($i=="mean_qscore_template") qcol=i;
        }

        if (!lencol || !qcol) {
                print "Error: required column not found in header." > "/dev/stderr";
                exit 1;
        }
        next
}

{
        print $lencol, $qcol
}
' "${submission_folder}/summaries/sequencing_summary_${run_name}.pass.txt" \
| sort -k1,1nr \
| awk 'NR<=5' >> "$log"

############## CLEAN FILES AND END LOG FILE ##############

rm -r "${submission_folder}/temp"
rm -r "$tmp_models_dir"

echo "" | tee -a "$log"
echo "Run ended at: $(date '+%d-%m-%Y %H:%M:%S')" | tee -a "$log"

echo "" | tee -a "$log"
echo ">>>>>>>> BASECALLED POD5 FILES <<<<<<<<" >> "$log"
echo "" >> "$log"
find "$pod5_directory" -type f -name "*.pod5" -exec basename {} \; >> "$log"
{
  echo ""
  echo "╔═══════════════════════════════════════╗"
  echo "║     Basecalling done successfully     ║"
  echo "╚═══════════════════════════════════════╝"
  echo ""
} | tee -a "$log"

# END SCRIPT
