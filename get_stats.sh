#!/usr/bin/env bash

set -e

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

if ! command -v samtools &> /dev/null; then
	echo "Error: 'samtools' is required to parse uBAM files." >&2
	exit 1
fi

#########################################################################################################

INPUT_FILE="$1"
LOG_FILE="${2:-"ubam_sequencing_stats.log"}"

if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
	echo "Usage: $0 <your_file.ubam> [output_log_file]" >&2
	exit 1
fi

echo "Processing uBAM file: $INPUT_FILE"
echo "Extracting BAM tags (qs, ch)..."
echo "=========================================="

# Extract read sequence length, mean Q-score tag (qs:f), and channel tag (ch:i)
# This bypasses character-by-character calculation, speeding processing.
# Hardcoded number of threads
STREAM_CMD="samtools view -@ 10 \"$INPUT_FILE\" | awk -F'\t' '
{
	len = length(\$10);

	# Extract Q-score float tag (qs:f:XX)
	match(\$0, /qs:f:[^\t]+/);
	qs = (RSTART > 0) ? substr(\$0, RSTART+5, RLENGTH-5) : 0;

	# Extract Channel integer tag (ch:i:XX)
	match(\$0, /ch:i:[^\t]+/);
	ch = (RSTART > 0) ? substr(\$0, RSTART+5, RLENGTH-5) : \"unknown\";

	print len \"\t\" qs \"\t\" ch
}'"

echo "Done!"
echo "Generating stats..."

# --- Metric Calculation Pass ---
eval "$STREAM_CMD" | sort -k1,1n | awk -F'\t' -v logfile="$LOG_FILE" '
{
	lens[NR] = $1
	qs[NR] = $2
	total_bases += $1
	q_sum += 10^(-$2/10)

	if ($1 > 40000) over40k++
	if ($1 > 100000) over100k++
	channels[$3]++
}
END {
	if (NR == 0) {
		print "Error: No valid sequencing reads parsed from uBAM." > "/dev/stderr"
        	exit 1
	}

	# Calculate Medians
	if (NR % 2 == 1) {
		med_len = lens[(NR+1)/2]; med_q = qs[(NR+1)/2]
    	} else {
        	med_len = (lens[NR/2] + lens[(NR/2)+1]) / 2; med_q = (qs[NR/2] + qs[(NR/2)+1]) / 2
    	}

	mean_len = total_bases / NR
	mean_q = -10 * log(q_sum / NR) / log(10)

	# Compute N50
	half_bases = total_bases / 2; running_sum = 0; n50 = 0
	for (i = NR; i >= 1; i--) {
        running_sum += lens[i]
        if (running_sum >= half_bases) { n50 = lens[i]; break; }
	}

	# Write out report
	print "--- uBAM Sequencing Production Statistics ---" >> logfile
	printf "Total parsed reads      : %d reads\n", NR >> logfile
	printf "Total yield             : %.2f Gb\n", total_bases / 1e9 >> logfile
	printf "Mean read length        : %.1f bases\n", mean_len >> logfile
	printf "Median read length      : %d bases\n", med_len >> logfile
	printf "Read length N50         : %d bases\n", n50 >> logfile
	printf "Mean read quality       : %.1f Q\n", mean_q >> logfile
	printf "Median read quality     : %.2f Q\n", med_q >> logfile
	printf "Reads greater than 40kb : %d\n", over40k >> logfile
	printf "Reads greater than 100kb: %d\n", over100k >> logfile
	printf "Active system channels  : %d\n", length(channels) >> logfile

	printf "\nTop 5 longest reads <length (qscore)>:\n" >> logfile
	idx = 0
	for (i = NR; (i > 0 && idx < 5); i--) {
        printf "%d bases\t(%.2f Q)\n", lens[i], qs[i] >> logfile
        idx++
    }
	print "--------------------------------------------\n" >> logfile
}'

echo "Processing complete! Metrics written to $LOG_FILE"
cat "$LOG_FILE"
