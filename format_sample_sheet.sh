#!/bin/bash
set -o pipefail



############################################### CHECK ENVIRONMENT AND DEPENDENCIES #######################################

echo "--------------------------------------------------"
# Check if conda environment is activated
if [[ -z "$CONDA_PREFIX" ]] || [[ "$CONDA_DEFAULT_ENV" == "base" ]]; then
        echo "Please activate your Conda environment first."
        echo "-> conda activate basecaller"
        exit 1
fi

# Define dependencies
declare -a dependencies_list=(
        "pod5"
        "jq"
)

echo "Checking for dependencies in the current conda environment $CONDA_PREFIX"

declare -a missing_dependencies

# Check for missing dependencies
for dep in "${dependencies_list[@]}"; do
        dep_path="$CONDA_PREFIX/bin/$dep"
        if [ ! -x "$dep_path" ]; then
                missing_dependencies+=("$dep")
        fi
done

if [ ${#missing_dependencies[@]} -gt 0 ]; then
        echo "The following dependencies are missing:"
        for dep in "${missing_dependencies[@]}"; do
                case "$dep" in
                        "pod5")
                                echo "- pod5 (pip install pod5)"
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
echo "--------------------------------------------------"
##########################################################################################################################

############################################### MAIN SCRIPT ##############################################################

# get barcodes - samples file
if [[ -z "$1" ]]; then
        echo "Script usage: ./format_sample_sheet.sh <barcode_aliases.txt> "
	echo ""
	echo "Where samples.txt contain sample names associated to barcodes formatted as 'barcode01;sample_name'"
	echo -e "barcode01;sample_name1\nbarcode02;sample_name2\nbarcode03;hek293\nbarcode04;HeLa"
        exit 1
elif [[ ! -f "$1" ]]; then
        echo "Error: '$1' is not a file or file not found."
        exit 1
elif [[ "$1" != *.txt ]]; then
        echo "Error: '$1' is not a .txt file."
        exit 1
fi

user_sample_sheet="$1"

echo "This is a typical sample sheet structure: "
cat <<'EOF'
+----------------+-------------------+-------------+-----------+---------+
| experiment_id  | kit               | position_id | barcode   | alias   |
+----------------+-------------------+-------------+-----------+---------+
| SOL00xx        | SQK-NBD114-24     | P2S-00697-A | barcode01 | sample1 |
| SOL00xx        | SQK-NBD114-24     | P2S-00697-A | barcode02 | sample2 |
| SOL00xx        | SQK-NBD114-24     | P2S-00697-A | barcode03 | sample3 |
| SOL00xx        | SQK-NBD114-24     | P2S-00697-A | barcode04 | sample4 |
+----------------+-------------------+-------------+-----------+---------+
EOF

kit_name=""
experiment_name=""
position_id=""

while true; do
	read -ep "Auto-detect run metadata from a POD5 file/folder? (y/n): " ans_auto
	case "$ans_auto" in
		[Nn])
			# manual inputs
			read -ep "Enter the name of the sequencing kit (e.g., SQK-NBD114-24): " kit_name
			# you can change '-i "SOL00"' with whatever you want it to pre-fill the user field
			read -e -i "SOL00" -p "Enter the experiment name (e.g., SOL0012): " experiment_name

			PS3="Select a position ID corresponding to the FC position on the P2Solo: "
			select pos in A B; do
				if [[ -n "$pos" ]]; then
					position_id="P2S-00697-$pos"
					break
				else
					echo "Invalid selection. Try again."
				fi
			done
			break
			;;

		[Yy])
			while true; do
				read -ep "Enter the POD5 file path or directory path: " input_path

				resolved_path=$(realpath -e "${input_path/#\~/$HOME}" 2>/dev/null || true)

				if [[ -n "$resolved_path" ]]; then
					if [[ -f "$resolved_path" && "$resolved_path" == *.pod5 ]]; then
						pod5_file="$resolved_path"
					elif [[ -d "$resolved_path" ]]; then
						pod5_file=$(find "$resolved_path" \( -type f -o -type l \) -name "*.pod5" | head -n 1)
					else
						pod5_file=""
					fi

					if [[ -z "$pod5_file" ]]; then
						echo "No valid .pod5 files found at that target. Please try again."
					else
						echo "Using file for detection: $pod5_file"
						echo "Parsing metadata..."

						# we cache the inspect output to avoid running it multiple times
						inspect_output=$(pod5 inspect debug "$pod5_file" 2>/dev/null)

						# extract values
						kit_name=$(echo "$inspect_output" | grep -E "sequencing_kit:" | head -n 1 | awk '{print toupper($2)}')
						experiment_name=$(echo "$inspect_output" | grep -E "experiment_name:" | head -n 1 | awk '{print $2}')
						position_id=$(echo "$inspect_output" | grep -E "sequencer_position:" | head -n 1 | awk '{print $2}')

						# fallback checks for empty variables

						# kit name fallback
						if [[ -z "$kit_name" ]]; then
							read -ep "Could not autodetect kit. Please enter kit name: " kit_name
						else
							echo "Detected kit: $kit_name"
						fi

						# exp name fallback
						if [[ -z "$experiment_name" ]]; then
							read -e -i "SOL00" -p "Could not autodetect experiment name. Please enter it (e.g., SOL0012): " experiment_name
						else
							echo "Detected experiment: $experiment_name"
						fi

						# flow cell position fallback
						if [[ -z "$position_id" ]]; then
							echo "Could not autodetect sequencer position."
							PS3="Select a position ID corresponding to the FC position on the P2Solo: "
							select pos in A B; do
								if [[ -n "$pos" ]]; then
									position_id="P2S-00697-$pos"
									break
								else
									echo "Invalid selection. Try again."
								fi
							done
						else
							echo "Detected sequencer position: $position_id"
						fi

						break 2 # break out of both loops since we have our answers
					fi
				else
					echo "Path does not exist. Please try again."
				fi
			done
			;;
		*)
			echo "Please enter y or n."
			;;
	esac
done

echo "---------------------------------------"
echo "Configuration Ready:"
echo "Kit Name:            $kit_name"
echo "Experiment Name:     $experiment_name"
echo "Sequencer Position:  $position_id"
echo "---------------------------------------"

# get current directory to sacve sample sheet
current_directory="$(pwd)"

sort -t';' -k1,1 "$user_sample_sheet" | \
awk -F';' -v OFS=',' \
    -v experiment_name="$experiment_name" -v kit_name="$kit_name" -v position_id="$position_id" \
    'BEGIN { print "experiment_id,kit,position_id,barcode,alias" }
     { print experiment_name, kit_name, position_id, $1, $2 }' > "${current_directory}/sample_sheet_${experiment_name}.csv"

echo "Saved to: ${current_directory}/sample_sheet_${experiment_name}.csv"
echo "Sample sheet formatted and ready to use: "
echo ""
cat "${current_directory}/sample_sheet_${experiment_name}.csv"
echo ""
echo "----------------- END OF SCRIPT -----------------"

##########################################################################################################################
