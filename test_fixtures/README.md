# qPCR validator fixtures

Run from the repository root:

```powershell
python .\test_fixtures\create_test_fixtures.py
python .\test_fixtures\run_fixture_checks.py
```

The generator creates `.xlsx` files with separate clean DNA and PRIMER workbooks, plus focused invalid cases.

| Fixture | Main condition |
|---|---|
| `clean_dna.xlsx` | Valid DNA-only workbook |
| `clean_primer.xlsx` | Valid PRIMER-only workbook |
| `dna_and_primer_sheets.xlsx` | DNA and PRIMER sheets together (invalid) |
| `dna_missing_sheet.xlsx` | Missing DNA sheet |
| `dna_bad_header.xlsx` | DNA header mismatch |
| `dna_invalid_name.xlsx` | Unauthorized name characters |
| `dna_duplicate_sample.xlsx` | Case-insensitive duplicate sample |
| `dna_invalid_task.xlsx` | Invalid task value and missing controls/standards |
| `dna_quantity_errors.xlsx` | Nonzero NTC/UNKN quantities and decimal STND quantity |
| `dna_missing_controls.xlsx` | Missing NTC and standard curve |
| `dna_few_standards_warning.xlsx` | Five STND samples; recommends at least six |
| `dna_incomplete_row.xlsx` | Sample row without task |
| `dna_sample_capacity_warning.xlsx` | More than 70 unique samples on a 96-well plate |
| `dna_gui_hard_cap_failure.xlsx` | More than 192 DNA rows |
| `primer_missing_sheet.xlsx` | Missing PRIMER sheet |
| `primer_bad_header.xlsx` | PRIMER header mismatch |
| `primer_reporter_errors.xlsx` | Invalid reporter; different quencher is allowed |
| `primer_duplicate_name.xlsx` | Case-insensitive duplicate primer |
| `primer_plate_capacity_warning.xlsx` | More than 70 primers on a 96-well plate |
| `primer_gui_hard_cap_failure.xlsx` | More than 64 unique primer names |

The validators also check workbook readability, `.xls` extension failures, blank/empty files, numeric positions when present, and file-type detection. Each qPCR workbook must contain either a DNA sheet or a PRIMER sheet, not both. The fixture set uses `.xlsx` because it is portable and can be generated with `openpyxl`.
