<#
.SYNOPSIS
编译并执行C3端口测试；原始输出保存在out/sim。
.PARAMETER Test
tb/目录中的测试模块名。
.PARAMETER Netlist
一个或多个原始netlist.v；替换同名RTL模块。命令行多个路径可用逗号分隔。
.PARAMETER Seed
独立参考向量的随机种子，默认20261007。
.PARAMETER Param
顶层参数 NAME=value，多个值可用逗号分隔。
.PARAMETER Deadline
可选的整个调用硬截止ISO时间，不会延长任务卡预算。
#>
param(
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$Test,
 [string[]]$Netlist,
 [string[]]$Param,
 [int]$Seed=20261007,
 [string]$Deadline
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$arguments=@((Join-Path $root 'tools/eda.py'),'sim','--test',$Test)
$arguments+=@('--seed',"$Seed")
if($Netlist){$arguments+='--netlist';foreach($item in $Netlist){$arguments+=($item -split ',')}}
if($Param){foreach($item in $Param){foreach($value in ($item -split ',')){$arguments+=@('--param',$value)}}}
if($Deadline){$arguments+=@('--deadline',$Deadline)}
$python=if($env:AFDX_PYTHON){$env:AFDX_PYTHON}else{(Get-Command python -ErrorAction Stop).Source}
& $python -X utf8 @arguments
$runExit=$LASTEXITCODE
if($runExit -eq 0 -and $Test -in @('tb_sys_perf','tb_sys_rtc')){
 $latest=Get-Content -LiteralPath (Join-Path $root "out/latest_$Test.json") -Raw | ConvertFrom-Json
 $metrics=Get-Content -LiteralPath (Join-Path $latest.folder 'check_summary.json') -Raw | ConvertFrom-Json
 if($Test -eq 'tb_sys_perf'){
  foreach($stage in @('gbe77_d0','gbe77_d257')){
   foreach($direction in $metrics.reports.system.performance.$stage.directions.PSObject.Properties){
    $value=$direction.Value
    Write-Output ('[METRIC] tb_sys_perf stage={0} direction={1} delivered_mbps={2:F3} max_e2e_us={3:F3} jitter_us={4:F3}' -f $stage,$direction.Name,$value.delivered_mbps,$value.T_e2e_link_removed.max_us,$value.jitter.max_us)
   }
  }
 }else{
  Write-Output ('[METRIC] tb_sys_rtc idle_max_ns={0} loaded_max_ns={1} gbe77_max_ns={2}' -f $metrics.idle_max_ns,$metrics.loaded_max_ns,$metrics.gbe_max_ns)
 }
}
exit $runExit
