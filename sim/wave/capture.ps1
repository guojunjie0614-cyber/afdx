# 捕获指定的本次 ModelSim Wave 窗口，不截取桌面或其他应用。
param([string]$SessionProcessIds,[string]$Destination)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WaveCapture {
    [StructLayout(LayoutKind.Sequential)] public struct Rect {public int L,T,R,B;}
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
    public delegate bool Visitor(IntPtr h,IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Visitor visit,IntPtr data);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder text,int size);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
$null=[WaveCapture]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
$windows=New-Object 'System.Collections.Generic.List[System.IntPtr]'
$ownedIds=@($SessionProcessIds.Split(',') | ForEach-Object {[uint32]$_})
$ownedTitles=New-Object 'System.Collections.Generic.List[string]'
$visitor=[WaveCapture+Visitor]{param([IntPtr]$window,[IntPtr]$data)
    $owner=[uint32]0
    $null=[WaveCapture]::GetWindowThreadProcessId($window,[ref]$owner)
    $title=New-Object System.Text.StringBuilder 256
    $null=[WaveCapture]::GetWindowText($window,$title,$title.Capacity)
    if($ownedIds -contains $owner){
        $ownedTitles.Add("$owner : $($title.ToString())")
        if($title.ToString().Contains('tx_bag')){$windows.Add($window)}
    }
    return $true
}
$null=[WaveCapture]::EnumWindows($visitor,[IntPtr]::Zero)
if($windows.Count -ne 1){throw "Expected one Wave tx_bag window; found $($windows.Count). Session windows: $($ownedTitles -join '; ')"}
$handle=$windows[0]
$rectangle=New-Object WaveCapture+Rect
if(![WaveCapture]::GetWindowRect($handle,[ref]$rectangle)){throw 'Cannot get Wave window rectangle'}
$picture=New-Object System.Drawing.Bitmap ($rectangle.R-$rectangle.L),($rectangle.B-$rectangle.T)
$graphics=[System.Drawing.Graphics]::FromImage($picture)
try {
    $dc=$graphics.GetHdc()
    try {
        if(![WaveCapture]::PrintWindow($handle,$dc,2)){throw 'ModelSim Wave window capture failed'}
    } finally {$graphics.ReleaseHdc($dc)}
    $picture.Save($Destination,[System.Drawing.Imaging.ImageFormat]::Png)
} finally {$graphics.Dispose();$picture.Dispose()}
