#!/usr/bin/env python3
"""GECF qPCR Hamilton Template Validator - Dashboard GUI v5.04

Validates DNA/PRIMER/Hamilton Excel files at GECF Frankfurt.

Usage:
    python qpcr-dashboard.py [--cli] [file ... | --dir DIR]
"""

import sys
import glob
import argparse
from pathlib import Path
from datetime import datetime

import tkinter as tk
from tkinter import filedialog, messagebox, ttk


# ---------------------------------------------------------------------------
# Validation core
# ---------------------------------------------------------------------------

_CORE = Path(__file__).parent / "qpcr_validation.py"

if not _CORE.exists():
    raise SystemExit(f"Validation core missing: {_CORE}")

import importlib.util as _il

_sp = _il.spec_from_file_location("qvc", str(_CORE))
qvc = _il.module_from_spec(_sp)
_sp.loader.exec_module(qvc)

del _il, _sp


# ---------------------------------------------------------------------------
# Colours / GUI constants
# ---------------------------------------------------------------------------

C_HDR = "#2c3e50"
C_OK = "#0fa657"
C_WN = "#de9b34"
C_FL = "#da3f3b"
C_BG = "#fafafa"

HW = "860x620"


# ---------------------------------------------------------------------------
# Validation runner
# ---------------------------------------------------------------------------

def _run(fp):
    """Run all applicable validators against one file."""
    structure_errors = qvc.validate_sheet_selection(fp)
    if structure_errors:
        return structure_errors

    types = qvc.detect_file_type(fp)
    if "read_error" in types:
        return [qvc.Issue(
            qvc.Issue.FAIL,
            f"{Path(fp).name}: The workbook could not be read. "
            "Check that it is a valid Excel file.",
        )]
    if not types or types == ["unknown"]:
        return [qvc.Issue(
            qvc.Issue.FAIL,
            f"{Path(fp).name}: File type is unknown. "
            "The workbook must contain a DNA or PRIMER sheet.",
        )]

    out = []
    validators = {
        "dna_list": qvc.validate_dna_list,
        "primer_list": qvc.validate_primer_list,
    }
    for file_type in types:
        validator = validators.get(file_type)
        if validator:
            out.extend(validator(fp)[0])

    return out


# ---------------------------------------------------------------------------
# CLI runner
# ---------------------------------------------------------------------------

def _cli(paths):
    """Run validation in text/CLI mode."""
    if not paths:
        print("\n  No files to check.", file=sys.stderr)
        return 1, 0
    fails = 0
    warns = 0
    cnt = 0
    for fp in paths:
        msgs = _run(fp)
        cnt += 1
        bn = Path(fp).name
        pad = " " * max(1, 34 - len(bn))
        print(
            f"\n{'=' * 79}\n"
            f" \u250c--- {bn}{pad}\u2510\n"
            f"| File: {fp}|"
        )

        for m in msgs:
            sym = {
                "ok": "\u2713",
                "warn": "!",
                "fail": "X",
            }[m.kind]
            clr = {
                "ok": "\033[92m",
                "warn": "\033[93m",
                "fail": "\033[91m",
            }[m.kind]

            print(f"| {clr}{sym}\033[0m  {m.text}|")

        fails += sum(
            1 for m in msgs
            if m.kind == qvc.Issue.FAIL
        )
        warns += sum(
            1 for m in msgs
            if m.kind == qvc.Issue.WARN
        )
    print(
        f"\n{'=' * 79}\n"
        f" Checked: {cnt} file(s), "
        f"{fails} fail(s), {warns} warning(s)"
    )

    return bool(fails), cnt


# ---------------------------------------------------------------------------
# Dashboard GUI
# ---------------------------------------------------------------------------

class App(tk.Tk):

    def __init__(self):
        super().__init__()
        self.title("GECF qPCR Validator v5.04")
        self.geometry(HW)
        self.minsize(700, 450)
        self.files = []

        # ttk styling
        style = ttk.Style()

        try:
            style.configure(
                ".",
                background=C_BG,
                font=("Segoe UI", 10),
            )
        except tk.TclError:
            pass
        self._build()

    # -----------------------------------------------------------------------
    # Build GUI
    # -----------------------------------------------------------------------

    def _build(self):
