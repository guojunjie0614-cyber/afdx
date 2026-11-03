"""CLI for the T75 compatibility-copy fallback; never edit original RTL."""
import argparse
import json
from pathlib import Path

from modelsim_sources import prepare


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl',type=Path,required=True)
    parser.add_argument('--folder',type=Path,required=True)
    args=parser.parse_args()
    args.folder.mkdir(parents=True,exist_ok=True)
    sources,changes=prepare(sorted(args.rtl.glob('*.v')),args.folder)
    (args.folder/'modelsim_compatibility.json').write_text(
        json.dumps(changes,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    for source in sources:print(source.resolve().as_posix())


if __name__=='__main__':main()
