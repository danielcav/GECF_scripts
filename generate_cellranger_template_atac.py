#!/usr/bin/env python3
"""
generate_cellranger_template_atac.py

Usage:
    python3 generate_cellranger_template_atac.py file.xlsx

Reads an Excel sheet containing (at least) these columns:
    - "GECF fastq ID (avidxxxx)"
    - "Sample name" (trailing spaces in the header are tolerated)
and a cell somewhere in the sheet containing the run name (AVT0XXX).

It then asks which reference genome to use, and generates a
cellranger-atac_AVT0XXX.sh script pre-filled with one
"cellranger-atac count" block per sample.
"""

import argparse
import readline
import glob
import os
import re
import sys

try:
    import openpyxl
except ImportError:
    sys.exit(
        "Error: the python module 'openpyxl' is required.\n"
        "Install it with: pip3 install openpyxl"
    )


HUMAN_GENOME_PATH = "/home/gecf/references/cellranger_references/current_human_arc_ATAC/refdata-cellranger-arc-GRCh38-2024-A"
MOUSE_GENOME_PATH = "/home/gecf/references/cellranger_references/current_mouse_arc_ATAC/refdata-cellranger-arc-GRCm39-2024-A"

AVT_PATTERN = re.compile(r"AVT0?\d{3,5}", re.IGNORECASE)

def _path_completer(text, state):
    matches = glob.glob(os.path.expanduser(text) + "*")
    matches = [m + "/" if os.path.isdir(m) else m for m in matches]
    return matches[state] if state < len(matches) else None

readline.set_completer_delims(" \t\n;")
readline.set_completer(_path_completer)
readline.parse_and_bind("tab: complete")

def norm(value):
    if value is None:
        return ""
    return str(value).strip().lower()


def build_merged_cell_lookup(ws):
    """
    Returns a dict mapping (row, col) -> value for every cell that belongs
    to a merged range, using the value stored in the top-left cell of that
    range. This lets header rows that use merged cells (e.g. a label
    merged across two rows) still resolve correctly.
    """
    lookup = {}
    for merged_range in ws.merged_cells.ranges:
        min_row, min_col, max_row, max_col = (
            merged_range.min_row,
            merged_range.min_col,
            merged_range.max_row,
            merged_range.max_col,
        )
        top_left_value = ws.cell(row=min_row, column=min_col).value
        for r in range(min_row, max_row + 1):
            for c in range(min_col, max_col + 1):
                lookup[(r, c)] = top_left_value
    return lookup


def get_cell_value(ws, merged_lookup, row, col):
    if (row, col) in merged_lookup:
        return merged_lookup[(row, col)]
    return ws.cell(row=row, column=col).value


