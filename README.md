# GECF Scripts

Scripts developed at the **Gene Expression Core Facility (GECF)** for Oxford Nanopore Technology (ONT) data processing. These scripts cover the full workflow from raw POD5 files to basecalled, demultiplexed, aligned reads, plus custom 10x Genomics reference/template generation and qPCR plate validation.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Scripts Overview](#scripts-overview)
- [dorado_basecaller_prod.sh](#dorado_basecaller_prodsh)
- [format_sample_sheet.sh](#format_sample_sheetsh)
- [demux.sh](#demuxsh)
- [get_stats.sh](#get_statssh)
- [adaptive_sampling_filter.sh](#filter_adaptive_samplingsh)
- [mapping_bams.sh](#mapping_bamssh)
- [update_dorado.sh](#update_doradosh)
- [generate_cellranger_template_atac.py](#generate_cellranger_template_atacpy)
- [fasta_to_gtf.py](#fasta_to_gtfpy)
- [qpcr-template-validator.py](#qpcr-template-validatorpy)
- [Test Fixtures](#test-fixtures)
- [Supporting Files](#supporting-files)
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
| `adaptive_sampling_filter.sh` | Filters pod5 files using adaptive sampling decisions |
| `mapping_bams.sh` | Aligns FASTQ/BAM reads to a reference genome with minimap2 |
| `update_dorado.sh` | Downloads and installs the latest stable Dorado release |
| `generate_cellranger_template_atac.py` | Produces a cellranger-atac pipeline script from an AVT Excel file |
| `fasta_to_gtf.py` | Converts custom multi-FASTA to cellranger-arc-compatible GTF |
| `qpcr-template-validator.py` | Validates qPCR DNA/PRIMER Hamilton Excel templates before sending to robot |

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
# When prompted, point to the filtered pod5 file
```

---

## mapping_bams.sh

Aligns FASTQ or BAM reads to a reference genome using **minimap2**, producing sorted and indexed BAM files. Processes single files or entire directories. The script also prints a `samtools flagstat` summary for each file.

### Usage

```bash
bash mapping_bams.sh -r <reference.fa> -i <input_file_or_folder> [-p <pattern>]
```

### Options

| Option | Description | Default |
|---|---|---|
| `-r <path>` | Reference genome in FASTA format (required) | |
| `-i <path>` | Path to a single file or directory (required) | |
| `-p <pattern>` | File pattern/extension to match (e.g. `*.pass.bam`, `*.fastq.gz`) | `*.fq, *.fastq, *.fq.gz, *.fastq.gz, *.bam` |
| `-h` | Show help message | |

### Supported inputs

- FASTQ / `.fq` (gzipped or uncompressed)
- BAM — streamed through `samtools fastq` first, then aligned

### Output

For each input file, a sorted and indexed BAM (`<sample>.sorted.bam`) plus its `.bai` index. A flagstat summary is printed to the terminal.

> Uses all available CPU cores via `nproc`.

---

## update_dorado.sh

Automatically downloads and installs the **latest stable** Dorado release from GitHub. Checks for pre-release builds and skips them by default. Detects your OS/architecture automatically.

### Prerequisites

Dorado binaries are platform-specific — this script detects your OS (macOS / Linux) and architecture (x64 / ARM) so you get the right build:

```bash
conda activate basecaller
bash update_dorado.sh
```

> Dorado is required before you can run basecalling (`dorado_basecaller_prod.sh`). The script is also part of the installation process; see [Installation](#installation).

---

## generate_cellranger_template_atac.py

Given an AVT Excel tracking file, generates a ready-to-run shell script that executes `cellranger-atac count` for every sample in the run. Parses the "GECF fastq ID (avidxxxx)" column to locate each sample's FASTQ pair and writes out a properly formatted pipeline wrapper (`<AVT>_cellranger_atac_pipelines.sh`).

### Usage

```bash
python3 generate_cellranger_template_atac.py file.xlsx
```

The Excel sheet must contain at least:
- A `"GECF fastq ID (avidxxxx)"` column linking samples to FASTQ pairs
- A run name matching `AVT0\d{3,5}` somewhere in the sheet or filename

> After running, check the generated script and verify paths before executing.

---

## fasta_to_gtf.py

Converts a multi-FASTA file (one contig per custom gene) into four GTF lines (gene + transcript + exon + CDS). The output pairs with your FASTA for building a **cellranger-arc** reference (`mkref`). Also writes a cleaned FASTA matching all names used in the GTF.

### Usage

```bash
python3 fasta_to_gtf.py input.fasta output.gtf
```

### Output

| Path | Purpose |
|---|---|
| `<output>.gtf` | 4 lines per FASTA record (+ strand) |
| `<output>.clean.fasta` | Cleaned FASTA headers matching GTF contig names |

> Names are sanitized: underscores become hyphens, `|` in headers drops metadata after the first pipe.

---

## qpcr-template-validator.py

Validates DNA and PRIMER Excel workbooks used as input templates for the **Hamilton qPCR workstation** (**v4.03 Hamilton Workstation**) before sending them to the robot. Catches errors early so plate preparation runs smoothly.

The validator checks both **DNA list** and **PRIMER list** sheets (a workbook must contain one or the other, never both). It verifies headers, sample/primer names, tasks, quantities, controls, plate capacity limits, duplicate entries, TaqMan reporter types, and more.

Two independent files work together:

- `qpcr_validation.py` — pure validation core (no UI imports)
- `qpcr-template-validator.py` — dashboard wrapper with **GUI** and **CLI** modes; loads the core from its sibling path

### Usage

**CLI mode** (headless or scripted):

```bash
# Single file
python qpcr-template-validator.py --cli /path/to/DNA_list.xls

# Multiple files
python qpcr-template-validator.py --cli file1.xls file2.xlsx

# Scan a directory recursively for Excel workbooks
python qpcr-template-validator.py --cli --dir /path/to/workbook_folder/
```

**GUI mode:**

```bash
# File picker popup
python qpcr-template-validator.py

# Pre-load files into the dashboard
python qpcr-template-validator.py file1.xls file2.xlsx
```

### Requirements

- `openpyxl` (for `.xlsx`/`.xlsm`)
- `xlrd` (for legacy `.xls`)

### Output

Exit code:

| Code | Meaning |
|---|---|
| 0 | All workbooks passed |
| 1 | One or more workbooks has failures |

Results are printed immediately. Each validation checks:

- Correct sheet name (`DNA` or `PRIMER`)
- Valid headers
- Task values (STND, NTC, UNKN)
- Sample/primer name format and uniqueness
- Quantity validation (NTC = 0, no decimal standards)
- Presence of controls (NTC + standard curve)
- Plate capacity limits (192 rows max for DNA, 64 unique primers)
- TaqMan reporter type

---

## Test Fixtures

A set of **20** pre-built test Excel workbooks live in `test_fixtures/`, covering every validation rule. To install them:

```bash
cd test_fixtures
python create_test_fixtures.py
```

Then verify the validator against all fixtures:

```bash
python run_fixture_checks.py
```

See `test_fixtures/README.md` for details on each individual fixture case. Fixtures are not tracked in git (see `.gitignore`).

---

## Supporting Files

| Path | Purpose |
|---|---|
| `basecaller_env.yml` | Conda environment definition for Dorado basecalling (pre-built models excluded) |
| `.gitignore` | Excludes large artifacts: `.xlsx` test fixtures, `.local/`, and generated BAMs |
| `test_fixtures/` | Test fixture generators and runner; see [Test Fixtures](#test-fixtures) above |

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
