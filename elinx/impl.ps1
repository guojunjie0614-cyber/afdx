<#
.SYNOPSIS
接续 synth.ps1 的结果，运行官方默认布局布线并输出布线后时序。
.PARAMETER Deadline
可选任务硬截止 ISO 时间；工具仅停止自己的精确进程树。
#>
param([string]$Deadline)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$arguments=@('-B','-X','utf8',(Join-Path $root 'tools/official_impl.py'))
if($Deadline){$arguments+=@('--deadline',$Deadline)}
$python=if($env:AFDX_PYTHON){$env:AFDX_PYTHON}else{(Get-Command python -ErrorAction Stop).Source}
& $python @arguments
exit $LASTEXITCODE