def parse_xlsx(path):
    """
    Returns (sample_fastq_pairs, detected_avt_run)
    sample_fastq_pairs: list of (sample_name, fastq_id) tuples
    detected_avt_run: string or None
    """
    wb = openpyxl.load_workbook(path, data_only=True)
    print(f"  Sheets: {', '.join(wb.sheetnames)}")

    if "User_x1x_copy" in wb.sheetnames:
        ws = wb["User_x1x_copy"]
        print(f"  -> Using 'User_x1x_copy' sheet")
    else:
        ws = wb.active
        print(f"  -> Using active sheet '{ws.title}'")

    merged_lookup = build_merged_cell_lookup(ws)

    fastq_col = None
    sample_col = None
    header_row_idx = None

    # Scan header rows, combining each row with the row above it, so a
    # header label merged/split across two rows (e.g. "GECF fastq ID" on
    # one row and "(avidxxxx)" on the row above/below) is still detected.
    max_header_scan = min(15, ws.max_row)
    for row_idx in range(1, max_header_scan + 1):
        row_vals = [
            get_cell_value(ws, merged_lookup, row_idx, c)
            for c in range(1, ws.max_column + 1)
        ]
        prev_row_vals = (
            [
                get_cell_value(ws, merged_lookup, row_idx - 1, c)
                for c in range(1, ws.max_column + 1)
            ]
            if row_idx > 1
            else [""] * ws.max_column
        )
        combined = [
            f"{norm(prev)} {norm(cur)}".strip()
            for prev, cur in zip(prev_row_vals, row_vals)
        ]

        f_idx = None
        s_idx = None
        for i, v in enumerate(combined):
            if "fastq id" in v and "avid" in v:
                f_idx = i
            if "sample name" in v:
                s_idx = i
        if f_idx is not None and s_idx is not None:
            fastq_col = f_idx + 1
            sample_col = s_idx + 1
            header_row_idx = row_idx
            break

    if fastq_col is None or sample_col is None:
        sys.exit(
            "Error: could not find both 'GECF fastq ID (avidxxxx)' and "
            "'Sample name' columns in the first 10 rows."
        )

    # If the header cell(s) are merged across multiple rows, make sure we
    # start reading data *after* the full merged range, not right after
    # the row where we first detected the header text.
    data_start_row = header_row_idx + 1
    for merged_range in ws.merged_cells.ranges:
        if (
            merged_range.min_row <= header_row_idx <= merged_range.max_row
            and (
                merged_range.min_col <= fastq_col <= merged_range.max_col
                or merged_range.min_col <= sample_col <= merged_range.max_col
            )
        ):
            data_start_row = max(data_start_row, merged_range.max_row + 1)

    print(
        f"Found header on row {header_row_idx}: "
        f"fastq column {fastq_col}, sample column {sample_col}"
    )

    pairs = []
    blank_streak = 0
    for row_idx in range(data_start_row, ws.max_row + 1):
        fastq_val = get_cell_value(ws, merged_lookup, row_idx, fastq_col)
        sample_val = get_cell_value(ws, merged_lookup, row_idx, sample_col)

        fastq_val = str(fastq_val).strip() if fastq_val is not None else ""
        sample_val = str(sample_val).strip() if sample_val is not None else ""

        # Excel returns 0 for empty numeric-formatted cells — treat those
        # the same as genuinely blank.
        fastq_val = "" if fastq_val == "0" else fastq_val
        sample_val = "" if sample_val == "0" else sample_val

        # Stop immediately if we hit a "Run details" marker row (a common
        # section break some sheets use after the sample table)
        if "run details" in norm(fastq_val) or "run details" in norm(sample_val):
            break

        if fastq_val and sample_val:
            pairs.append((sample_val, fastq_val))
            blank_streak = 0
        elif not fastq_val and not sample_val:
            # Fully empty row: could be a stray blank row, or the real end
            # of the table. Tolerate isolated blank rows, but stop once we
            # see two blank rows in a row (after we've already collected
            # at least one pair).
            blank_streak += 1
            if pairs and blank_streak >= 2:
                break
        else:
            # One of the two cells is empty but not both: likely a
            # malformed/partial row. Skip it but keep going.
            print(
                f"Warning: row {row_idx} has only one of "
                f"fastq ID / sample name filled in; skipping."
            )
            blank_streak = 0

    # Search whole sheet for an AVT run name
    avt_found = None
    for row in ws.iter_rows():
        for cell in row:
            if cell.value is None:
                continue
            m = AVT_PATTERN.search(str(cell.value))
            if m:
                avt_found = m.group(0).upper()
                break
        if avt_found:
            break

    return pairs, avt_found


def print_pairs_table(pairs):
    """
    Print a simple aligned table of (sample_name, fastq_id) pairs,
    with the fastq ID column first.
    """
    if not pairs:
        return

    fastq_header = "Fastq ID"
    sample_header = "Sample name"

    fastq_width = max(len(fastq_header), max(len(f) for _, f in pairs))
    sample_width = max(len(sample_header), max(len(s) for s, _ in pairs))

    sep = f"+{'-' * (fastq_width + 2)}+{'-' * (sample_width + 2)}+"

    print(sep)
    print(f"| {fastq_header:<{fastq_width}} | {sample_header:<{sample_width}} |")
    print(sep)
    for sample_name, fastq_id in pairs:
        print(f"| {fastq_id:<{fastq_width}} | {sample_name:<{sample_width}} |")
    print(sep)


# Global flag for non-interactive execution (CI/testing)
NON_INTERACTIVE = False

