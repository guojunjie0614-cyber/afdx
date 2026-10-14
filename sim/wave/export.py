"""运行真实 ModelSim GUI，把原生 PostScript 波形转换为 PNG。"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time
from datetime import datetime

import psutil

ROOT = Path(__file__).resolve().parents[2]
SCENES = ("tx_dual", "rx_redundancy", "rx_fcs_error", "tx_bag", "snmp_get")


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
    capture_ready = driver_dir / "capture_ready.txt"
    capture_done = driver_dir / "capture_done.txt"
    capture = ""
    if scene == "tx_bag":
        # 原生打印不带游标；此场景保留真实 GUI 的两个游标和间隔读数。
        capture = (
            "set window [view wave -undock -title {Wave tx_bag} -width 1400 -height 500 -x 0 -y 0]\n"
            "update\nwave zoom range 10000ns 830000ns\nupdate\n"
            "set capture_file [open " + tcl_path(capture_ready) + " w]\n"
            "puts $capture_file [pid]\n"
            "close $capture_file\n"
            "while {![file exists " + tcl_path(capture_done) + "]} {after 100; update}\n")
    (driver_dir / "export.do").write_text(
        "set wave_preferences [array get PrefWave]\n"
        "onerror {array set PrefWave $wave_preferences; quit -f -code 1}\n"
        + "cd " + tcl_path(ROOT) + "\n"
        + "do " + tcl_path(ROOT / "sim" / "wave" / (scene + ".do")) + "\n"
        + capture
        + "set output_file [open " + tcl_path(result) + " w]\n"
        + "puts $output_file $wave_output\nclose $output_file\n"
        + "array set PrefWave $wave_preferences\nquit -f -code 0\n",
        encoding="utf-8")
    startup = None
    flags = 0
    if os.name == "nt":
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        flags = subprocess.CREATE_NO_WINDOW
    owned = {}
    captured = False
    with (driver_dir / "launch.log").open("wb") as log:
        process = psutil.Popen(
            [exe, "-gui", "-l", "export.log", "-do", "do export.do"],
            cwd=driver_dir, stdout=log, stderr=subprocess.STDOUT,
            startupinfo=startup, creationflags=flags)
        limit = time.monotonic() + 600
        try:
            while process.poll() is None:
                for child in [process] + process.children(recursive=True):
                    owned[child.pid] = child.create_time()
                if capture_ready.is_file() and not captured:
                    gui_pid = int(capture_ready.read_text().strip())
                    if gui_pid not in owned:
                        raise RuntimeError("Unexpected GUI process identity")
                    subprocess.run([
                        "powershell", "-NoProfile", "-File", str(ROOT / "sim/wave/capture.ps1"),
                        "-SessionProcessIds", ",".join(map(str, owned)),
                        "-Destination", str(driver_dir / "gui.png")], check=True)
                    capture_done.write_text("captured\n")
                    captured = True
                if time.monotonic() >= limit:
                    raise TimeoutError(scene + " GUI export exceeded 600 seconds")
                time.sleep(1)
            if process.returncode or not result.is_file():
                raise RuntimeError(scene + " GUI export failed; inspect " + str(driver_dir))
        finally:
            # 仅在异常退出时关闭本次启动且身份仍相同的子进程。
            if process.poll() is None:
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
    if captured:
        shutil.copyfile(driver_dir / "gui.png", folder / "gui.png")
    return folder


def rasterize(ps, gs, magick, dpi):
    output = ps.with_suffix(".png")
    command = [gs]
    # TeX Live 的私有 Ghostscript 需要显式指定随附资源；普通安装无需此项。
    base = Path(gs).resolve().parent.parent
    if (base / "Resource" / "Init" / "gs_init.ps").is_file():
        command.append("-I" + ";".join(str(base / part) for part in
                                      ("Resource/Init", "lib", "Resource", "kanji")))
    command += ["-dBATCH", "-dNOPAUSE", "-sDEVICE=png16m", "-r" + str(dpi),
                "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4",
                "-sOutputFile=" + str(output), str(ps)]
    with ps.with_suffix(".conversion.log").open("wb") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    cropped = ps.with_name(ps.stem + "_cropped.png")
    # 只裁白边；不重绘、不修改波形、信号名或游标。
    subprocess.run([magick, str(output), "-trim", "+repage", "-alpha", "off",
                    str(cropped)], check=True)
    return cropped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", choices=SCENES)
    parser.add_argument("--ghostscript", default=os.environ.get("AFDX_GHOSTSCRIPT"))
    parser.add_argument("--dpi", type=int, default=180)
    args = parser.parse_args()
    gs = args.ghostscript or shutil.which("gswin64c.exe") or shutil.which("gs")
    if not gs:
        raise RuntimeError("Set AFDX_GHOSTSCRIPT or pass --ghostscript")
    magick = shutil.which("magick.exe") or shutil.which("magick")
    if not magick:
        raise RuntimeError("Put ImageMagick's magick executable on PATH")
    destination = ROOT / "sim" / "wave" / "png"
    destination.mkdir(exist_ok=True)
    for scene in (args.scene,) if args.scene else SCENES:
        print("Exporting " + scene, flush=True)
        folder = run_gui(scene, simulator())
        if scene == "tx_bag":
            # 裁掉 PrintWindow 在缩放屏幕上留下的空黑边；保留整个真实 Wave 窗口。
            cropped = folder / "gui_cropped.png"
            subprocess.run([magick, str(folder / "gui.png"), "-trim", "+repage",
                            "-resize", "180%", str(cropped)], check=True)
            pictures = [cropped, rasterize(folder / "frame1.ps", gs, magick, args.dpi),
                        rasterize(folder / "frame2.ps", gs, magick, args.dpi)]
        else:
            pictures = [rasterize(folder / "wave.ps", gs, magick, args.dpi)]
        if scene == "rx_fcs_error":
            pictures.append(rasterize(folder / "counter_read.ps", gs, magick, args.dpi))
        subprocess.run([magick, *map(str, pictures), "-background", "white", "-append",
                        str(destination / (scene + ".png"))], check=True)
        print("Saved sim/wave/png/" + scene + ".png", flush=True)


if __name__ == "__main__":
    main()
