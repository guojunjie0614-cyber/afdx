<#
.SYNOPSIS
C3 EQ6HL130/CSG484_H原生综合，-Sta额外执行125MHz未布局时序估算。
.PARAMETER Top
rtl/和elinx/probe/中的顶层模块；参数固定包装用于探测。
.PARAMETER Sta
使用8ns时钟，不加虚假I/O预算、false-path或多周期约束。
.PARAMETER Deadline
可选任务硬截止ISO时间；工具仅停止自己的精确进程树。
#>
param(
 [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$Top,
 [switch]$Sta,
 [string]$Deadline
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$arguments=@((Join-Path $root 'tools/eda.py'),'synth','--top',$Top)
if($Sta){$arguments+='--sta'}
if($Deadline){$arguments+=@('--deadline',$Deadline)}
$python=if($env:AFDX_PYTHON){$env:AFDX_PYTHON}else{(Get-Command python -ErrorAction Stop).Source}
& $python -X utf8 @arguments
exit $LASTEXITCODE
