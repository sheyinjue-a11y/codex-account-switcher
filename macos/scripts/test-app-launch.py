"""Exercise the distributed .app through macOS LaunchServices, with synthetic UI data."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="switcher-launch-") as temporary:
    root = Path(temporary)
    # Include a space and Chinese characters: Finder/download destinations commonly do.
    extracted = root / "下载 应用"
    extracted.mkdir()
    archive = app.parent / "Codex-Account-Switcher-macOS-universal.zip"
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
    installed = extracted / app.name
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
    mount = root / "mounted-image"
    disk_image = app.parent / "Codex-Account-Switcher-macOS-universal.dmg"
    subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(disk_image)], check=True)
    try:
        assert (mount / "Applications").is_symlink(), "DMG must provide an Applications install shortcut"
        assert (mount / "Applications").readlink() == Path("/Applications")
        dmg_installed = root / "Applications" / app.name
        dmg_installed.parent.mkdir()
        subprocess.run(["/usr/bin/ditto", str(mount / app.name), str(dmg_installed)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(dmg_installed)], check=True)
    finally:
        subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)
    for empty in (True, False):
        report = root / ("first-run.json" if empty else "accounts.json")
        # First launch follows DMG installation; account launch covers ZIP extraction.
        launch_app = dmg_installed if empty else installed
        args = ["/usr/bin/open", "-n", "-W", str(launch_app), "--args", "--smoke-test", str(report)]
        if empty:
            args.append("--smoke-empty")
        subprocess.run(args, check=True, timeout=30)
        assert report.exists(), "Application exited without showing its normal account window"
        result = json.loads(report.read_text())
        assert result["visibleWindows"] == 1, result
        assert result["preview"] is True and not result["error"], result
        assert result["profiles"] == (0 if empty else 2), result
        assert result["firstRunAction"] == "登录 ChatGPT 并开始", result
        assert result["bundleVersion"] == "0.3.3", result
        destination = app.parent / ("first-run.png" if empty else "accounts-launch.png")
        destination.write_bytes(report.with_suffix(".json.png").read_bytes())
        print(f"PASS: LaunchServices opened one {'first-run window after DMG installation' if empty else 'account window from the extracted ZIP'}")
        time.sleep(0.3)