def ask_avt_run(detected_avt):
    if NON_INTERACTIVE:
        return detected_avt or "AVT0000"
    if detected_avt:
        while True:
            print(f"Detected run name: {detected_avt}")
            answer = input("Use this run name? [Y/n]: ").strip()
            if answer[0].lower() == "y":
                return detected_avt
            elif answer[0].lower() == "n":
                break
            else:
                print("Answer can only be Y or n. Please try again.")
                continue

    while True:
        avt_run = input("Enter the AVT run name (e.g. AVT0226): ").strip()
        if avt_run:
            return avt_run
        print("AVT run name cannot be empty. Please try again.")

def ask_reference_genome():
    if NON_INTERACTIVE:
        return HUMAN_GENOME_PATH
    print()
    print("Which reference genome do you want to use?")
    print("  1) Current human genome")
    print("  2) Current mouse genome")
    print("  3) Custom genome (specify path)")
    while True:
        choice = input("Enter choice [1-3]: ").strip()

        if choice == "1":
            return HUMAN_GENOME_PATH
        elif choice == "2":
            return MOUSE_GENOME_PATH
        elif choice == "3":
            path = input("Enter full path to custom genome reference: ").strip()
            if os.path.isdir(path):
                return path
            print(f"Error: path '{path}' does not exist. Please try again.")
            continue
        else:
            print(f"Invalid choice '{choice}'. Please enter 1, 2, or 3.")
            continue


NGS_BASE_DIR_TEMPLATE = "/mnt/PTEGraw/AA/NGSruns/AVT/AV240401/{avt_run}"


def find_fastq_path(avt_run, fastq_id):
    """
    Search recursively under the run's base directory for a directory
    whose name is exactly `fastq_id` (it can live under any subfolder
    structure). Returns the full path if found, or None if not found
    (e.g. base dir doesn't exist on this machine, or no matching folder).
    """
    base_dir = NGS_BASE_DIR_TEMPLATE.format(avt_run=avt_run)

    if not os.path.isdir(base_dir):
        return None

    for root, dirnames, _ in os.walk(base_dir):
        for d in dirnames:
            if d == fastq_id:
                return os.path.join(root, d)

    return None


