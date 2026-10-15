<#
.SYNOPSIS
按工程设置运行与 eLinx Run Synthesis 相同的官方综合、装箱和综合后时序。
.PARAMETER Top
可选兼容参数，必须与工程的综合顶层相同。
.PARAMETER Sta
兼容原命令；综合后时序默认执行，约束取自工程。
.PARAMETER Deadline
可选任务硬截止ISO时间；工具仅停止自己的精确进程树。
#>
param(
 [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')][string]$Top,
 [switch]$Sta,
 [string]$Deadline
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$arguments=@('-B','-X','utf8',(Join-Path $root 'tools/official_synth.py'))
if($Top){$arguments+=@('--top',$Top)}
if($Deadline){$arguments+=@('--deadline',$Deadline)}
$python=if($env:AFDX_PYTHON){$env:AFDX_PYTHON}else{(Get-Command python -ErrorAction Stop).Source}
& $python @arguments
exit $LASTEXITCODE
