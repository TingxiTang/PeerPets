"""从明确列出的发行文件生成完整 macOS 包，保留 Unix 可执行权限。"""
from pathlib import Path
import plistlib
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
TOOLS = ("peer.py", "agy_text.py", "ask-agy", "peer-check", "Check-Peers.command",
         "GlassDesk.swift", "PeerPets.swift", "PeerPetsActivity.swift", "tests/test_peer.py", "tests/peer-pets/main.swift")
RESOURCES = ("ART-CREDITS.txt", "CrossPet-LICENSE.md", "gpt-idle.webp", "gpt-thinking.webp",
             "gemini-idle.webp", "gemini-thinking.webp")


def main():
    with (ROOT / "macos/Info.plist").open("rb") as info:
        version = plistlib.load(info)["CFBundleShortVersionString"]
    build = ROOT / "build"
    archive = build / f"PeerPets-{version}-macOS.zip"
    sources = [Path(name) for name in ("README.md", "AGENTS.md", "LICENSE", "Makefile", ".gitignore",
                                       "scripts/package.py", "macos/Info.plist")]
    sources.extend(Path("tools") / name for name in TOOLS)
    sources.extend(Path("macos/Resources") / name for name in RESOURCES)
    contents = Path("PeerPets.app/Contents")
    app = [contents / name for name in ("Info.plist", "MacOS/PeerPets", "_CodeSignature/CodeResources")]
    app.extend(contents / "Resources" / name for name in (*RESOURCES, "LICENSE"))
    with tempfile.TemporaryDirectory(dir=build) as stage:
        temporary = Path(stage) / archive.name
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as output:
            for base, paths in ((ROOT, sources), (build, app)):
                for path in paths:
                    output.write(base / path, Path(f"PeerPets-{version}") / path)
        temporary.replace(archive)
    print(archive)


if __name__ == "__main__":
    main()