def build_script(avt_run, reference_genome, pairs):
    lines = []
    lines.append("#!/bin/bash")
    lines.append("TIMESTAMP=$(date +%Y%m%d_%H%M%S)")
    lines.append("")

    base_dir = NGS_BASE_DIR_TEMPLATE.format(avt_run=avt_run)
    base_dir_exists = os.path.isdir(base_dir)

    for idx, (_, fastq_id) in enumerate(pairs, start=1):
        resolved_path = find_fastq_path(avt_run, fastq_id)
        if resolved_path:
            lines.append(f"fastq_path_{idx}={resolved_path}")
        else:
            lines.append(f"fastq_path_{idx}={base_dir}/FIXME_LOCATE_{fastq_id}")
            if base_dir_exists:
                print(
                    f"Warning: no folder named '{fastq_id}' found under "
                    f"{base_dir} - fastq_path_{idx} needs to be set manually."
                )
    if not base_dir_exists:
        print(
            f"Warning: base directory {base_dir} not found on this machine - "
            f"all fastq_path_N variables need to be set manually."
        )
    lines.append("")

    lines.append(f"reference_genome_used={reference_genome}")
    lines.append("")

    lines.append("# Extra cellranger-atac options (leave empty if none)")
    lines.append("# Examples: --chemistry=ARC-v1  --no-bam  --min-atac-count=500")
    lines.append("CUSTOM_OPTIONS=")
    lines.append("")

    lines.extend(f"""
# Specify input folder (i.e. where cellranger count output files are located)
# example: /mnt/data/CellRangerCountOutput/
Server_folder=
# example: {base_dir}/CRatac_{avt_run}_${{TIMESTAMP}}
NGSruns_folder=

# checks if folders exist
if [[ ! -d "$Server_folder" ]]; then
    echo "Server folder does not exist."
    exit 1
fi
if [[ ! -d "$NGSruns_folder" ]]; then
    echo "NGSruns folder does not exist."
    exit 1
fi

#------------------------------------- MAIN -------------------------------------#
""".strip("\n").splitlines())
    lines.append("")

    for idx, (sample_name, fastq) in enumerate(pairs, start=1):
        numbered_dir = f'$(printf "%02d" {idx})_{sample_name}_atac'
        lines.append(f"# --- Sample {idx}: {sample_name} ---")
        lines.append(
            f"cellranger-atac count --id={sample_name} \\"
        )
        lines.append(
            f"                       --description={fastq} \\"
        )
        lines.append(
            f"                       --reference=${{reference_genome_used}} \\"
        )
        lines.append(
            f"                       --fastqs=${{fastq_path_{idx}}} \\"
        )
        lines.append(
            f"                       --output=${{NGSruns_folder}}/{numbered_dir} \\"
        )
        lines.append(
            f"                       ${{CUSTOM_OPTIONS}}"
        )
        lines.append("")
        lines.append(
            f"# Clean up SC_ATAC_COUNTER_CS (non-useful)"
        )
        lines.append(
            f"rm -rf ${{NGSruns_folder}}/{numbered_dir}/sc/atac/count/{sample_name}_atac/sc_atac_counter_cs/* 2>/dev/null || true"
        )
        lines.append("")

    # Post-processing: collect WebSummaries into a {avt_run}_Summaries folder
    lines.append("")
    lines.append("# ------------------------------------ POST-PROCESSING ------------------------------------ #")
    lines.append("")
    lines.append("# Collect per-sample WebSummaries into one folder")
    lines.append(f"mkdir -p ${{NGSruns_folder}}/{avt_run}_Summaries")
    lines.append("")
    for idx, (sample_name, fastq) in enumerate(pairs, start=1):
        numbered_dir = f'$(printf "%02d" {idx})_{sample_name}_atac'
        sample_atac_id = f"{sample_name}_atac"
        lines.append(
            f"cp -n ${{NGSruns_folder}}/{numbered_dir}/ats/bam/web_summary/index.html "
            f"${{NGSruns_folder}}/{avt_run}_Summaries/{sample_name}_WebSummary.html 2>/dev/null || true"
        )
    lines.append("")

    # Collect summary.csv files into one merged CSV
    lines.append("# Merge all per-sample summary.csv into a single file")
    lines.append(f"echo 'fastq_id|sample_name|summary_field|value' > ${{NGSruns_folder}}/{avt_run}_Summaries/all_summary.csv")
    for idx, (sample_name, fastq) in enumerate(pairs, start=1):
        numbered_dir = f'$(printf "%02d" {idx})_{sample_name}_atac'
        sample_atac_id = f"{sample_name}_atac"
        lines.append(
            f"sed 1d ${{NGSruns_folder}}/{numbered_dir}/ats/bam/pipeline_info/summary.csv 2>/dev/null | "
            f"awk -F',' '{{print \"{fastq}|{sample_name}|$0\"}}' >> ${{NGSruns_folder}}/{avt_run}_Summaries/all_summary.csv || true"
        )
    lines.append("")

    lines.append("")
    lines.extend("""
#### Arguments TO BE EDITED ----> ARGUMENTS BELOW ARE FOR MULTIOME 
# --id	Required. A unique run ID string (e.g., sample345). The name is arbitrary and will be used to name the directory containing all pipeline-generated files and outputs. Only letters, numbers, underscores, and hyphens are allowed (maximum of 64 characters).
# --libraries	Path to a 3-column CSV file declaring FASTQ paths, sample names and library types of input ATAC and GEX FASTQs. The libraries CSV format is described here.
# --reference	Path to the cellranger-arc-compatible reference package. References for human and mouse are available for download. Custom references can be constructed as described here.

# --description	Sample description to embed into output files
# --gex-exclude-introns	Disable counting of intronic reads. In this mode we only count reads that are exonic and compatible with annotated splice junctions in the reference. Note: using this mode will reduce the UMI counts in the count matrix.
# --min-atac-count	Cell caller override: define the minimum number of ATAC transposition events in peaks (ATAC counts) for a cell barcode. Note: this option must be specified in conjunction with `min-gex-count`. With `--min-atac-count=X` and `--min-gex-count=Y` a barcode is defined as a cell if it contains at least X ATAC counts AND at least Y GEX UMI counts. It is advisable to use these parameters only after reviewing the web summary generated using default parameters.
# --min-gex-count	Cell caller override: define the minimum number of GEX UMI counts for a cell barcode. Note: this option must be specified in conjunction with `min-atac-count`. With `--min- atac-count=X` and `--min-gex-count=Y` a barcode is defined as a cell if it contains at least X ATAC counts AND at least Y GEX UMI counts. It is advisable to use these parameters only after reviewing the web summary generated using default parameters.
# --no-bam	Skip BAM file generation. This will reduce the total computation time for the pipestance and the size of the output directory. If unsure, it is recommended not to use this option, as BAM files can be useful for troubleshooting and downstream analysis. Default: false.
# --peaks	Peak-caller override: specify peaks to use in downstream analyses from supplied BED file. Note that the file must only contain three columns specifying the contig, start, and end of the peaks. The peaks must not overlap each other. The file must be sorted by position with the same chromosome order as the reference package. The file is allowed to contain comment lines beginning with `#`.
# --localcores	Restricts cellranger-arc to use specified number of cores to execute pipeline stages. By default, cellranger-arc will use all of the cores available on your system.
# --localmem	Restricts cellranger-arc to use specified amount of memory (in GB) to execute pipeline stages. By default, cellranger-arc will use 90% of the memory available on your system.



rsync -aqrW ${{Server_folder}} ${{NGSruns_folder}}
""".strip("\n").splitlines())

    return "\n".join(lines) + "\n"

