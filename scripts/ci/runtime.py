"""Export the tested VM runtime for launcher CI, or check it against a checkout."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
GUEST = ("Image", "initramfs.cpio.gz", "steamac-layer.img")
LIBS = ("libkrun.1.dylib", "libepoxy.0.dylib", "libvirglrenderer.1.dylib",
        "libMoltenVK.dylib", "libvulkan_kosmickrisp.dylib", "libwmtr_host.dylib")
# The package includes the notices for both the runtime and the launcher's pinned dependencies.
INPUTS = ["guest", "wmtr", "host/dxmt", "host/kosmickrisp", "host/libepoxy", "host/libkrun",
          "host/moltenvk", "host/virglrenderer", "host/vrhost", "scripts/builder",
          "scripts/config.env", "scripts/build-image.sh", "scripts/steps", "scripts/keys",
          "LICENSE", "LICENSES", "NOTICE"]
INPUTS += ["host/launcher/" + name for name in
           ("Package.resolved", "fetch-desync.sh", "fetch-enet.sh", "fetch-gvproxy.sh",
            "fetch-nanors.sh", "fetch-zstd.sh", "licenses.sh")]


def source_digest():
    entries = subprocess.check_output(["git", "ls-tree", "-rz", "HEAD", "--", *INPUTS], cwd=ROOT)
    return hashlib.sha256(entries).hexdigest()


def guest_checksums(resources):
    return "".join(f"{hashlib.sha256((resources / name).read_bytes()).hexdigest()}  {name}\n"
                   for name in GUEST)


def verify(runtime, resources):
    if (runtime / "inputs.sha256").read_text().strip() != source_digest():
        raise SystemExit("Runtime sources changed. Rebuild and pin the matching runtime; see scripts/ci/README.md.")
    if guest_checksums(resources) != (runtime / "guest.sha256").read_text():
        raise SystemExit("Guest resources differ from the pinned runtime.")


def export(app, prefix, archive):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    if subprocess.check_output(["git", "status", "--porcelain", "--", *INPUTS], cwd=ROOT):
        raise SystemExit("Commit the runtime inputs before exporting the SDK.")
    contents = app / "Contents"
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        for d in ("lib", "include", "guest"):
            (root / d).mkdir()
        for name in LIBS:
            lib = contents / "Frameworks" / name
            subprocess.run(["lipo", lib, "-verify_arch", "arm64"], check=True)
            shutil.copyfile(lib, root / "lib" / name)
        (root / "lib/libkrun.dylib").symlink_to("libkrun.1.dylib")
        for name in ("libkrun.h", "libkrun_input.h", "libkrun_display.h"):
            shutil.copyfile(prefix / "include" / name, root / "include" / name)
        for name in ("MOLTENVK.txt", "KOSMICKRISP.txt"):
            shutil.copyfile(prefix / name, root / name)
        for name in GUEST:
            shutil.copyfile(contents / "Resources" / name, root / "guest" / name)
        shutil.copytree(contents / "Resources/licenses", root / "licenses",
                        ignore=shutil.ignore_patterns(".DS_Store", "._*"))
        (root / "inputs.sha256").write_text(source_digest() + "\n")
        (root / "guest.sha256").write_text(guest_checksums(root / "guest"))
        with tarfile.open(archive, "x:gz") as tar:
            for path in sorted(root.rglob("*")):
                info = tar.gettarinfo(str(path), str(path.relative_to(root)))
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ""
                if path.is_file() and not path.is_symlink():
                    with path.open("rb") as file:
                        tar.addfile(info, file)
                else:
                    tar.addfile(info)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("export")
    for argument in ("app", "prefix", "archive"):
        create.add_argument(argument, type=Path)
    check = commands.add_parser("verify")
    check.add_argument("runtime", type=Path)
    check.add_argument("resources", type=Path)
    args = parser.parse_args()
    if args.command == "export":
        export(args.app, args.prefix, args.archive)
    else:
        verify(args.runtime, args.resources)
