from pathlib import Path

from openpyxl import Workbook


OUT = Path(__file__).parent
DNA_HEADER = ["Position", "Name", "Task", "Quantity"]
PRIMER_HEADER = ["Position", "Name/Detector", "Reporter", "Quencher"]


def save_book(filename, sheets):
    workbook = Workbook()
    workbook.remove(workbook.active)
    for title, rows in sheets:
        sheet = workbook.create_sheet(title)
        for row in rows:
            sheet.append(row)
    workbook.save(OUT / filename)


def dna_book(filename, rows, header=DNA_HEADER, extra_sheets=()):
    save_book(filename, [("DNA", [header, *rows]), *extra_sheets])


def primer_book(filename, rows, header=PRIMER_HEADER, extra_sheets=()):
    save_book(filename, [("PRIMER", [header, *rows]), *extra_sheets])


def make_clean():
    dna_rows = [
        [1, "NTC", "NTC", 0],
        [2, "Std1", "STND", 10],
        [3, "Std2", "STND", 20],
        [4, "Std3", "STND", 30],
        [5, "Std4", "STND", 40],
        [6, "Std5", "STND", 50],
        [7, "Std6", "STND", 60],
    ]
    primer_rows = [
        [1, "AssayA", "FAM", "FAM"],
        [2, "AssayB", "VIC", "VIC"],
    ]
    dna_book("clean_dna.xlsx", dna_rows)
    primer_book("clean_primer.xlsx", primer_rows)
    save_book("dna_and_primer_sheets.xlsx", [
        ("DNA", [DNA_HEADER, *dna_rows]),
        ("PRIMER", [PRIMER_HEADER, *primer_rows]),
    ])


def make_dna_fixtures():
    save_book("dna_missing_sheet.xlsx", [("PRIMER", [["placeholder"]])])
    dna_book("dna_bad_header.xlsx", [[1, "NTC", "NTC", 0]], ["Pos", "Sample", "Type", "Amount"])
    dna_book("dna_invalid_name.xlsx", [
        [1, "Bad Name!", "UNKN", 0],
        [2, "Std1", "STND", 10],
        [3, "Std2", "STND", 20],
        [4, "Std3", "STND", 30],
        [5, "NTC", "NTC", 0],
    ])
    dna_book("dna_duplicate_sample.xlsx", [
        [1, "SampleA", "UNKN", 0],
        [2, "samplea", "UNKN", 0],
        [3, "NTC", "NTC", 0],
    ])
    dna_book("dna_invalid_task.xlsx", [[1, "SampleA", "BAD", 0]])
    dna_book("dna_quantity_errors.xlsx", [
        [1, "NTC", "NTC", 1],
        [2, "Unknown1", "UNKN", 1],
        [3, "Standard1", "STND", "1.5"],
    ])
    dna_book("dna_missing_controls.xlsx", [[1, "SampleA", "UNKN", 0]])
    dna_book("dna_few_standards_warning.xlsx", [
        [1, "SampleA", "UNKN", 0],
        [2, "Std1", "STND", 10],
        [3, "Std2", "STND", 20],
        [4, "Std3", "STND", 30],
        [5, "Std4", "STND", 40],
        [6, "Std5", "STND", 50],
    ])
    dna_book("dna_incomplete_row.xlsx", [
        [1, "NTC", "NTC", 0],
        [2, "SampleWithoutTask", None, 0],
    ])

    capacity_rows = [[1, "NTC", "NTC", 0]]
    capacity_rows.extend([position, f"Sample{position}", "UNKN", 0] for position in range(2, 73))
    dna_book("dna_sample_capacity_warning.xlsx", capacity_rows)

    hard_cap_rows = [[1, "NTC", "NTC", 0]]
    hard_cap_rows.extend([position, f"Sample{position}", "UNKN", 0] for position in range(2, 195))
    dna_book("dna_gui_hard_cap_failure.xlsx", hard_cap_rows)


def make_primer_fixtures():
    save_book("primer_missing_sheet.xlsx", [("DNA", [["placeholder"]])])
    primer_book("primer_bad_header.xlsx", [[1, "AssayA", "FAM", "FAM"]], ["Pos", "Name", "Dye", "Quench"])
    primer_book("primer_reporter_errors.xlsx", [
        [1, "AssayBadReporter", "GREEN", "GREEN"],
        [2, "AssayDifferentQuencher", "FAM", "VIC"],
    ])
    primer_book("primer_duplicate_name.xlsx", [
        [1, "AssayA", "FAM", "FAM"],
        [2, "assaya", "VIC", "VIC"],
    ])

    warning_rows = [[position, f"Assay{position}", "FAM", "FAM"] for position in range(1, 72)]
    primer_book("primer_plate_capacity_warning.xlsx", warning_rows)

    hard_cap_rows = [[position, f"Assay{position}", "FAM", "FAM"] for position in range(1, 66)]
    primer_book("primer_gui_hard_cap_failure.xlsx", hard_cap_rows)


def main():
    OUT.mkdir(exist_ok=True)
    make_clean()
    make_dna_fixtures()
    make_primer_fixtures()
    print(f"Created test workbooks in {OUT}")


if __name__ == "__main__":
    main()