def main():
    parser = argparse.ArgumentParser(
        description=(
            "Parses one or more Excel sheets and generates a cellranger-atac_AVT0XXX.sh "
            'script with one "cellranger-atac count" block per sample.'
        ),
        epilog="Example:\n  python3 %(prog)s samples.xlsx\n  python3 %(prog)s run1.xlsx run2.xlsx run3.xlsx",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "xlsx_files",
        nargs="+",
        help=(
            "One or more Excel files containing at least the columns "
            "'GECF fastq ID (avidxxxx)' and 'Sample name'. "
            "A cell containing the run name (e.g. AVT0226) is also "
            "searched for automatically."
        ),
    )
    parser.add_argument(
        "--non-interactive", "-n",
        action="store_true",
        default=False,
        help="Skip all prompts, use detected values and human genome as defaults.",
    )
    args = parser.parse_args()

    global NON_INTERACTIVE
    NON_INTERACTIVE = args.non_interactive
    xlsx_files = args.xlsx_files

    all_pairs = []
    all_detected_avts = []

    for xlsx_file in xlsx_files:
        if not os.path.isfile(xlsx_file):
            sys.exit(f"Error: file '{xlsx_file}' does not exist.")
        if not xlsx_file.lower().endswith(".xlsx"):
            sys.exit(f"Error: '{xlsx_file}' does not look like an .xlsx file.")

        pairs, detected_avt = parse_xlsx(xlsx_file)
        if not pairs:
            print(f"Warning: no sample/fastq ID pairs found in '{xlsx_file}' — skipping.")
            continue

        all_pairs.extend(pairs)
        if detected_avt:
            all_detected_avts.append(detected_avt)

    if not all_pairs:
        sys.exit("Error: no sample/fastq ID pairs could be parsed from the provided file(s).")

    print()
    print(f"Total: {len(all_pairs)} sample(s) from {len(xlsx_files)} Excel file(s):")
    print_pairs_table(all_pairs)
    print()

    # If all files share the same AVT, use it. Otherwise let user decide (or pick first in non-interactive).
    if len(set(all_detected_avts)) == 1:
        detected_avt = all_detected_avts[0]
    elif len(set(all_detected_avts)) > 1:
        print(f"Warning: different run names detected ({', '.join(sorted(set(all_detected_avts)))}).")
        print("Using the first one as default — you can change it below.")
        detected_avt = all_detected_avts[0]
    else:
        detected_avt = None

    avt_run = ask_avt_run(detected_avt)
    if not avt_run:
        sys.exit("Error: AVT run name cannot be empty.")

    reference_genome = ask_reference_genome()

    script_content = build_script(avt_run, reference_genome, all_pairs)

    out_script = f"cellranger-atac_{avt_run}.sh"
    with open(out_script, "w") as f:
        f.write(script_content)
    os.chmod(out_script, 0o755)

    print(f"Generated: {out_script}")
    print("Review it, fill in Server_folder / NGSruns_folder, and adjust fastq paths if needed.")


if __name__ == "__main__":
    main()
