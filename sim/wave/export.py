"""运行真实 ModelSim GUI，用 PrintWindow 保存默认配色的 Wave 窗口截图。"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import psutil

ROOT = Path(__file__).resolve().parents[2]
SCENES = {"tx_dual": 2, "rx_redundancy": 2, "rx_fcs_error": 3,
          "tx_bag": 1, "snmp_get": 2, "frag": 3}


def tcl_path(path):
    return '"' + str(path).replace("\\", "/").replace("$", "\\$").replace(
        "[", "\\[").replace('"', '\\"') + '"'


def simulator():
    home = os.environ.get("MODELSIM_HOME")
    exe = Path(home) / "vsim.exe" if home else shutil.which("vsim.exe")
    if not exe or not Path(exe).is_file():
        raise RuntimeError("Set MODELSIM_HOME or put vsim.exe on PATH")
    return str(exe)


def run_gui(scene, exe):
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    driver_dir = ROOT / "out" / "wave" / ("export_" + scene + "_" + stamp)
    driver_dir.mkdir(parents=True)
    result = driver_dir / "result.txt"
    request = driver_dir / "capture_request.txt"
    (driver_dir / "export.do").write_text(
        "set wave_preferences [array get PrefWave]\n"
        "onerror {catch {array set PrefWave $wave_preferences}; quit -f -code 1}\n"
        "cd " + tcl_path(ROOT) + "\n"
        "do " + tcl_path(ROOT / "sim" / "wave" / (scene + ".do")) + "\n"
        "set output_file [open " + tcl_path(result) + " w]\n"
        "puts $output_file $wave_output\nclose $output_file\n"
        "array set PrefWave $wave_preferences\n"
        "catch {view wave -dock}\nupdate\nquit -f -code 0\n",
        encoding="utf-8")
    environment = dict(os.environ, AFDX_WAVE_CAPTURE_DIR=str(driver_dir))
    # 仅给本次 GUI 进程启用原生 DPI 绘制，不改变系统缩放或安装设置。
    environment["__COMPAT_LAYER"] = (
        environment.get("__COMPAT_LAYER", "") + " HIGHDPIAWARE").strip()
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    flags = subprocess.CREATE_NO_WINDOW
    powershell = str(Path(os.environ["SystemRoot"]) /
                     "System32/WindowsPowerShell/v1.0/powershell.exe")
    owned = {}
    captured = []
    with (driver_dir / "launch.log").open("wb") as log:
        process = psutil.Popen(
            [exe, "-gui", "-l", "export.log", "-do", "do export.do"],
            cwd=driver_dir, env=environment, stdout=log, stderr=subprocess.STDOUT,
            startupinfo=startup, creationflags=flags)
        limit = time.monotonic() + 600
        try:
            while process.poll() is None:
                for child in [process] + process.children(recursive=True):
                    owned[child.pid] = child.create_time()
                if request.is_file():
                    fields = request.read_text(encoding="utf-8").splitlines()
                    gui_pid, name, window = fields
                    if int(gui_pid) not in owned or not re.fullmatch(
                            re.escape(scene) + r"(?:_[123])?", name):
                        raise RuntimeError("Unexpected Wave capture identity")
                    if name not in captured:
                        subprocess.run([
                            powershell, "-NoProfile", "-ExecutionPolicy", "Bypass",
                            "-File", str(ROOT / "sim/wave/capture.ps1"),
                            "-SessionProcessIds", ",".join(map(str, owned)),
                            "-Destination", str(driver_dir / (name + ".png"))],
                            check=True, timeout=30, startupinfo=startup, creationflags=flags)
                        captured.append(name)
                        (driver_dir / (name + ".done")).write_text("captured\n")
                        print("Captured " + name + ": " + window, flush=True)
                if time.monotonic() >= limit:
                    raise TimeoutError(scene + " GUI export exceeded 600 seconds")
                time.sleep(1)
            if process.returncode or not result.is_file() or len(captured) != SCENES[scene]:
                raise RuntimeError(scene + " GUI export failed; inspect " +
                                   str(driver_dir.relative_to(ROOT)))
        finally:
            # 仅关闭本次启动且身份仍相同的进程，不影响其他 ModelSim 会话。
            victims = []
            for pid, created in reversed(list(owned.items())):
                try:
                    child = psutil.Process(pid)
                    if child.create_time() == created:
                        child.terminate()
                        victims.append(child)
                except psutil.NoSuchProcess:
                    pass
            _, alive = psutil.wait_procs(victims, timeout=5)
            for child in alive:
                child.kill()
    folder = Path(result.read_text().strip())
    for name in captured:
        shutil.copyfile(driver_dir / (name + ".png"), folder / (name + ".png"))
    return folder, captured


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", choices=SCENES)
    args = parser.parse_args()
    destination = ROOT / "sim/wave/png"
    destination.mkdir(exist_ok=True)
    for scene in (args.scene,) if args.scene else SCENES:
        print("Capturing " + scene, flush=True)
        folder, captured = run_gui(scene, simulator())
        for name in captured:
            shutil.copyfile(folder / (name + ".png"), destination / (name + ".png"))
            print("Saved sim/wave/png/" + name + ".png", flush=True)
        # 分图场景替换原来的拼接打印稿，不保留已废弃的同名 PNG。
        previous = destination / (scene + ".png")
        if scene not in captured and previous.is_file():
            previous.unlink()


if __name__ == "__main__":
    main()
