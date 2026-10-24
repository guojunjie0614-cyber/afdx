"""Compare current RX initialization with the fixed R5 source, cycle by cycle."""
import argparse,json,re,subprocess,sys
from pathlib import Path
import eda
ROOT=Path(__file__).resolve().parents[1]
R5='960e30e8028739f159438783778c5ba864a197a5'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--copies',type=int,choices=(1,2,4,8,16,32),default=32)
    parser.add_argument('--deadline')
    args=parser.parse_args()
    flow=eda.Flow('resource_reduce_D_equiv','copies_'+str(args.copies),args.deadline)
    try:
        source=subprocess.check_output(['git','show',R5+':rtl/afdx_rx_core.v'],cwd=ROOT).decode('utf-8')
        source=source.replace('module afdx_rx_core #(','module afdx_rx_core_r5 #(',1)
        # The R5 core instantiates the R5 delivery module, whose queue port differs from the current one.
        source=source.replace('afdx_rx_deliver #(','afdx_rx_deliver_r5 #(',1)
        deliver=subprocess.check_output(['git','show',R5+':rtl/afdx_rx_deliver.v'],cwd=ROOT).decode('utf-8')
        deliver=deliver.replace('module afdx_rx_deliver #(','module afdx_rx_deliver_r5 #(',1)
        reference=flow.folder/'afdx_rx_core_r5.v';reference.write_text(source,encoding='utf-8')
        reference_deliver=flow.folder/'afdx_rx_deliver_r5.v';reference_deliver.write_text(deliver,encoding='utf-8')
        sources=sorted((ROOT/'rtl').glob('*.v'))+[reference,reference_deliver,ROOT/'tb/tb_rx_init_equiv.v']
        ms=eda.modelsim_dir()
        flow.job('vlib',[ms/'vlib.exe','work'],30)
        compiled=flow.job('compile',[ms/'vlog.exe','-vlog01compat',*sources],120)
        if not re.search(r'Errors: 0, Warnings: 0',compiled):raise RuntimeError('Compile diagnostics')
        script=flow.folder/'run.do';script.write_text('onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n',encoding='ascii')
        log=flow.job('simulation',[ms/'vsim.exe','-c','tb_rx_init_equiv','-gCOPIES='+str(args.copies),'-do','do run.do'],600)
        if 'INIT_EQUIV PASS' not in log or re.search(r'INIT_EQUIV (FAIL|MISMATCH)|\*\* (Error|Fatal)',log):raise RuntimeError('Initialization comparison failed')
        flow.result.update(passed=True,r5=R5,copies=args.copies,init_edges=re.findall(r'INIT_EDGE[^\r\n]*',log),inputs={str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):eda.sha(p) for p in sources})
    except Exception as e:
        flow.result.update(passed=False,error=str(e));print('INIT_EQUIV FAIL '+str(e),flush=True)
    finally:flow.finish()
    print(json.dumps(flow.result,ensure_ascii=False,indent=2),flush=True)
    return 0 if flow.result.get('passed') else 1
if __name__=='__main__':raise SystemExit(main())
