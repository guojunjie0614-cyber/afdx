"""Export all endpoints from an existing official routed graph without rerouting."""
import argparse
import json
from pathlib import Path
import sqlite3
import struct

import eda
from official_synth import installation, tcl
import check_multicycle

ROOT=Path(__file__).resolve().parents[1]
# eLinx 3.0.7 GUI report configuration for the single clk clock.
# Only the result limit and paths-per-endpoint fields are changed below.
REPORT_CONFIG=bytes.fromhex('00000000640000000a00000003000000caf249710103000000000000000000000000000000')

def report(route_path,deadline):
    route=json.loads(route_path.read_text(encoding='utf-8'))
    if not route.get('completed'):raise RuntimeError('Official implementation has not completed')
    for name,digest in {**route['source_hashes'],**route['setting_hashes']}.items():
        if eda.sha(ROOT/name)!=digest:raise RuntimeError('Routed input differs: '+name)
    output=Path(route['output'])
    flow=eda.Flow('timing','AFDX_top_full_timing',deadline)
    flow.result.update(route=route['folder'],scope='Existing routed graph and delays; reporting limit only')
    config=bytearray(REPORT_CONFIG)
    struct.pack_into('<ii',config,4,1000000,1)
    routed_config=output/'AFDX_EndSystem.tr.cfg.pb'
    previous=routed_config.read_bytes() if routed_config.exists() else None
    binary=installation()/'bin/shell/bin'
    log_config=flow.folder/'log4cpp.property'
    log_config.write_text('log4cpp.rootCategory=DEBUG,A1\n'
        'log4cpp.appender.A1=RollingFileAppender\n'
        'log4cpp.appender.A1.fileName='+(flow.folder/'full_timing.edi').as_posix()+'\n'
        'log4cpp.appender.A1.append=false\n'
        'log4cpp.appender.A1.layout=PatternLayout\n'
        'log4cpp.appender.A1.layout.ConversionPattern=%d [%p] %m%n\n',encoding='utf-8')
    lines=['setlogfile '+tcl(log_config)+' '+tcl(flow.folder/'full_timing.edi')]
    for name,value in [('TOP_LEVEL_ENTITY','AFDX_top'),('DESIGN_PATH',str(output.parent.parent)),
                       ('PROJECT_NAME','AFDX_EndSystem'),('DEVICE_SERIES','eHiChip6'),
                       ('DEVICE_NAME','EQ6HL130'),('PACKAGE_NAME','CSG484_H')]:
        lines.append('set_global_assignment -name '+name+' '+tcl(value))
    lines+=['load_pb_ver '+tcl(output/'AFDX_EndSystem.ver.pb'),
            'load_time_model '+tcl((binary.parent/'Infrastructure/psk_intern/eHiChip6/EQ6HL130').as_posix()+'/'),
            'deserialize_timing_graph '+tcl(output/'AFDX_EndSystem.tbg.pb'),
            'deserialize_timing_delay '+tcl(output/'AFDX_EndSystem'),
            'do_timing_analysis',
            'print_timing_report '+tcl(flow.folder/'full_timing.tan.rpt'),
            'get_fmax_and_slack '+tcl(flow.folder/'full_timing.slack.rpt'),
            'free_timing_graph','puts "FULL_ROUTED_TIMING_COMPLETED"','exit 0']
    script=flow.folder/'report.tcl';script.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    try:
        routed_config.write_bytes(config)
        log=flow.job('report',[binary/'Implementation.exe','-f',script],1800,cwd=binary)
        if 'FULL_ROUTED_TIMING_COMPLETED' not in log:raise RuntimeError('Full report did not complete')
        database=flow.folder/'full_timing.tan.pb'
        synthesis=json.loads((Path(route['synthesis'])/'summary.json').read_text(encoding='utf-8'))
        netlist=Path(synthesis['netlist'])
        if eda.sha(netlist)!=synthesis['netlist_sha256']:raise RuntimeError('Mapped netlist changed')
        audit_path=flow.folder/'audit'
        proof=check_multicycle.audit(netlist,ROOT/'elinx/constraints.edc',audit_path)
        measured=check_multicycle.timing(database,proof['patterns'],audit_path)
        if not proof['passed'] or not measured['passed']:raise RuntimeError('Multicycle scope/timing audit failed')
        clock=next((row for row in measured['clocks'] if row['name']=='clk'),measured['clocks'][0])
        setup_worst_ns=clock['setup_worst_slack']/1000.0
        flow.result.update(completed=True,timing_database=str(database),audit=str(audit_path),
                           setup_uncertainty_ns=proof['setup_uncertainty_ns'],
                           setup_slack_at_period_ns=round(setup_worst_ns+proof['setup_uncertainty_ns'],6),
                           constrained_registers=proof['constrained_registers'],
                           invalid_registers=proof['invalid_registers'],
                           internal_register_arcs=proof['internal_register_arcs'],
                           uncovered_internal_arcs=proof['uncovered_internal_arcs'],
                           timing=measured)
        print('FULL ROUTED TIMING PASS setup_uncertainty_ns={:g} setup_slack_at_period_ns={:+.3f} '
              .format(proof['setup_uncertainty_ns'],flow.result['setup_slack_at_period_ns'])
              +json.dumps(measured,ensure_ascii=False),flush=True)
    except Exception as error:
        flow.result.update(completed=False,error=str(error))
        print('FULL ROUTED TIMING FAIL '+str(error),flush=True)
    finally:
        if previous is None:routed_config.unlink(missing_ok=True)
        else:routed_config.write_bytes(previous)
        flow.finish()
    return flow.result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--route',type=Path,default=ROOT/'out/latest_AFDX_top_route.json')
    parser.add_argument('--deadline')
    args=parser.parse_args()
    return 0 if report(args.route,args.deadline).get('completed') else 1

if __name__=='__main__':raise SystemExit(main())
