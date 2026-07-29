#!/usr/bin/env python3
"""
fasta_to_gtf.py

Generate a cellranger-arc mkref-compatible GTF from a multi-FASTA file
containing custom genes/contigs (one contig per gene).

For each FASTA record, writes 4 GTF lines (gene, transcript, exon, CDS)
spanning the full length of the sequence, on the + strand.

Usage:
    python fasta_to_gtf.py input.fasta output.gtf

Notes:
    - The FASTA header token before the first whitespace is used as the
      contig/gene name (anything after is treated as a description and
      dropped, matching standard FASTA header parsing).
    - Underscores in names are replaced with hyphens, since cellranger-arc
      mkref does not allow underscores in contig names (it reads text after
      "_" as a species identifier for multi-species references).
    - Also writes a cleaned FASTA (same basename + ".clean.fasta") with
      headers sanitized to match the GTF contig names exactly, since the
      FASTA and GTF must use identical contig names.
"""

import sys
import re
from pathlib import Path


def sanitize_name(name: str) -> str:
    """Replace underscores, slashes, and disallowed characters with hyphens."""
    name = name.replace("_", "-")
    name = name.replace("/", "-")
    # keep it conservative: letters, numbers, hyphens, dots only
    name = re.sub(r"[^A-Za-z0-9\.\-]", "-", name)
    # collapse repeated hyphens (e.g. "ZNF642 / ZFP69" -> "ZNF642-ZFP69", not "ZNF642---ZFP69")
    name = re.sub(r"-{2,}", "-", name)
    name = name.strip("-")
    return name


def parse_fasta(path):
    """Yield (header_id, sequence) tuples from a FASTA file."""
    header = None
    seq_chunks = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith(">"):
                if header is not None:
                    yield header, "".join(seq_chunks)
                # header format: "name | description | ..."  -> take field before first "|"
                # falls back to first whitespace token if no "|" is present
                raw = line[1:]
                if "|" in raw:
                    header = raw.split("|")[0].strip()
                else:
                    header = raw.split()[0]
                seq_chunks = []
            else:
                seq_chunks.append(line.strip())
        if header is not None:
            yield header, "".join(seq_chunks)


def main():
    if len(sys.argv) != 3:
        print("Usage: python fasta_to_gtf.py input.fasta output.gtf")
        sys.exit(1)

    in_fasta = Path(sys.argv[1])
    out_gtf = Path(sys.argv[2])
    out_fasta = out_gtf.with_suffix("")
    out_fasta = Path(str(out_fasta) + ".clean.fasta")

    seen_names = set()
    records = list(parse_fasta(in_fasta))

    if not records:
        print("No sequences found in input FASTA. Aborting.")
        sys.exit(1)

    with open(out_gtf, "w") as gtf, open(out_fasta, "w") as fasta_out:
        for raw_name, seq in records:
            length = len(seq)
            if length == 0:
                print(f"WARNING: sequence '{raw_name}' has zero length, skipping.")
                continue

            name = sanitize_name(raw_name)

            if name != raw_name:
                print(f"Renamed '{raw_name}' -> '{name}' (removed underscores/invalid chars)")

            if name in seen_names:
                print(f"ERROR: duplicate contig name '{name}' after sanitization. Aborting.")
                sys.exit(1)
            seen_names.add(name)

            attrs = (
                f'gene_id "{name}"; transcript_id "{name}mRNA"; '
                f'gene_name "{name}"; gene_biotype "protein_coding";'
            )

            gtf.write(f"{name}\tcustom\tgene\t1\t{length}\t.\t+\t.\t{attrs}\n")
            gtf.write(f"{name}\tcustom\ttranscript\t1\t{length}\t.\t+\t.\t{attrs}\n")
            gtf.write(f"{name}\tcustom\texon\t1\t{length}\t.\t+\t.\t{attrs}\n")
            gtf.write(f"{name}\tcustom\tCDS\t1\t{length}\t.\t+\t.\t{attrs}\n")

            fasta_out.write(f">{name}\n")
            for i in range(0, length, 60):
                fasta_out.write(seq[i:i + 60] + "\n")

    print(f"\nDone. {len(seen_names)} genes written.")
    print(f"GTF:   {out_gtf}")
    print(f"FASTA: {out_fasta}  (headers sanitized to match GTF contig names)")


if __name__ == "__main__":
    main()