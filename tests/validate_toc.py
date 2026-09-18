from pathlib import Path
import os

root = Path(__file__).resolve().parent.parent
tocs = list(root.glob("*.toc"))
assert len(tocs) == 1, "Expected one Retail TOC"
toc = tocs[0]
metadata = {}
for line in toc.read_text(encoding="utf-8-sig").splitlines():
    line = line.strip()
    if line.startswith("## ") and ":" in line:
        key, value = line[3:].split(":", 1)
        metadata[key] = value.strip()
    elif line and not line.startswith("#"):
        path = root / line.replace("\\\\", "/").replace("\\", "/")
        assert path.is_file(), f"Missing TOC dependency: {line}"
assert metadata["Interface"] == "120100", "Expected Retail 12.1"
if os.environ.get("GITHUB_REF_TYPE") == "tag":
    assert os.environ["GITHUB_REF_NAME"] == "v" + metadata["Version"], "Tag must match TOC version"
print(f"{toc.name}: TOC and dependencies valid")
