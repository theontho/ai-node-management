# AI Node System Inventory

Generate a self-contained, private dashboard describing a Linux or Windows AI
node's hardware, accounts, storage, network interfaces, relevant services, and
installed development and agent tools.

The report includes account names, IP and MAC addresses, device serial numbers,
volume labels, and paths for large directories and files. It deliberately
omits credentials, authentication secrets, environment-variable values, and
file contents. Reports are generated under the ignored `output/` directory and
must be treated as private.

## Generate a report

Python 3.10 or later is required. Run this on the node host, rather than inside
an application container, so the report describes the full machine:

```bash
python3 ./collect.py
```

On Windows:

```powershell
python .\collect.py
```

The dashboard is written to `output/latest/index.html`, with the same snapshot
available as `inventory.json` for automation. Open the HTML file directly or
serve the directory with:

```bash
python3 -m http.server --directory output/latest 8000
```

The report is point-in-time data. Rerun the collector whenever the node's
hardware, storage, accounts, addresses, or toolchain changes. By default, the
collector makes one read-only pass over mounted local volumes, excludes
symlinks and reparse points, and reports top-level usage, the 20 largest
directories at any depth, and the 50 largest files. Each large top-level
directory also shows immediate subdirectories that occupy at least 2% of it
and at least 100 MiB. This can take several minutes on nodes with millions of
files.

Use `--skip-storage-scan` for a fast hardware-only refresh. Adjust the retained
rankings with `--top-items` and `--largest-files`.
