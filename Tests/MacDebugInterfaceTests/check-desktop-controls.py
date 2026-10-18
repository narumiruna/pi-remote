"""Check native debug clicks in a separately launched, unchanged product app.

Run with uv run python and the dedicated MacDebugCheck .app path. This is not
an attended consent, provider, keyboard or VoiceOver acceptance check.
"""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Pass the built PiRemoteMacDebugCheck.app path.")
    app = Path(sys.argv[1]).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "dev.narumi.PiRemote.MacDebugCheck":
        raise SystemExit("Only the dedicated debug-check bundle is permitted.")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    repository = Path(__file__).resolve().parents[2]
    probe_path = repository / ".pi/tests/debug-probe.ts"
    # Keep Unix socket paths short and do not use the user's app preferences.
    with tempfile.TemporaryDirectory(prefix="prdf-", dir=Path.home()) as directory:
        home = Path(directory)
        (home / "Library/Caches").mkdir(mode=0o700, parents=True)
        environment = {key: os.environ[key] for key in ("PATH", "USER", "LOGNAME", "TMPDIR") if key in os.environ}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home))

        def probe(*arguments):
            result = subprocess.run(["node", str(probe_path), *arguments], cwd=repository,
                                    env=environment, capture_output=True, text=True, timeout=15)
            # The existing probe emits only fixed errors or bounded metadata.
            return json.loads(result.stdout)

        def applied(action, value):
            result = probe("interact", action, value)
            assert result == {"ok": True, "action": action, "outcome": "applied"}, result

        # Test-only argument-domain consent in an empty private home. Never seed
        # production preferences or claim that this verifies the consent dialog.
        process = subprocess.Popen([str(binary), "-macDebugEnabled", "YES", "-macInterfaceMode", "desktop",
                                    "-piSidebarVisible", "NO"], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            endpoint = home / "Library/Caches/PiRemoteDebug/endpoint.json"
            storage = home / "Library/Application Support/PiRemote/host.json"
            for _ in range(100):
                if endpoint.exists() and storage.exists():
                    break
                assert process.poll() is None, "The dedicated check app exited before startup."
                time.sleep(0.1)
            assert endpoint.exists() and storage.exists(), (
                "Private home startup did not finish: "
                f"storage={storage.exists()}, endpoint={endpoint.exists()}."
            )
            for _ in range(30):
                status = probe("status")
                if status.get("ok") and status["status"]["windowWidth"] > 0:
                    break
                time.sleep(0.1)
            assert status["ok"] and status["status"]["windowWidth"] > 0, status
            initial = status["status"]
            assert initial["interfaceMode"] == "desktop" and initial["destination"] == "conversation", initial
            assert not initial["sessionPresent"] and initial["sessionCount"] == 0, initial
            assert not initial["listenerOn"] and initial["dialogCount"] == 0, initial
            before = probe("capture")
            assert before["ok"], before
            applied("click", "mac-sidebar-toggle")
            time.sleep(0.2)
            shown = probe("capture")
            assert shown["ok"] and shown["sha256"] != before["sha256"], shown
            applied("click", "mac-commands")
            time.sleep(0.2)
            protected = probe("capture")
            assert protected == {"ok": False, "error": "Capture is blocked while a protected surface is visible."}, protected
            blocked = probe("interact", "click", "mac-sidebar-toggle")
            assert blocked == {"ok": False, "error": "Pi Remote debug interaction is blocked while a protected surface is visible."}, blocked
            applied("panel", "close")
            time.sleep(0.2)
            assert probe("capture")["ok"], "Closing the ordinary panel did not restore capture."
            applied("click", "mac-sidebar-toggle")
            final = probe("status")
            assert final["ok"] and final["status"] == initial, final
            print(json.dumps({"result": "passed", "nativeSidebar": "passed", "nativeCommands": "passed",
                              "protectedPanel": "passed", "runtimeUnchanged": True,
                              "privateHome": True, "imagesSaved": False}))
        finally:
            # Only the child created above is stopped. The user's app is not addressed.
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
