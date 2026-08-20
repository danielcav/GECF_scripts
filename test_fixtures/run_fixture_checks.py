from pathlib import Path
import importlib.util


ROOT = Path(__file__).parents[1]
FIXTURES = Path(__file__).parent
spec = importlib.util.spec_from_file_location("qpcr_validation", ROOT / "qpcr_validation.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)

VALIDATORS = {
    "clean_dna.xlsx": ("dna",),
    "clean_primer.xlsx": ("primer",),
    "dna_and_primer_sheets.xlsx": ("structure",),
    "dna_missing_sheet.xlsx": ("dna",),
    "dna_bad_header.xlsx": ("dna",),
    "dna_invalid_name.xlsx": ("dna",),
    "dna_duplicate_sample.xlsx": ("dna",),
    "dna_invalid_task.xlsx": ("dna",),
    "dna_quantity_errors.xlsx": ("dna",),
    "dna_missing_controls.xlsx": ("dna",),
    "dna_few_standards_warning.xlsx": ("dna",),
    "dna_incomplete_row.xlsx": ("dna",),
    "dna_sample_capacity_warning.xlsx": ("dna",),
    "dna_gui_hard_cap_failure.xlsx": ("dna",),
    "primer_missing_sheet.xlsx": ("primer",),
    "primer_bad_header.xlsx": ("primer",),
    "primer_reporter_errors.xlsx": ("primer",),
    "primer_duplicate_name.xlsx": ("primer",),
    "primer_plate_capacity_warning.xlsx": ("primer",),
    "primer_gui_hard_cap_failure.xlsx": ("primer",),
}


def severity(messages):
    if any(message.kind == validator.Issue.FAIL for message in messages):
        return "fail"
    if any(message.kind == validator.Issue.WARN for message in messages):
        return "warn"
    return "ok"


def main():
    missing = [name for name in VALIDATORS if not (FIXTURES / name).exists()]
    if missing:
        raise SystemExit(
            "Missing fixtures. Run: python .\\test_fixtures\\create_test_fixtures.py\n"
            + "\n".join(missing)
        )

    failed = False
    functions = {
        "dna": validator.validate_dna_list,
        "primer": validator.validate_primer_list,
        "structure": validator.validate_sheet_selection,
    }
    for name, validator_names in VALIDATORS.items():
        path = str(FIXTURES / name)
        results = []
        for validator_name in validator_names:
            result = functions[validator_name](path)
            messages = result if validator_name == "structure" else result[0]
            results.append(f"{validator_name}={severity(messages)}")
        print(f"{name}: {', '.join(results)}")


if __name__ == "__main__":
    main()
