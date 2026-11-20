# Original RTL compiles directly in standard environments; declaration-order copy fallback is opt-in only.
proc afdx_modelsim_rtl {root folder} {
    if {![info exists ::env(AFDX_MODELSIM_DECL_ORDER)] || $::env(AFDX_MODELSIM_DECL_ORDER) ne "1"} {
        return [lsort [glob [file join $root rtl *.v]]]
    }
    if {![info exists ::env(AFDX_PYTHON)] || ![file isfile $::env(AFDX_PYTHON)]} {
        error "ModelSim compatibility-copy fallback requires AFDX_PYTHON; original RTL is unchanged"
    }
    set report [exec $::env(AFDX_PYTHON) -B -X utf8 [file join $root tools prepare_modelsim.py] \
        --rtl [file join $root rtl] --folder $folder]
    return [split [string trim $report] "\n"]
}
