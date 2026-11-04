"""Reuse the existing pure-Tcl application stimulus and independent checks.

Only procedure definitions from run_app.do are loaded. Its ModelSim startup,
compile and simulate procedures are never called. Tcl measurement and byte,
ordering, redundancy, throughput and timing checks are unchanged.
"""
import argparse
from pathlib import Path
import shutil
import tkinter

ROOT = Path(__file__).resolve().parents[1]


def run(mode, folder):
    folder = folder.resolve()
    interp = tkinter.Tcl()
    interp.eval('proc onerror {args} {}; proc onbreak {args} {}')
    script = (ROOT/'sim/run_app.do').read_text(encoding='utf-8')
    definitions = script.split('proc app_entry::main ', 1)[0]
    interp.eval(definitions)
    interp.setvar('::app_entry::root', ROOT.as_posix())
    config_path = folder/'input/vl_config.txt'
    stimulus_path = folder/'input/stimulus.txt'
    cfg = interp.call('app_entry::read_config', config_path.as_posix())
    msgs = interp.call('app_entry::read_stimulus', stimulus_path.as_posix(), cfg)
    if mode == 'prepare':
        interp.call('app_entry::write_vectors', folder.as_posix(), msgs, cfg, stimulus_path.as_posix())
        shutil.copyfile(config_path,folder/'vectors/vl_config.txt')
        # The default-window fallback in Tcl is tied to the committed stimulus
        # pathname; this isolated input keeps its explicit companion window.
        values = (folder/'input/window.txt').read_text(encoding='ascii').split()
        window = tuple(round(float(value)*125) for value in values)
        (folder/'vectors/app_window.txt').write_text('%d %d\n'%window,encoding='ascii')
        print('APP VECTORS PREPARED')
    else:
        window = tuple(map(int,(folder/'vectors/app_window.txt').read_text().split()))
        print(interp.call('app_entry::analyse', folder.as_posix(), msgs, cfg, window))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode',choices=['prepare','check'])
    p.add_argument('folder',type=Path)
    args = p.parse_args()
    run(args.mode,args.folder)
