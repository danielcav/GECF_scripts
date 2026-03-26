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
| p2sid00xx      | SQK-NBD114-24     | A           | barcode01 | sample1 |
| p2sid00xx      | SQK-NBD114-24     | A           | barcode02 | sample2 |
| p2sid00xx      | SQK-NBD114-24     | A           | barcode03 | sample3 |
| p2sid00xx      | SQK-NBD114-24     | A           | barcode04 | sample4 |
+----------------+-------------------+-------------+-----------+---------+
EOF

# you can change '-i "p2sid00"' with whatever you want it to pre-fill the user field
read -e -i "p2sid00" -p "Please specify an experiment name (e.g. p2sid00xx): " run_name

while true; do
        read -ep "Auto detect the barcoding kit ? (y/n): " ans_auto
        case "$ans_auto" in
                [Nn])
                        read -ep "Enter the name of the barcode kit (e.g., SQK-NBD114-24): " kit_name
                        break
                        ;;
                [Yy])
                        while true; do
                                # Can improve this part so the user directly gives a pod5 file instead of a directory.
                                read -ep "Enter the pod5 directory path: " input_path
                                pod5_directory=$(realpath -e "${input_path/#\~/$HOME}" 2>/dev/null || true)

                                if [[ -n "$pod5_directory" ]] && [[ -d "$pod5_directory" ]]; then
                                        pod5_file=$(find "$pod5_directory" -type f -name "*.pod5" | head -n 1)
                                        if [[ -z "${pod5_file:-}" ]]; then
                                                echo "Directory exists but does not contain any .pod5 files. Please provide another directory path."
                                        else
                                                echo "Directory exists and contains pod5 files: $pod5_directory"
                                                echo "Detecting barcoding kit..."
                                                kit_name=$(pod5 inspect debug "$pod5_file" | \
                                                        grep "barcoding_kits" | \
                                                        sed "s/.*barcoding_kits': '\([^']*\)'.*/\1/" | \
                                                        awk '{print toupper($1)}')
                                                if [[ -z "${kit_name:-}" ]]; then
                                                        read -ep "The program was not able to detect the sequencing kit. Please enter a sequencing kit name (e.g. SQK-NBD114-24): " kit_name
                                                else
                                                        echo "Detected kit: $kit_name"
                                                fi
                                                break
                                        fi
                                else
                                        echo "Directory does not exist. Please try again."
                                fi
                        done
                        break
                        ;;
                *)
                        echo "Please enter y or n."
                        ;;
        esac
done


PS3="Select a position ID corresponding to the FC position on the P2Solo: "
select position_id in A B; do
        if [[ -n "$position_id" ]]; then
                echo "Position selected: $position_id"
                break
        else
                echo "Invalid selection. Try again."
        fi
done

# get current directory to sacve sample sheet
current_directory="$(pwd)"

sort -t';' -k1,1 "$user_sample_sheet" | \
awk -F';' -v OFS=',' \
    -v run_name="$run_name" -v kit_name="$kit_name" -v position_id="$position_id" \
    'BEGIN { print "experiment_id,kit,position_id,barcode,alias" }
     { print run_name, kit_name, position_id, $1, $2 }' > "${current_directory}/sample_sheet_${run_name}.csv"

echo "Sample sheet formatted and ready to use: "
echo ""
cat "${current_directory}/sample_sheet_${run_name}.csv"
echo ""
echo "----------------- END OF SCRIPT -----------------"

##########################################################################################################################
