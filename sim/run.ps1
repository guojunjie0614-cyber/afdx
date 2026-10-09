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
exit $LASTEXITCODE
