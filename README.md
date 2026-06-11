# GECF Scripts

Scripts developed at the **Gene Expression Core Facility (GECF)** for Oxford Nanopore Technology (ONT) data processing. These scripts cover the full workflow from raw pod5 files to basecalled and demultiplexed reads, with QC metrics at each step.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Scripts Overview](#scripts-overview)
- [dorado_basecaller_prod.sh](#dorado_basecaller_prodsh)
- [format_sample_sheet.sh](#format_sample_sheetssh)
- [demux.sh](#demuxsh)
- [get_stats.sh](#get_statssh)
- [filter_adaptive_sampling.sh](#filter_adaptive_samplingsh)
- [Typical Workflows](#typical-workflows)

---

## Requirements

- Linux system
- [Conda](https://docs.conda.io/en/latest/)
- [Dorado](https://github.com/nanoporetech/dorado) (installed separately, see below)

All other dependencies are managed through the provided conda environment.

---

## Installation

**1. Clone the repository**

```bash
git clone https://github.com/danielcav/GECF_scripts.git
cd GECF_scripts
```

**2. Create the conda environment**

```bash
conda env create -f basecaller_env.yml
conda activate basecaller
```

**3. Install Dorado**

Dorado is not available via conda and must be installed separately. You can use the provided update script:

```bash
bash update_dorado.sh
```

Or download it manually from the [Dorado releases page](https://github.com/nanoporetech/dorado/releases).

**4. Make scripts executable**

```bash
chmod +x *.sh
```

> All scripts must be kept in the same folder to work correctly together.

---

## Scripts Overview

| Script | Description |
|---|---|
| `dorado_basecaller_prod.sh` | Basecalls raw pod5 files using Dorado |
| `format_sample_sheet.sh` | Generates a sample sheet for demultiplexing |
| `demux.sh` | Demultiplexes barcoded basecalled BAM files |
| `get_stats.sh` | Computes sequencing statistics from a BAM file |
| `filter_adaptive_sampling.sh` | Filters pod5 files using adaptive sampling decisions |

---

## dorado_basecaller_prod.sh

Basecalls raw pod5 files using Dorado. Supports simplex and duplex modes, modified base calling, and both barcoded and non-barcoded runs. Automatically downloads the selected model and generates QC reports and sequencing statistics.

### Usage

```bash
bash dorado_basecaller_prod.sh [--qscore <int>] [--legacy]
```

### Options

| Option | Description | Default |
|---|---|---|
| `--qscore <int>` | Minimum qscore filter for pass/fail read splitting | 10 |
| `--legacy` | Show older model versions in model selection | false |
| `-h`, `--help` | Show help message | |

### The script will interactively ask for

- Project name (run name)
- Path to the pod5 directory
- Basecalling mode (simplex or duplex)
- Accuracy mode (fast, hac, sup)
- Model selection
- Whether to call modified bases (5mC, 5hmC, 6mA...)
- Whether reads are barcoded

### Output structure

```
SUP_basecalling_<run_name>/
├── ubam_files/          # Basecalled BAM files (pass and fail)
├── fastq_files/         # Compressed FASTQ files
├── summaries/           # Sequencing summary files
├── QC_reports/          # Sequali QC reports (HTML + JSON)
├── logs/                # Log file with parameters, versions and stats
└── checksums_<run>.txt  # MD5 checksums for BAM and FASTQ files
```

### Example

```bash
conda activate basecaller
bash dorado_basecaller_prod.sh --qscore 10
```

> If reads are barcoded, the script will stop after basecalling and ask you to run `demux.sh` next.

---
 
## format_sample_sheet.sh
 
Generates a properly formatted sample sheet CSV file required by `demux.sh`. It takes a simple text file mapping barcodes to sample names and enriches it with run metadata (kit name, experiment name, sequencer position), either by auto-detecting them from a pod5 file or by manual input.
 
> Always run this script before `demux.sh`.
 
### Usage
 
```bash
bash format_sample_sheet.sh <barcode_aliases.txt>
```
 
### Input file format
 
A plain text file with one entry per line, formatted as `barcode;sample_name`:
 
```
barcode01;sample1
barcode02;sample2
barcode03;HEK293
barcode04;HeLa
```
 
### The script will interactively ask for
 
- Whether to auto-detect metadata from a pod5 file (recommended)
- If auto-detect: path to a pod5 file or directory
- If manual: kit name, experiment name, and sequencer position (A or B)
### Output
 
A CSV sample sheet saved in the current directory:
 
```
sample_sheet_<experiment_name>.csv
```
 
With the following structure:
 
```
experiment_id,kit,position_id,barcode,alias
SOL0046,SQK-NBD114-24,P2S-00697-A,barcode01,sample1
SOL0046,SQK-NBD114-24,P2S-00697-A,barcode02,sample2
```
 
### Example
 
```bash
bash format_sample_sheet.sh barcodes_SOL0046.txt
# When prompted, choose auto-detect and provide the pod5 directory
```
 
---

## demux.sh

Demultiplexes barcoded BAM files produced by `dorado_basecaller_prod.sh`. Handles both simplex and duplex data, including false positive duplex read detection and removal. Produces submission-ready folder structure with QC reports and statistics for each sample.

### Usage

```bash
bash demux.sh --input <file.bam> --sample-sheet <file.csv> [options]
```

### Options

| Option | Description | Default |
|---|---|---|
| `--input <file.bam>` | Input BAM file (required) | |
| `--sample-sheet <file>` | Sample sheet CSV or TXT file (required) | |
| `--qscore <int>` | Minimum qscore filter | 10 |
| `--greedy` | Classify duplex reads using only one parent if the other is unclassified | false |
| `--barcode-both-ends` | Require barcodes on both ends of the read | false |
| `-h`, `--help` | Show help message | |

### Sample sheet format

The sample sheet must be a CSV or TXT file. It can be generated using the provided `format_sample_sheet.sh` script. It should contain at minimum the run name and kit name.

### Output structure

```
demultiplexed_data_<run_name>/
├── ubam_files/          # Per-sample BAM files (all, pass, fail)
├── fastq_files/         # Per-sample compressed FASTQ files
├── summaries/           # Per-sample sequencing summaries
├── QC_reports/          # Per-sample Sequali QC reports
└── logs/                # Log file with parameters and stats
```

### Example

```bash
bash demux.sh \
    --input /data/SUP_basecalling_p2sid0046/ubam_files/p2sid0046_untrimmed.all.bam \
    --sample-sheet /data/sample_sheet_p2sid0046.csv \
    --qscore 10
```

---

## get_stats.sh

Computes sequencing statistics directly from a BAM file. Called automatically by `dorado_basecaller_prod.sh` and `demux.sh`, but can also be used standalone on any BAM file.

### Usage

```bash
bash get_stats.sh [-o output_log_file] <your_file.bam>
```

### Options

| Option | Description |
|---|---|
| `-o <file>` | Append statistics to a log file (optional) |
| `-h`, `--help` | Show help message |

### Output metrics

- Total number of reads
- Total yield (Gb)
- Mean and median read length
- Read length N50
- Mean and median read quality
- Number of reads greater than 40kb and 100kb
- Number of active channels
- Top 5 longest reads with their quality scores

### Example

```bash
# Print stats to terminal only
bash get_stats.sh /data/my_sample.bam

# Print stats to terminal and append to a log file
bash get_stats.sh -o my_run.log /data/my_sample.bam
```

---

## filter_adaptive_sampling.sh

When sequencing with adaptive sampling, MinKNOW generates a decisions file (`AS_decisions_*.csv`) that records which reads were accepted or rejected in real time. This script extracts the IDs of accepted reads and creates a filtered pod5 file containing only those reads, significantly reducing basecalling time.

### Usage

```bash
bash filter_adaptive_sampling.sh \
    --as-csv <AS_decisions.csv> \
    --pod5-dir <pod5_directory> \
    --project <project_name> \
    [--output-dir <output_directory>]
```

### Options

| Option | Description | Default |
|---|---|---|
| `--as-csv <file>` | Path to the adaptive sampling decisions CSV file (required) | |
| `--pod5-dir <dir>` | Path to the directory containing pod5 files (required) | |
| `--project <name>` | Project name, e.g. p2sid0046 (required) | |
| `--output-dir <dir>` | Output directory | Parent of pod5 directory |
| `-h`, `--help` | Show help message | |

### Output

- `accepted_read_ids_<project>.txt` — list of accepted read IDs
- `accepted_reads_<project>.pod5` — filtered pod5 file containing only accepted reads

> Some read IDs may be missing from the pod5 files. This is normal behaviour with adaptive sampling and is handled automatically with the `--missing-ok` flag.

### Example

```bash
bash filter_adaptive_sampling.sh \
    --as-csv /data/adaptive_sampling/AS_decisions_SOL0046.csv \
    --pod5-dir /data/SOL0046/pod5/ \
    --project p2sid0046
```

Then basecall the filtered pod5 file:

```bash
bash dorado_basecaller_prod.sh
# When prompted for the pod5 directory, provide the output directory from the previous step
```

---

## Typical Workflows

### Standard simplex or duplex run (non-barcoded)

```bash
conda activate basecaller
bash dorado_basecaller_prod.sh
```

### Barcoded run (simplex or duplex)

```bash
conda activate basecaller
bash dorado_basecaller_prod.sh
# Script stops after basecalling for barcoded data
bash demux.sh --input <basecalled.bam> --sample-sheet <sheet.csv>
```

### Adaptive sampling run

```bash
conda activate basecaller
bash filter_adaptive_sampling.sh \
    --as-csv <AS_decisions.csv> \
    --pod5-dir <pod5/> \
    --project <run_name>
bash dorado_basecaller_prod.sh
# When prompted, point to the filtered pod5 file
```

### Compute stats on any BAM file

```bash
conda activate basecaller
bash get_stats.sh /path/to/any_file.bam
```
