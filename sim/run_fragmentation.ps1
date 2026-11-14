param([int]$TimeoutSeconds=5400)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path $root ('out/fragmentation/'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force $out | Out-Null
Write-Host "Fragmentation outputs: $out"
function Find-Icarus([string]$Name) {
 if ($env:IVERILOG_HOME) {
  foreach ($leaf in @($Name,($Name+'.exe'))) {
   $candidate=Join-Path (Join-Path $env:IVERILOG_HOME 'bin') $leaf
   if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
  }
 }
 $command=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
 if ($command) { return $command.Source }
 foreach ($leaf in @(($Name+'.exe'),$Name)) {
  $candidate=Join-Path 'C:/iverilog/bin' $leaf
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
 }
 throw "Icarus $Name not found: checked IVERILOG_HOME/bin, PATH, and C:/iverilog/bin"
}
$iv=Find-Icarus 'iverilog'; $vvp=Find-Icarus 'vvp'
$python=(Get-Command python -ErrorAction Stop).Source
# Start-Process timeout avoids a hung simulator; exit status and log sentinel are both mandatory.
function Invoke-Bounded([string]$Exe,[string[]]$Arguments,[string]$Log,[int]$Limit) {
 $info=New-Object System.Diagnostics.ProcessStartInfo
 $info.FileName=$Exe; $info.WorkingDirectory=$out; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 # The Windows command line parser uses quoted arguments; escape embedded quotes/backslashes.
 $info.Arguments=($Arguments | ForEach-Object { '"' + ($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' }) -join ' '
 $proc=New-Object System.Diagnostics.Process; $proc.StartInfo=$info
 if (!$proc.Start()) { throw "Cannot start $Exe" }
 $stdout=$proc.StandardOutput.ReadToEndAsync();$stderr=$proc.StandardError.ReadToEndAsync()
 $timedOut=!$proc.WaitForExit($Limit*1000)
 if ($timedOut) { $proc.Kill() }
 $proc.WaitForExit(); [IO.File]::WriteAllText($Log,$stdout.Result+$stderr.Result)
 if ($timedOut) { throw "Timeout after $Limit seconds: $Exe; see $Log" }
 if ($proc.ExitCode -ne 0) { throw "$Exe failed ($($proc.ExitCode)); see $Log" }
}
try {
 Invoke-Bounded $python @((Join-Path $root 'tools/fragment_ref.py'),'selftest') (Join-Path $out 'reference.log') $TimeoutSeconds
 Invoke-Bounded $python @((Join-Path $root 'tools/fragment_integration.py'),'prepare',$out) (Join-Path $out 'prepare.log') $TimeoutSeconds
 $sources=@(Get-ChildItem (Join-Path $root 'rtl/*.v') | Sort-Object Name | ForEach-Object { $_.FullName })
 $compile=@('-g2005','-s','tb_fragmentation','-o',(Join-Path $out 'tb_fragmentation.vvp'))+$sources+@((Join-Path $root 'tb/tb_fragmentation.v'))
 Invoke-Bounded $iv $compile (Join-Path $out 'compile.log') $TimeoutSeconds
 Invoke-Bounded $vvp @((Join-Path $out 'tb_fragmentation.vvp')) (Join-Path $out 'simulation.log') $TimeoutSeconds
 if ((Get-Content (Join-Path $out 'simulation.log') -Raw) -notmatch '\[RESULT\] tb_fragmentation PASS errors=0') { throw 'Simulation did not pass; see simulation.log' }
 Invoke-Bounded $python @((Join-Path $root 'tools/fragment_integration.py'),'check',$out) (Join-Path $out 'check.log') $TimeoutSeconds
 Write-Host "[RESULT] fragmentation PASS; outputs: $out"
} catch { Write-Error $_; exit 1 }
