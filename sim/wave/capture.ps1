# 捕获指定的本次 ModelSim Wave 窗口，不截取桌面或其他应用。
param([string]$SessionProcessIds,[string]$Destination,[string]$WindowTitle='Wave')
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
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
    public delegate bool Visitor(IntPtr h,IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Visitor visit,IntPtr data);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder text,int size);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
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
        if($title.ToString() -eq $WindowTitle){$windows.Add($window)}
    }
    return $true
}
$null=[WaveCapture]::EnumWindows($visitor,[IntPtr]::Zero)
if($windows.Count -ne 1){throw "Expected one $WindowTitle window; found $($windows.Count). Session windows: $($ownedTitles -join '; ')"}
$handle=$windows[0]
# 与旧版 ModelSim 的 DPI 上下文一致，避免将逻辑像素绘制进物理像素画布。
$null=[WaveCapture]::SetThreadDpiAwarenessContext([WaveCapture]::GetWindowDpiAwarenessContext($handle))
# 布局和缩放由 do 脚本确定；仅还原本次所属的最小化窗口。
if([WaveCapture]::IsIconic($handle)){$null=[WaveCapture]::ShowWindow($handle,9)}
Start-Sleep -Milliseconds 500
$rectangle=New-Object WaveCapture+Rect
if(![WaveCapture]::GetWindowRect($handle,[ref]$rectangle)){throw 'Cannot get Wave window rectangle'}
if([WaveCapture]::IsIconic($handle) -or ($rectangle.R-$rectangle.L) -lt 600 -or ($rectangle.B-$rectangle.T) -lt 300){throw 'Wave window is minimized or too small to contain readable waveform evidence'}
$picture=New-Object System.Drawing.Bitmap ($rectangle.R-$rectangle.L),($rectangle.B-$rectangle.T)
$graphics=[System.Drawing.Graphics]::FromImage($picture)
try {
    $dc=$graphics.GetHdc()
    try {
        if(![WaveCapture]::PrintWindow($handle,$dc,2)){throw 'ModelSim Wave window capture failed'}
    } finally {$graphics.ReleaseHdc($dc)}
    $picture.Save($Destination,[System.Drawing.Imaging.ImageFormat]::Png)
} finally {$graphics.Dispose();$picture.Dispose()}
"Wave pixels: $($rectangle.R-$rectangle.L)x$($rectangle.B-$rectangle.T); DPI awareness: $([WaveCapture]::GetAwarenessFromDpiAwarenessContext([WaveCapture]::GetWindowDpiAwarenessContext($handle)))"