# Root grid configuration
        self.grid_rowconfigure(3, weight=1)
        self.grid_columnconfigure(0, weight=1)

        # -------------------------------------------------------------------
        # Header
        # -------------------------------------------------------------------

        self._hdr = tk.Frame(
            self,
            bg=C_HDR,
            height=48,
        )

        self._hdr.grid(
            row=0,
            column=0,
            columnspan=2,
            sticky="ew",
        )

        self._hdr.pack_propagate(False)

        tk.Label(
            self._hdr,
            text=" GECF qPCR Template Validator",
            fg="#ffffff",
            bg=C_HDR,
            font=("Segoe UI", 13),
        ).pack(
            side="left",
            pady=7,
        )

        now = datetime.now().strftime("%Y-%m-%d %H:%M")

        self._ts = tk.Label(
            self._hdr,
            text=f"  {now}  ",
            fg="#aeb6bf",
            bg=C_HDR,
            font=("Segoe UI", 9),
        )

        self._ts.pack(
            side="right",
            padx=14,
        )

        # -------------------------------------------------------------------
        # Stats bar
        # -------------------------------------------------------------------

        self._sb = tk.Frame(
            self,
            bg="#ecf0f1",
            height=38,
        )

        self._sb.grid(
            row=1,
            column=0,
            columnspan=2,
            sticky="ew",
        )

        self._lb_ok = tk.Label(
            self._sb,
            text="\u2713 0",
            bg="#ecf0f1",
            fg=C_OK,
            font=("Segoe UI", 11, "bold"),
        )

        self._lb_ok.pack(
            side="left",
            padx=40,
            fill="y",
            anchor="center",
        )

        self._lb_warn = tk.Label(
            self._sb,
            text="\u26a0 0",
            bg="#ecf0f1",
            fg=C_WN,
            font=("Segoe UI", 11, "bold"),
        )

        self._lb_warn.pack(
            side="left",
            padx=40,
            fill="y",
            anchor="center",
        )

        self._lb_fail = tk.Label(
            self._sb,
            text="\u274c 0",
            bg="#ecf0f1",
            fg=C_FL,
            font=("Segoe UI", 11, "bold"),
        )

        self._lb_fail.pack(
            side="left",
            padx=40,
            fill="y",
            anchor="center",
        )

        # -------------------------------------------------------------------
        # Progress / buttons
        # -------------------------------------------------------------------

        self._pb = tk.Frame(
            self,
            bg=C_BG,
            height=38,
        )

        self._pb.grid(
            row=2,
            column=0,
            columnspan=2,
            sticky="ew",
        )

        self._pb.pack_propagate(False)

        btns = tk.Frame(
            self._pb,
            bg=C_BG,
        )

        btns.pack(
            side="left",
            padx=16,
            pady=4,
        )

        self._btn_pick = ttk.Button(
            btns,
            text="\u2191 Select files",
            command=self._pick,
        )

        self._btn_pick.pack(
            side="left",
        )

        self._bar = ttk.Progressbar(
            self._pb,
            mode="determinate",
            length=360,
        )

        self._canvas = tk.Canvas(
            self,
            bg=C_BG,
            highlightthickness=0,
        )

        self._canvas.grid(
            row=3,
            column=0,
            sticky="nsew",
        )

        self._scrollbar = ttk.Scrollbar(
            self,
            orient="vertical",
            command=self._canvas.yview,
        )

        self._scrollbar.grid(
            row=3,
            column=1,
            sticky="ns",
        )

        self._canvas.configure(
            yscrollcommand=self._scrollbar.set,
        )

        self._cards = tk.Frame(
            self._canvas,
            bg=C_BG,
        )

        self._canvas_window = self._canvas.create_window(
            (4, 4),
            window=self._cards,
            anchor="nw",
        )

        self._cards.bind(
            "<Configure>",
            self._update_scrollregion,
        )

        self._canvas.bind(
            "<Configure>",
            self._resize_cards,
        )

        # Mouse-wheel scrolling
        self._canvas.bind_all(
            "<MouseWheel>",
            self._mousewheel,
        )

    # -----------------------------------------------------------------------
    # Scroll handling
    # -----------------------------------------------------------------------

    def _update_scrollregion(self, event=None):
        self._canvas.configure(
            scrollregion=self._canvas.bbox("all")
        )

    def _resize_cards(self, event):
        self._canvas.itemconfigure(
            self._canvas_window,
            width=max(event.width - 8, 1),
        )

    def _mousewheel(self, event):
        self._canvas.yview_scroll(
            int(-1 * (event.delta / 120)),
            "units",
        )

    # -----------------------------------------------------------------------
    # Result card
    # -----------------------------------------------------------------------

    def _add_card(
        self,
        fp,
        ok,
        warn,
        fail_count,
        msgs,
    ):

        worst = "fail" if fail_count else ("warn" if warn else "ok")

        col = {
            "ok": C_OK,
            "warn": C_WN,
            "fail": C_FL,
        }[worst]

        sym = {
            "ok": "\u2714",
            "warn": "\u26a0",
            "fail": "\u274c",
        }[worst]

        # ---------------------------------------------------------------
        # Card header
        # ---------------------------------------------------------------

        hd = tk.Frame(
            self._cards,
            bg=col,
            height=36,
        )

        hd.pack(
            fill="x",
            pady=(12, 0),
            padx=20,
        )

        hd.pack_propagate(False)

        bn = Path(fp).name

        detected_types = qvc.detect_file_type(fp)

        if detected_types:
            fl = detected_types[0].replace(
                "_",
                " ",
            ).title()
        else:
            fl = "Unknown"

        tk.Label(
            hd,
            text=f" {sym}  {bn}  [{fl}]",
            fg="#ffffff",
            bg=col,
            font=("Segoe UI", 10),
            anchor="w",
        ).pack(
            side="left",
            anchor="n",
            padx=4,
        )

        cnt = warn + fail_count

        tk.Label(
            hd,
            text=f"\u2014 {cnt} issue(s)",
            fg="#dddddd",
            bg=col,
            font=("Segoe UI", 9),
        ).pack(
            side="right",
            anchor="n",
            padx=6,
        )

        # ---------------------------------------------------------------
        # Card body
        # ---------------------------------------------------------------

        bd = tk.Frame(
            self._cards,
            bg="#ffffff",
        )

        bd.pack(
            fill="x",
            padx=20,
            pady=(2, 0),
        )

        # ---------------------------------------------------------------
        # Clipboard text
        # ---------------------------------------------------------------

        clipboard_lines = [
            f"{fp} ({fl})"
        ]

        for m in msgs:
            emj = {
                "ok": "\u2713",
                "warn": "\u26a0",
                "fail": "\u2717",
            }[m.kind]

            clipboard_lines.append(
                f"  {emj}  {m.text}"
            )
        clip_text = "\n".join(
            clipboard_lines
        )

        # ---------------------------------------------------------------
        # Copy button
        # ---------------------------------------------------------------

        rt = tk.Frame(
            self._cards,
            bg="#ffffff",
        )

        rt.pack(
            fill="x",
            padx=58,
            pady=(0, 4),
        )

        btn = tk.Label(
            rt,
            text="\U0001F4CB Copy card to clipboard",
            fg="#5dade2",
            bg="#ffffff",
            font=("Segoe UI", 9),
            cursor="hand2",
        )

        btn.pack(
            side="right",
        )

        def _copy():
            self.clipboard_clear()
            self.clipboard_append(clip_text)
            self.update()

            btn.config(
                text="Copied \u2713"
            )

            self.after(
                1200,
                lambda: btn.config(
                    text="\U0001F4CB Copy card to clipboard"
                ),
            )

        btn.bind(
            "<Button-1>",
            lambda event: _copy(),
        )

        # ---------------------------------------------------------------
        # Issue detail labels
        # ---------------------------------------------------------------

        for m in msgs:

            emj = {
                "ok": "\u2713",
                "warn": "\u26a0",
                "fail": "\u2717",
            }[m.kind]

            fcol = {
                "ok": C_OK,
                "warn": C_WN,
                "fail": C_FL,
            }[m.kind]

            tk.Label(
                bd,
                text=f" {emj}  {m.text}",
                fg=fcol,
                bg="#ffffff",
                font=("Segoe UI", 10),
                anchor="w",
                justify="left",
            ).pack(
                fill="x",
                padx=8,
                pady=(1, 1),
            )

        # Bottom spacing
        tk.Frame(
            self._cards,
            bg=C_BG,
            height=1,
        ).pack(
            fill="x",
        )

    # -----------------------------------------------------------------------
    # File picker
    # -----------------------------------------------------------------------

    def _pick(self):
        fps = filedialog.askopenfilenames(
            title="Select qPCR Excel files",
            filetypes=[
                (
                    "Excel files",
                    "*.xls *.xlsx *.xlsm",
                ),
                (
                    "All files",
                    "*.*",
                ),
            ],
        )
        self.files = sorted(set(fps))
        self._validate_and_update()

    # -----------------------------------------------------------------------
    # Validation and GUI update
    # -----------------------------------------------------------------------

    def _validate_and_update(self):
        if not self.files:
            messagebox.showinfo(
                "Nothing to check",
                "Please select files first.",
            )
            return
        total = len(self.files)
        self._bar["maximum"] = total
        self._bar["value"] = 0
        self.update_idletasks()

        # Clear previous cards
        for widget in self._cards.winfo_children():
            widget.destroy()
        n_ok = 0
        n_warn = 0
        n_fail = 0
        for i, fp in enumerate(self.files):
            try:
                msgs = _run(fp)
            except Exception as exc:
                # Don't crash the entire dashboard if one file fails.
                msgs = [
                    qvc.Issue(
                        qvc.Issue.FAIL,
                        f"Validation error: {exc}",
                    )
                ]
            oc = sum(
                1
                for m in msgs
                if m.kind == qvc.Issue.OK
            )
            fc = sum(
                1
                for m in msgs
                if m.kind == qvc.Issue.FAIL
            )
            wc = sum(
                1
                for m in msgs
                if m.kind == qvc.Issue.WARN
            )
            n_ok += oc
            n_warn += wc
            n_fail += fc
            self._add_card(
                fp,
                oc,
                wc,
                fc,
                msgs,
            )
            self._bar["value"] = i + 1
            self.update_idletasks()

        # Update summary
        self._lb_ok.config(
            text=f"\u2713 {n_ok}"
        )
        self._lb_warn.config(
            text=f"\u26a0 {n_warn}"
        )
        self._lb_fail.config(
            text=f"\u274c {n_fail}"
        )
        self.after(
            100,
            lambda: self._bar.config(
                value=total
            ),
        )
        self._canvas.yview_moveto(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
        description=(
            "GECF qPCR Hamilton Template "
            "Validator v5.04"
        )
    )

    parser.add_argument(
        "--cli",
        action="store_true",
        help="Text output mode (no GUI)",
    )

    parser.add_argument(
        "files",
        nargs="*",
        help="Excel files to validate",
    )

    parser.add_argument(
        "--dir",
        dest="directory",
        help="Scan directory for qPCR Excel files",
    )

    args = parser.parse_args()

    # -----------------------------------------------------------------------
    # CLI mode
    # -----------------------------------------------------------------------

    if args.cli:

        srcs = list(args.files)

        if args.directory:

            for ext in (
                "*.xls",
                "*.xlsx",
                "*.xlsm",
            ):
                srcs.extend(
                    glob.glob(
                        f"{args.directory}/**/{ext}",
                        recursive=True,
                    )
                )
            srcs = sorted(set(srcs))

        if not srcs:
            parser.print_help()
            sys.exit(1)

        failed, count = _cli(srcs)

        sys.exit(
            1 if failed else 0
        )

    # -----------------------------------------------------------------------
    # GUI mode
    # -----------------------------------------------------------------------

    else:

        srcs = list(args.files)

        if args.directory:

            for ext in (
                "*.xls",
                "*.xlsx",
                "*.xlsm",
            ):
                srcs.extend(
                    glob.glob(
                        f"{args.directory}/**/{ext}",
                        recursive=True,
                    )
                )

        app = App()

        app.files = sorted(
            set(srcs)
        )

        if app.files:
            app._validate_and_update()

        app.mainloop()
