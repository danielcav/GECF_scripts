#!/bin/bash
set -e -o pipefail

on_exit () {
	echo "This script has exited in error (on line $1)"
}
trap 'on_exit $LINENO' ERR

########################################## CHECK DEPENDENCIES ###########################################

if [[ -z "$CONDA_PREFIX" ]] || [[ "$CONDA_DEFAULT_ENV" == "base" ]]; then
	echo "Please activate your Conda environment first."
	echo "-> conda activate basecaller"
	exit 1
fi

if ! command -v pod5 &> /dev/null; then
	echo "Error: 'pod5' is required." >&2
	exit 1
fi

#########################################################################################################

usage() {
	echo "Usage: $0 --as-csv <AS_decisions.csv> --pod5-dir <pod5_directory> --project <project_name> [--output-dir <output_directory>]"
	echo ""
	echo "Arguments:"
	echo "  --as-csv    <file>   Path to the adaptive sampling decisions CSV file"
	echo "  --pod5-dir  <dir>    Path to the directory containing pod5 files"
	echo "  --project   <name>   Project name (e.g. SOL0046)"
	echo ""
	echo "Options:"
	echo "  --output-dir <dir>   Output directory. Default: same as pod5 directory"
	echo "  -h, --help           Show this help message"
	exit 0
}

########################################## PARSE ARGUMENTS ###########################################

as_csv=""
pod5_dir=""
project_name=""
output_dir=""

if [[ $# -eq 0 ]]; then
	usage
fi

while [[ "$#" -gt 0 ]]; do
	case $1 in
		--as-csv)
			as_csv="$2"
			shift 2
			;;
		--pod5-dir)
			pod5_dir="$2"
			shift 2
			;;
		--project)
			project_name="$2"
			shift 2
			;;
		--output-dir)
			output_dir="$2"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Unknown option: $1"
			usage
			;;
	esac
done

# validate inputs
if [[ -z "$as_csv" ]]; then
	echo "Error: --as-csv is required." >&2
	exit 1
elif [[ ! -f "$as_csv" ]]; then
	echo "Error: AS decisions file '${as_csv}' not found." >&2
	exit 1
fi

if [[ -z "$pod5_dir" ]]; then
	echo "Error: --pod5-dir is required." >&2
	exit 1
elif [[ ! -d "$pod5_dir" ]]; then
	echo "Error: pod5 directory '${pod5_dir}' not found." >&2
	exit 1
fi

if [[ -z "$project_name" ]]; then
	echo "Error: --project is required." >&2
	exit 1
fi

if [[ -z "$output_dir" ]]; then
	output_dir="$(dirname "$pod5_dir")"
fi

mkdir -p "$output_dir"

accepted_ids="${output_dir}/accepted_read_ids_${project_name}.txt"
accepted_pod5="${output_dir}/accepted_reads_${project_name}.pod5"

#########################################################################################################

{
	echo ""
	echo "╔════════════════════════════════════╗"
	echo "║   Adaptive Sampling Read Filter    ║"
	echo "╚════════════════════════════════════╝"
	echo ""
}

echo "AS decisions file : $as_csv"
echo "pod5 directory    : $pod5_dir"
echo "Project name      : $project_name"
echo "Output directory  : $output_dir"
echo ""

########################################## EXTRACT ACCEPTED READ IDS ###########################################

echo -n "Extracting accepted read IDs from AS decisions file..."
tail -n +2 "$as_csv" | awk -F',' '{if ($2 == "sequence" && $3 == "SUCCESS") print $1}' > "$accepted_ids"
n_accepted=$(wc -l < "$accepted_ids")
echo "Done"
echo "Found ${n_accepted} accepted reads."
echo ""

if [[ "$n_accepted" -eq 0 ]]; then
	echo "Error: no accepted reads found in ${as_csv}. Check that the file is correctly formatted." >&2
	exit 1
fi

########################################## FILTER POD5 FILES ###########################################

total_cores=$(nproc --all)
cores=$((total_cores - 2))

echo -n "Filtering pod5 files to keep accepted reads only..."
pod5 filter "${pod5_dir}"/*.pod5 \
	-t "$cores" \
	-i "$accepted_ids" \
	-o "$accepted_pod5" \
	--missing-ok
echo "Done"
echo ""

echo "Filtered pod5 file created: $accepted_pod5"
echo ""
echo "You can now run basecaller.sh using this file as input:"
echo "  bash dorado_basecaller_prod.sh"
echo "  -> When prompted for pod5 directory, provide: $(dirname "$accepted_pod5")"
echo ""

{
	echo "╔════════════════════════════════════╗"
	echo "║           Filtering done!          ║"
	echo "╚════════════════════════════════════╝"
	echo ""
}
