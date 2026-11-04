"""Create reviewed compatible source copies for native GUI/Tcl compilation."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from run_modelsim_entries import prepare_tree

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    if args.out.exists():raise SystemExit('Refusing to overwrite an existing source snapshot')
    prepare_tree(args.out)
    print('MODELSIM SOURCE SNAPSHOT '+str(args.out.resolve()))
