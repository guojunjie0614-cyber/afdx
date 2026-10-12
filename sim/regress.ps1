<#
.SYNOPSIS
RTL回归；-Netlist按tests_netlist.txt的测试|综合顶层列表，复用out/latest_<顶层>.json对应网表。
.PARAMETER Netlist
不重新综合。清单每行形如tb_mac_loop|afdx_timebase,afdx_mac_tx,afdx_mac_rx。
#>
param([switch]$Netlist,[string]$Deadline,[int]$Seed=20261007)
$ErrorActionPreference='Stop'
$rows=@()
$pwsh=(Get-Process -Id $PID).Path
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$batchStarted=Get-Date
$batchPath=Join-Path $root ('out/regress/'+$(if($Netlist){'net_'}else{'rtl_'})+$batchStarted.ToString('yyyyMMdd_HHmmss_fffffff'))
$null=New-Item -ItemType Directory -Path $batchPath
$list=if($Netlist){'tests_netlist.txt'}else{'tests.txt'}
foreach($line in Get-Content (Join-Path $PSScriptRoot $list)){
 $test=$line.Trim()
 if(!$test -or $test.StartsWith('#')){continue}
 $parts=$test.Split('|');$test=$parts[0]
 $invokeArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'run.ps1'),'-Test',$test,'-Seed',"$Seed")
 if($Netlist){
  $paths=@()
  foreach($top in $parts[1].Split(',')){
   $summary=Get-Content -LiteralPath (Join-Path $root "out/latest_$top.json") -Raw | ConvertFrom-Json
   if(!$summary.completed){throw "综合未完成：$top"}
   $path=Join-Path $summary.folder 'netlist.v'
   if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $summary.netlist_sha256){throw "网表摘要不一致：$top"}
   foreach($source in $summary.inputs){
    if((Get-FileHash -LiteralPath $source.path -Algorithm SHA256).Hash -ne $source.sha256){throw "综合后源码已变化，请重新综合：$top / $($source.path)"}
   }
   $paths+=$path
  }
  $invokeArgs+=@('-Netlist',($paths -join ','))
 }
 $paramIndex=if($Netlist){2}else{1}
 if($parts.Count -gt $paramIndex -and $parts[$paramIndex]){$invokeArgs+=@('-Param',$parts[$paramIndex])}
 if($Deadline){$invokeArgs+=@('-Deadline',$Deadline)}
 & $pwsh @invokeArgs
 $code=$LASTEXITCODE
 $runSummary=Get-Content -LiteralPath (Join-Path $root "out/latest_$test.json") -Raw | ConvertFrom-Json
 $rows+=[pscustomobject]@{Test=$test;Param=if($parts.Count -gt $paramIndex){$parts[$paramIndex]}else{''};Status=if($code -eq 0){'PASS'}else{'FAIL'};Exit=$code;Folder=$runSummary.folder;Checks=$runSummary.checks;CheckItems=$runSummary.check.items}
 [pscustomobject]@{Started=$batchStarted.ToString('o');Netlist=[bool]$Netlist;Runs=$rows} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $batchPath 'summary.json') -Encoding utf8
}
$rows | Format-Table Test,Param,Status,Exit,Checks,CheckItems -AutoSize
Write-Output "回归证据：$batchPath"
if(!$rows.Count -or @($rows | Where-Object Exit -ne 0).Count){exit 1}
exit 0
