# 先在 eLinx 中运行 Run Synthesis，再执行本入口。
param(
 [ValidateSet('tb_elinx','tb_net_services')][string]$Test='tb_elinx',
 [string]$Netlist,
 [string]$Deadline
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$arguments=@('-B','-X','utf8',(Join-Path $root 'tools/gui_netlist.py'),'--test',$Test)
if($Netlist){$arguments+=@('--netlist',$Netlist)}
if($Deadline){$arguments+=@('--deadline',$Deadline)}
$python=if($env:AFDX_PYTHON){$env:AFDX_PYTHON}else{(Get-Command python -ErrorAction Stop).Source}
& $python @arguments
exit $LASTEXITCODE
