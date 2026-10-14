#!/usr/bin/env python3
"""Prepare private Wine/GStreamer copies for subsequent bundle signing.

Never runs Wine, installer scripts, or bundled helpers. Never changes system
frameworks or removes quarantine. Input provenance is pinned; native load commands
in OUTPUT copies are rewritten, so the packager must sign them afterwards.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

WINE_SHA = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
WINE_BYTES = 185303032
GST_SHA = "02803f73435daabe8fb12b79c38c6775d0efb83af001474558ba25c4f874d305"
GST_BYTES = 151846922
GST_PREFIX = "/Library/Frameworks/GStreamer.framework/"
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
MACH_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
LOAD_RE = re.compile(r"cmd (LC_(?:LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD|LAZY_LOAD|ID)_DYLIB)\s+cmdsize \d+\s+name (.*?) \(offset")
RPATH_RE = re.compile(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset")


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=check, text=True, capture_output=True)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def within(path: Path, parent: Path) -> bool:
    return path.resolve().is_relative_to(parent.resolve())


def quarantine(path: Path) -> bytes | None:
    result = run(["/usr/bin/xattr", "-px", "com.apple.quarantine", str(path)], check=False)
    return bytes.fromhex(result.stdout) if result.returncode == 0 else None


def native_files(root: Path) -> list[Path]:
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in MACH_MAGICS:
                result.append(path)
    return result


def inspect(path: Path) -> dict:
    text = run(["/usr/bin/otool", "-l", str(path)]).stdout
    loads = list(dict.fromkeys(LOAD_RE.findall(text)))
    return {"path": path, "architectures": run(["/usr/bin/lipo", "-archs", str(path)]).stdout.strip().split(), "ids": list(dict.fromkeys(value for command, value in loads if command == "LC_ID_DYLIB")),
            "dependencies": list(dict.fromkeys(value for command, value in loads if command != "LC_ID_DYLIB")),
            "rpaths": list(dict.fromkeys(RPATH_RE.findall(text)))}


def scan(root: Path) -> list[dict]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
        return list(executor.map(inspect, native_files(root)))


def check_symlinks(root: Path, *, repair_framework_absolute: bool = False) -> int:
    count = 0
    for link in root.rglob("*"):
        if not link.is_symlink():
            continue
        count += 1
        target = os.readlink(link)
        if repair_framework_absolute and target.startswith(GST_PREFIX):
            relative = os.path.relpath(root / target[len(GST_PREFIX):], link.parent)
            link.unlink()
            link.symlink_to(relative)
        if not within(link, root):
            raise RuntimeError(f"Symlink escapes prepared tree: {link} -> {target}")
    return count


def normalize_framework(framework: Path) -> list[dict]:
    """Keep only version aliases at the framework root so codesign can seal it."""
    changes = []
    metadata = framework / ".gitignore"
    if metadata.is_file() and not metadata.is_symlink():
        destination = framework / "Versions/Current/Resources/UpstreamMetadata/framework.gitignore"
        if not within(destination, framework):
            raise RuntimeError("Framework metadata destination escapes its private tree")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            raise RuntimeError("Refusing to overwrite preserved framework metadata")
        metadata.rename(destination)
        changes.append({"operation": "move", "from": ".gitignore", "to": "Versions/Current/Resources/UpstreamMetadata/framework.gitignore"})
    headers = framework / "Headers"
    if headers.is_symlink() and not headers.exists():
        target = os.readlink(headers)
        headers.unlink()
        changes.append({"operation": "removeDanglingDevelopmentHeadersAlias", "path": "Headers", "target": target})
    unexpected = [item.name for item in framework.iterdir()
                  if item.name != "Versions" and (not item.is_symlink() or not item.exists())]
    if unexpected:
        raise RuntimeError("Unexpected unversioned framework root entries: " + ", ".join(sorted(unexpected)))
    return changes


def snapshot(root: Path) -> dict:
    checksum = hashlib.sha256()
    files = 0
    total = 0
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            checksum.update(("link\0" + relative + "\0" + os.readlink(path) + "\0").encode())
        elif path.is_file():
            files += 1
            total += path.stat().st_size
            checksum.update(("file\0" + relative + "\0" + digest(path) + "\0").encode())
    return {"sha256": checksum.hexdigest(), "regularFileCount": files, "logicalBytes": total}


class Relocator:
    def __init__(self, output: Path, rows: list[dict]):
        self.output = output
        self.wine = output / "WineRuntime"
        self.gst = output / "GStreamer.framework"
        self.rows = rows
        self.names: dict[str, list[Path]] = {}
        self.ids: dict[str, list[Path]] = {}
        for path in output.rglob("*"):
            if path.is_file() and within(path, output):
                self.names.setdefault(path.name, []).append(path.resolve())
        for row in rows:
            for identifier in row["ids"]:
                self.ids.setdefault(identifier, []).append(row["path"].resolve())

    def map_rpath(self, value: str, owner: Path) -> Path | None:
        if value.startswith("@loader_path"):
            return (owner.parent / value.removeprefix("@loader_path").lstrip("/")).resolve()
        if value.startswith(GST_PREFIX):
            return (self.gst / value[len(GST_PREFIX):]).resolve()
        if value == "/opt/local/lib" or value.startswith("/opt/local/lib/"):
            return (self.wine / "lib" / value.removeprefix("/opt/local/lib").lstrip("/")).resolve()
        if value.startswith("/") and within(Path(value), self.output):
            return Path(value).resolve()
        return None

    def choose(self, candidates: list[Path], owner: Path, label: str) -> Path | None:
        candidates = sorted(set(p.resolve() for p in candidates if p.exists() and within(p, self.output)))
        if not candidates:
            return None
        if len(candidates) == 1:
            return candidates[0]
        domain = self.gst if within(owner, self.gst) else self.wine
        same_domain = [p for p in candidates if within(p, domain)]
        if len(same_domain) == 1:
            return same_domain[0]
        if same_domain:
            candidates = same_domain
        if len({digest(p) for p in candidates}) == 1:
            return candidates[0]
        raise RuntimeError(f"Ambiguous dependency {label} for {owner}: {candidates}")

    def resolve(self, value: str, row: dict) -> Path:
        owner = row["path"]
        if value.startswith(GST_PREFIX):
            candidate = (self.gst / value[len(GST_PREFIX):]).resolve()
            if candidate.is_file() and within(candidate, self.gst):
                return candidate
        if value.startswith("@loader_path/"):
            candidate = (owner.parent / value.removeprefix("@loader_path/")).resolve()
            if candidate.is_file() and within(candidate, self.output):
                return candidate
        if value.startswith("@rpath/"):
            suffix = value.removeprefix("@rpath/")
            for rpath in row["rpaths"]:
                directory = self.map_rpath(rpath, owner)
                if directory is not None:
                    candidate = (directory / suffix).resolve()
                    if candidate.is_file() and within(candidate, self.output):
                        return candidate
        candidate = self.choose(self.ids.get(value, []), owner, value)
        if candidate is None:
            candidate = self.choose(self.names.get(Path(value).name, []), owner, value)
        if candidate is None:
            raise RuntimeError(f"Unresolved private dependency {value} in {owner.relative_to(self.output)}")
        return candidate

    def plan(self, row: dict) -> dict:
        owner = row["path"]
        resolved = [(dep, self.resolve(dep, row)) for dep in row["dependencies"] if not dep.startswith(SYSTEM_PREFIXES)]
        names = {}
        for dep, target in resolved:
            if target.name in names and names[target.name] != target:
                raise RuntimeError(f"Two incompatible libraries share {target.name} in {owner}")
            names[target.name] = target
        directories = []
        for dep, target in resolved:
            if target.parent not in directories:
                directories.append(target.parent)
        # Preserve loader-relative search paths needed by dlopen (SDL2/MoltenVK),
        # remapping known original install roots to these private copies.
        for old in row["rpaths"]:
            target = self.map_rpath(old, owner)
            if target is not None and target.is_dir() and within(target, self.output) and target not in directories:
                directories.append(target)
        if within(owner, self.wine):
            wine_lib = self.wine / "lib"
            if wine_lib not in directories:
                directories.append(wine_lib)
        rpaths = ["@loader_path/" + os.path.relpath(p, owner.parent) for p in directories]
        changes = [(old, "@rpath/" + target.name) for old, target in resolved if old != "@rpath/" + target.name]
        args = []
        if row["ids"]:
            args.extend(["-id", "@rpath/" + owner.name])
        for old, new in changes:
            args.extend(["-change", old, new])
        for old in row["rpaths"]:
            if old not in rpaths:
                args.extend(["-delete_rpath", old])
        for new in rpaths:
            if new not in row["rpaths"]:
                args.extend(["-add_rpath", new])
        return {"path": owner, "args": args, "dependencies": [(old, str(target.relative_to(self.output))) for old, target in resolved]}

    def apply(self, plan: dict) -> dict:
        owner = plan["path"]
        before_quarantine = quarantine(owner)
        if plan["args"]:
            result = run(["/usr/bin/install_name_tool", *plan["args"], str(owner)], check=False)
            # install_name_tool may replace the inode and discard extended attrs.
            # Reapply the original protection BEFORE any later processing. This
            # only adds/restores quarantine; it never removes quarantine or runs code.
            if before_quarantine is not None and quarantine(owner) != before_quarantine:
                run(["/usr/bin/xattr", "-wx", "com.apple.quarantine", before_quarantine.hex(), str(owner)])
            if result.returncode:
                raise RuntimeError(f"Cannot relocate {owner.relative_to(self.output)}: {result.stderr.strip()}")
        if before_quarantine is not None and quarantine(owner) != before_quarantine:
            raise RuntimeError(f"Quarantine was not preserved during relocation: {owner}")
        return {"path": str(owner.relative_to(self.output)), "dependencyTargets": plan["dependencies"], "modified": bool(plan["args"])}

    def audit(self) -> list[dict]:
        audited = scan(self.output)
        native_by_path = {row["path"].resolve(): row for row in audited}
        failures = []
        for row in audited:
            for identifier in row["ids"]:
                if not identifier.startswith("@rpath/"):
                    failures.append(f"Nonrelative dylib ID: {identifier}")
            for rpath in row["rpaths"]:
                target = self.map_rpath(rpath, row["path"])
                if not rpath.startswith("@loader_path/") or target is None or not within(target, self.output):
                    failures.append(f"Nonprivate RPATH: {row['path']} => {rpath}")
            for dep in row["dependencies"]:
                if dep.startswith(SYSTEM_PREFIXES):
                    continue
                if not dep.startswith("@rpath/"):
                    failures.append(f"Nonprivate load command: {row['path']} => {dep}")
                    continue
                # Final proof deliberately excludes planning's install-ID/name
                # fallback: dyld must reach the target through THIS binary's RPATHs.
                reached = None
                suffix = dep.removeprefix("@rpath/")
                for rpath in row["rpaths"]:
                    directory = self.map_rpath(rpath, row["path"])
                    if directory is None:
                        continue
                    candidate = (directory / suffix).resolve()
                    if candidate.is_file() and within(candidate, self.output):
                        reached = native_by_path.get(candidate)
                        break
                if reached is None:
                    failures.append(f"No actual RPATH resolves {dep} from {row['path']}")
                elif not set(row["architectures"]).issubset(set(reached["architectures"])):
                    failures.append(f"Architecture mismatch: {row['path']} => {reached['path']}")
        if failures:
            raise RuntimeError("Dependency closure audit failed:\n" + "\n".join(failures[:25]))
        return [{"path": str(row["path"].relative_to(self.output)), "architectures": row["architectures"], "dependencies": row["dependencies"], "rpaths": row["rpaths"]} for row in audited]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wine-app", type=Path)
    parser.add_argument("--gstreamer-pkg", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--audit-only", action="store_true", help="Verify actual private RPATH closure without copying, modifying or executing runtime files")
    args = parser.parse_args()
    if args.audit_only:
        output = args.output.expanduser().resolve(strict=True)
        rows = scan(output)
        audit = Relocator(output, rows).audit()
        print(json.dumps({"output": str(output), "nativeBinaries": len(audit), "dependencyAudit": "passed", "checks": ["actual per-binary RPATH reachability", "contained native targets", "matching architectures", "system-only absolute dependencies"]}, indent=2))
        return
    if args.wine_app is None or args.gstreamer_pkg is None:
        parser.error("Preparation requires --wine-app and --gstreamer-pkg")
    app = args.wine_app.expanduser().resolve(strict=True)
    package = args.gstreamer_pkg.expanduser().resolve(strict=True)
    output = args.output.expanduser().absolute()
    if any(p.is_symlink() for p in [output, *output.parents]):
        raise RuntimeError("Output and its parents must not be symlinks")
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("Output must be empty; prepared copies are never overwritten")
    if within(app, output) or within(package, output) or within(output, app):
        raise RuntimeError("Output must be separate from the source app and package")
    source = app / "Contents/Resources/wine"
    recorded = json.loads((app.parent / ".download.json").read_text())
    expected = {"archiveRoot": "Wine Stable.app", "releaseID": "wine-stable-11.0_1", "version": "11.0_1", "downloadBytes": WINE_BYTES, "sha256": WINE_SHA,
                "executableRelativePath": "Contents/Resources/wine/bin/wine", "sourceURL": "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1"}
    for key, value in expected.items():
        if recorded.get(key) != value:
            raise RuntimeError(f"Wine download provenance mismatch: {key}")
    if package.stat().st_size != GST_BYTES or digest(package) != GST_SHA:
        raise RuntimeError("GStreamer package size/SHA256 does not match pinned upstream 1.28.1 runtime")
    check_symlinks(source)
    original = snapshot(source)
    signature = run(["/usr/sbin/pkgutil", "--check-signature", str(package)], check=False)
    output.mkdir(parents=True, exist_ok=True)
    expanded = output / ".gstreamer-expanded"
    print("Copying Wine and expanding verified GStreamer package (no installation scripts run).", flush=True)
    run(["/usr/bin/ditto", "--rsrc", "--extattr", str(source), str(output / "WineRuntime")])
    run(["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)])
    components = []
    excluded_components = []
    for component in sorted(expanded.glob("*.pkg")):
        if component.name.startswith("gstreamer-1.0-python-"):
            excluded_components.append({"name": component.name, "reason": "Optional Python plugin depends on external Python3.framework/3.9; unused by Wine multimedia integration."})
            continue
        metadata = ET.parse(component / "PackageInfo").getroot()
        location = metadata.attrib.get("install-location", "")
        if not location.startswith(GST_PREFIX):
            raise RuntimeError(f"Unexpected GStreamer component installation root: {location}")
        relative = location[len(GST_PREFIX):]
        if ".." in Path(relative).parts:
            raise RuntimeError("Unsafe component installation location")
        payload = component / "Payload"
        if not payload.is_dir():
            raise RuntimeError(f"Missing expanded component payload: {component.name}")
        destination = output / "GStreamer.framework" / relative
        run(["/usr/bin/ditto", "--rsrc", "--extattr", str(payload), str(destination)])
        components.append(component.name)
    if not components:
        raise RuntimeError("No GStreamer framework components found in the verified package")
    notices = output / "ThirdPartyLicenses"
    notices.mkdir()
    run(["/usr/bin/ditto", "--rsrc", "--extattr", str(expanded / "Resources/license.txt"), str(notices / "GStreamer-Package-license.txt")])
    check_symlinks(output / "WineRuntime")
    check_symlinks(output / "GStreamer.framework", repair_framework_absolute=True)
    framework_normalization = normalize_framework(output / "GStreamer.framework")
    # Remove only the extraction scratch tree created by this invocation. Native
    # inventory then covers exactly the two payload trees that will be embedded.
    shutil.rmtree(expanded)
    rows = scan(output)
    # install_name_tool must only touch a hardlinked binary once. Aliases in the
    # same directory share loader-relative paths; cross-directory hardlinks do not.
    grouped = {}
    for row in rows:
        stat = row["path"].stat()
        grouped.setdefault((stat.st_dev, stat.st_ino), []).append(row)
    unique_rows = []
    for group in grouped.values():
        if len({r["path"].parent for r in group}) > 1:
            raise RuntimeError("Native hardlinks span different loader directories; explicit flattening is required")
        identifier_name = Path(group[0]["ids"][0]).name if group[0]["ids"] else ""
        unique_rows.append(next((r for r in group if r["path"].name == identifier_name), group[0]))
    relocator = Relocator(output, rows)
    plans = [relocator.plan(row) for row in unique_rows]
    print(f"Relocating {len(plans)} native binaries; original source files remain unchanged.", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        modifications = list(executor.map(relocator.apply, plans))
    audit = relocator.audit()
    if snapshot(source) != original:
        raise RuntimeError("Original Wine source tree changed during preparation")
    manifest = {"schemaVersion": 1, "id": "wine-stable-11.0_1", "name": "Wine Stable 11.0", "version": "11.0_1", "architecture": "x86_64", "developmentOnly": True,
                "license": "Wine LGPL-2.1-or-later; bundled components have separate licenses; distribution review incomplete",
                "sourceURL": "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1",
                "components": {"GStreamer": "1.28.1", "Wine Gecko": "2.47.4", "Wine Mono": "10.4.1"}, "gstreamerComponentPackages": components, "excludedGStreamerComponents": excluded_components,
                "frameworkNormalization": framework_normalization,
                "runtimeID": "wine-stable-11.0_1", "wineVersion": "11.0_1", "wineArchitecture": "x86_64", "gstreamerVersion": "1.28.1",
                "wineArchiveSHA256": WINE_SHA, "wineDownloadManifest": recorded, "wineSourceTree": original,
                "wineProvenanceNote": "Archive digest is the validated downloader record; current extracted source tree is separately hashed above.",
                "gstreamerPackageSHA256": GST_SHA, "gstreamerPackageBytes": GST_BYTES, "gstreamerPackageSignature": signature.stdout + signature.stderr,
                "quarantinePolicy": "Preserved; no quarantine removal or Gatekeeper override is performed.",
                "signingRequired": True, "releaseApproved": False,
                "scope": "Native static load-command closure verified. Runtime plugin/scanner environment, signing, license/source obligations and actual game compatibility require separate validation.",
                "modifications": modifications, "nativeAudit": audit,
                "winePreparedTree": snapshot(output / "WineRuntime"), "gstreamerPreparedTree": snapshot(output / "GStreamer.framework")}
    (output / "embed-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    summary_keys = ["schemaVersion", "id", "name", "version", "architecture", "license", "sourceURL", "components", "developmentOnly"]
    (output / "RuntimeManifest.json").write_text(json.dumps({key: manifest[key] for key in summary_keys}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(output), "nativeBinaries": len(audit), "dependencyAudit": "passed", "signingRequired": True}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print("Preparation failed: " + (detail or str(error)), file=sys.stderr)
        sys.exit(1)
