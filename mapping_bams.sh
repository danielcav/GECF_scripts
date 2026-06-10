#!/usr/bin/env bash

set -euo pipefail

# --- Help/Usage Function ---
usage() {
	echo "Usage: $0 -r <reference.fa> -i <input_file_or_folder> [-p <pattern>]"
	echo ""
	echo "Options:"
	echo "  -r    Path to the reference genome (FASTA format)"
	echo "  -i    Path to a single sequence file or a directory containing files"
	echo "  -p    [Optional] File pattern/extension to match (e.g., '*.pass.bam', '*.fastq.gz')"
	echo "        Default matches: *.fq, *.fastq, *.fq.gz, *.fastq.gz, *.bam"
	echo "  -h    Show this help message"
	exit 1
}

# --- Parse Arguments ---
REF=""
INPUT=""
PATTERN=""

while getopts "r:i:p:h" opt; do
	case ${opt} in
		r ) REF="$OPTARG" ;;
		i ) INPUT="$OPTARG" ;;
		p ) PATTERN="$OPTARG" ;;
		h ) usage ;;
		* ) usage ;;
	esac
done

# Validate required arguments
if [[ -z "$REF" || -z "$INPUT" ]]; then
	echo "Error: Reference (-r) and Input (-i) are required."
	usage
fi

if [[ ! -f "$REF" ]]; then
	echo "Error: Reference file '$REF' does not exist."
	exit 1
fi

# --- Core Mapping Function ---
process_file() {
	local infile="$1"
	local filename
	filename=$(basename "$infile")

	# Extract sample name by stripping known extensions
	local samplename="${filename%.gz}"
	samplename="${samplename%.bam}"
	samplename="${samplename%.fastq}"
	samplename="${samplename%.fq}"

	local out_bam="${samplename}.sorted.bam"

	echo "=================================================="
	echo "Processing: $filename"
	echo "Output will be saved as: $out_bam"
	echo "=================================================="

	# Determine input type flag for minimap2 if it's a BAM file
	if [[ "$filename" == *.bam ]]; then
		echo "Streaming BAM input via samtools fastq..."
		# Convert BAM to FASTQ stream -> Align with minimap2 -> Sort with samtools
		samtools fastq -T "*" "$infile" | \
			minimap2 -t $(nproc) -ax map-ont -y -Y "$REF" - | \
			samtools sort -@ $(nproc) -o "$out_bam" -
	else
		echo "Running minimap2 on standard FASTQ/FASTA input..."
		minimap2 -t $(nproc) -ax map-ont -Y "$REF" "$infile" | \
			samtools sort -@ $(nproc) -o "$out_bam" -
	fi

	# Index the sorted BAM
	echo "Indexing $out_bam..."
	samtools index "$out_bam"

	echo "Running flagstats for $out_bam..."
	samtools flagstats "$out_bam"

	echo "Finished processing: $out_bam"
	echo ""
}

# --- Main Logic ---

# Check if tools are installed
for cmd in minimap2 samtools; do
	if ! command -v "$cmd" &> /dev/null; then
		echo "Error: $cmd is required but not installed/in PATH."
		exit 1
	fi
done

# Case 1: Input is a single file
if [[ -f "$INPUT" ]]; then
	process_file "$INPUT"

# Case 2: Input is a directory
elif [[ -d "$INPUT" ]]; then
	echo "Scanning directory: $INPUT"

	# If user provided a specific pattern
	if [[ -n "$PATTERN" ]]; then
		find "$INPUT" -type f -iname "$PATTERN" | while read -r file; do
			process_file "$file"
		done
	else
		# Default behavior: look for standard sequencing extensions
		find "$INPUT" -type f \( -name "*.fq" -o -name "*.fastq" -o -name "*.fq.gz" -o -name "*.fastq.gz" -o -name "*.bam" \) | while read -r file; do
			process_file "$file"
		done
	fi
else
	echo "Error: Input '$INPUT' is neither a valid file nor a directory."
	exit 1
fi

echo "Pipeline complete!"
