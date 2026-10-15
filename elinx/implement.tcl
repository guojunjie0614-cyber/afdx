if {[catch {
set run {@RUN@}
set base {@BASE@}
set lib [file join $base Infrastructure psk_intern eHiChip6 series_library]
set device [file join $base Infrastructure psk_intern eHiChip6 EQ6HL130]
set top @TOP@
setlogfile [file join $run log4cpp.property] [file join $run implementation.edi]
print_version_information
foreach {name value} {
DEVICE_SERIES eHiChip6 DEVICE_NAME EQ6HL130 PACKAGE_NAME CSG484_H PACKAGE CSG484_H PINS 484
PackAlgName VPack GainHashSize 16 PackAlgSeedPolicy PINS_SEED_POLICY PackAlgGainPolicy SHAREDPINS_GAIN_POLICY
VPACK_ALPHA 50 TVPACK_ALPHA 75 CLB_MaxNumLEs 10 CLB_MaxNumAclrs 2 CLB_MaxNumEnas 2 CLB_MaxNumIns 20
VPACKFULL classic MODULE_PACK 1 CIN_LIST_FULL 0 ALPHA 0.5 FIRST_ITER_PRESFAC 3.0 HEAP_SPREAD_BETA 0.9
HEAP_CONVERGE 0.8 INIT_SA 0 INNERNUM 1 TIMING_TRADEOFF_LAMBDA 0.9 HEAP_STALL_MAX 20 PRES_FAC_MULT 1.3
ASTAR_FAC 1.05 ACC_MULT 1.3 REFINE_RLIM 3 HEAP_WEIGHT_ADD 1 DETAILED_PLACER_ALGORITHM 2
ENABLE_FIX_HOLD_VIOLATE 1 FIX_SETUP_SLACK 1 MAX_ROUTER_ITERATION 150 PROCESS_NAME TT ENABLE_TIMING_ANALYSIS true
} {set_global_assignment -name $name $value}
set_global_assignment -name TOP_LEVEL_ENTITY $top
set_global_assignment -name DESIGN_PATH $run
set_global_assignment -name PROJECT_NAME $top
set_global_assignment -name IMPLE_NAME c3_t6
set_global_assignment -name ProjectName $top
set_global_assignment -name ProjectDirectory "$run/"
set_global_assignment -name PackArchFileName [file join $lib pack_guide.xml]
source [file join $lib arc_guide.tcl]
set_arc_ucm_parameter TILE_DAT_PATH [file join $lib tile]
set_arc_ucm_parameter STRUCTURE_PATH [file join $device CSG484_H structure.dat]
set_arc_ucm_parameter TILE_TIMING_DAT_PATH [file join $device timing_info.dat]
puts "C3_IMPL_STAGE architecture"
flush stdout
arc_deserialize_device_info
arc_deserialize_tile_info
read_port_info -f [file join $lib place_route_guide.xml]
udm_parse_vqm [file join $run design.vqm]
# C3 mapped netlist; tool inputs and logs stay in this private output directory.
set model [file nativename $device]
append model "\\"
load_time_model $model
# constraints.sdc is an output copy of the single source elinx/constraints.edc.
read_sdc [file join $run constraints.sdc]
read_drc_config_file [file join $device elinx_drc.dat]
excute_check_prepack
puts "C3_IMPL_STAGE pack"
flush stdout
create_timing_group
DoReadPackData
DoTVPack $run $top
DoPostPackData $run $top
DoReleasePData $run $top
free_timing_group
write_statistical_info $top -pack -f [file join $run utilization_packed.rpt]
udm_save_checkpoint [file join $run packed.ecp]
udm_write_cluster [file join $run packed_cluster.xml]
excute_check_preplace
puts "C3_IMPL_STAGE place"
flush stdout
create_timing_group
serialize_timing_delay [file join $run pack.dly.pb]
try_place -f [file join $run design.place]
place_clear
serialize_timing_delay [file join $run place.dly.pb]
puts "C3_IMPL_STAGE route"
flush stdout
route_init_arc
route_pro_ucm
route_pro_udm
route_channel
route_internal
write_tiles_nets [file join $run design.tiles.pb]
serialize_timing_delay [file join $run route.dly.pb]
compute_driven_slack
free_timing_group
write_route_status_rpt [file join $run route_status_before_export.rpt]
route_write_results -f [file join $run design.route]
route_write_results -udm
write_statistical_info $top -f [file join $run utilization_routed.rpt]
write_route_status_rpt [file join $run route_status.rpt]
udm_save_checkpoint [file join $run routed.ecp]
# Routed timing is diagnostic only; export resources/checkpoint first.
if {[catch {
build_timing_graph
deserialize_timing_delay [file join $run route.dly.pb]
generate_eda_netlist [file join $lib sdf_guide.xml] [file join $run design.sdo]
serialize_timing_graph [file join $run design.tbg.pb]
show_fmax 1
compute_clock_fmax
print_timing_report [file join $run routed_timing.rpt]
free_timing_graph
} timing_message]} {puts "C3_ROUTED_TIMING_UNAVAILABLE $timing_message"}
route_delete_interface
puts "C3_IMPL_STAGE completed"
} message options]} {puts "C3_IMPL_FAILED $message";puts [dict get $options -errorinfo];exit 1}
exit 0
