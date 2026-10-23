<#
.SYNOPSIS
    Apex Config Tool - tunes Apex Legends' videoconfig.txt for the PC it runs on.

.DESCRIPTION
    Reads the game's own videoconfig.txt, detects this PC's hardware, and patches only the values
    that should change (it never replaces the whole file). Every apply makes a timestamped backup
    that can be restored from the window. Optionally writes the FPS cap into Steam's launch options.

    Run with the game closed, after the game has been launched at least once.

.PARAMETER Silent
    No window. Detects hardware, applies the chosen preset (default: Auto), prints a summary.

.PARAMETER DryRun
    With -Silent: show what would change without writing anything.

.PARAMETER Preset
    With -Silent: Auto, Competitive, MaxFPS, Extreme, Balanced, GameLow, GameHigh or FiTH.

.PARAMETER ConfigPath
    Override the videoconfig.txt path (default: Saved Games\Respawn\Apex\local\videoconfig.txt).

.PARAMETER SteamPath
    Override the Steam folder (default: read from the registry).
#>
[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$DryRun,
    [string]$Preset = 'Auto',
    [string]$ConfigPath,
    [string]$SteamPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# ---------------------------------------------------------------------------------------------
#  Game constants - edit this block to support a future release
# ---------------------------------------------------------------------------------------------
$ToolName      = 'g1gGLe''z Apex Performance Tool'
$ToolVersion   = '1.0.1'
$Links = @{
    Discord  = 'https://discord.gg/Br7z7zBvFb'
    YouTube  = 'https://www.youtube.com/user/FiTHGAMINGOFFICIAL'
    Facebook = 'https://www.facebook.com/FiTHGAMINGOFFICIAL/'
    Steam    = 'https://steamcommunity.com/groups/FiTHOFFICIAL'
    Website  = 'https://fithgaming.co.uk/apex/'
}
$ConfigVersion = '10'                          # videoconfig.txt format this tool was built and tested on
$SteamAppId    = '1172470'                     # Apex Legends on Steam
$GameProcesses = @('r5apex', 'r5apex_dx12')    # r5apex.exe / r5apex_dx12.exe

function Get-SavedGamesPath {
    # Windows can move Saved Games; the real location is in the user's shell folders.
    try {
        $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $v = $p.PSObject.Properties['{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}']
        if ($v -and $v.Value) { return [Environment]::ExpandEnvironmentVariables([string]$v.Value) }
    } catch { }
    $userProfile = $env:USERPROFILE
    if (-not $userProfile) { $userProfile = [Environment]::GetFolderPath('UserProfile') }
    return (Join-Path $userProfile 'Saved Games')
}

if (-not $ConfigPath) { $ConfigPath = Join-Path (Get-SavedGamesPath) 'Respawn\Apex\local\videoconfig.txt' }
$ConfigDir = Split-Path $ConfigPath

$LocalAppData = $env:LOCALAPPDATA
if (-not $LocalAppData) { $LocalAppData = [IO.Path]::GetTempPath() }
$BackupRoot = Join-Path $LocalAppData 'ApexConfigTool\backups'

$Inv = [Globalization.CultureInfo]::InvariantCulture
function F6([double]$x) { $x.ToString('0.000000', $Inv) }                          # 1.000000
function FTrim([double]$x) { $s = $x.ToString('0.######', $Inv); if ($s -eq '-0') { '0' } else { $s } }   # 0.75, 2, 1

# ---------------------------------------------------------------------------------------------
#  videoconfig.txt reading / writing
# ---------------------------------------------------------------------------------------------
# A setting line looks like:   <tab>"setting.mat_picmip"<tab><tab>"1"
$LineRegex = '^(?<pre>\s*"setting\.)(?<key>[^"]+)(?<mid>"\s+")(?<val>[^"]*)(?<post>".*)$'

function Read-ApexFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
    $lines = $text -split "`r?`n"
    $values = [ordered]@{}
    foreach ($l in $lines) {
        $m = [regex]::Match($l, $LineRegex)
        if ($m.Success) { $values[$m.Groups['key'].Value] = $m.Groups['val'].Value }
    }
    [pscustomobject]@{ Path = $Path; Lines = $lines; NewLine = $nl; Values = $values }
}

function Write-ApexFile($File, $Changes) {
    $out = foreach ($l in $File.Lines) {
        $m = [regex]::Match($l, $LineRegex)
        if ($m.Success -and $Changes.Contains($m.Groups['key'].Value)) {
            $m.Groups['pre'].Value + $m.Groups['key'].Value + $m.Groups['mid'].Value + $Changes[$m.Groups['key'].Value] + $m.Groups['post'].Value
        } else { $l }
    }
    Write-TextSafely $File.Path ($out -join $File.NewLine)
}

# Writes next to the target first, then swaps it in, so a crash can't leave a half-written file.
function Write-TextSafely([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp-apextool"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-PositiveInt($Text) {
    if ($null -eq $Text) { return $null }
    $s = ([string]$Text).Trim()
    if ($s -notmatch '^\d{1,9}$') { return $null }
    $n = [int]$s
    if ($n -gt 0) { return $n }
    return $null
}

function ConvertTo-Num([string]$s) {
    if ($s -notmatch '^\s*-?\d+(\.\d+)?\s*$') { return $null }
    return [double]::Parse($s.Trim(), $Inv)
}

# "0.6" and "0.600000" are the same value to the game - don't list them as a change.
function Test-SameValue([string]$a, [string]$b) {
    if ($a -ceq $b) { return $true }
    $x = ConvertTo-Num $a; $y = ConvertTo-Num $b
    if ($null -ne $x -and $null -ne $y) { return ([math]::Abs($x - $y) -lt 0.0000005) }
    return $false
}

# ---------------------------------------------------------------------------------------------
#  Steam launch options (localconfig.vdf) - only the LaunchOptions line of Apex is ever touched
# ---------------------------------------------------------------------------------------------
$VdfTokenRegex = '"((?:[^"\\]|\\.)*)"|\{|\}'

function Get-SteamRoot {
    if ($SteamPath) { if (Test-Path -LiteralPath $SteamPath) { return $SteamPath } else { return $null } }
    try {
        $p = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop
        if ($p.PSObject.Properties['SteamPath'] -and $p.SteamPath) {
            $s = ([string]$p.SteamPath) -replace '/', '\'
            if (Test-Path -LiteralPath $s) { return $s }
        }
    } catch { }
    foreach ($s in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
        if ($s -and (Test-Path -LiteralPath $s)) { return $s }
    }
    return $null
}

function ConvertFrom-VdfString([string]$s) { ($s -replace '\\"', '"') -replace '\\\\', '\' }
function ConvertTo-VdfString([string]$s)   { ($s -replace '\\', '\\') -replace '"', '\"' }

# Finds the Apex block and its LaunchOptions value inside one localconfig.vdf text.
function Find-VdfLaunchOptions([string]$Text) {
    $stack = New-Object System.Collections.Generic.List[string]
    $pending = $null
    $want = "software/valve/steam/apps/$SteamAppId"
    $res = [pscustomobject]@{ Found = $false; BraceIndex = -1; Depth = 0; Value = $null; ValueIndex = -1; ValueLength = 0 }
    foreach ($m in [regex]::Matches($Text, $VdfTokenRegex)) {
        $t = $m.Value
        if ($t -eq '{') {
            $k = ''; if ($null -ne $pending) { $k = $pending.Groups[1].Value }
            $stack.Add($k.ToLowerInvariant()); $pending = $null
            if (-not $res.Found -and $stack.Count -ge 5) {
                $tail = ($stack.GetRange($stack.Count - 5, 5)) -join '/'
                if ($tail -eq $want) { $res.Found = $true; $res.BraceIndex = $m.Index; $res.Depth = $stack.Count }
            }
        } elseif ($t -eq '}') {
            if ($res.Found -and $stack.Count -eq $res.Depth) { return $res }   # end of the Apex block
            if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }
            $pending = $null
        } elseif ($null -eq $pending) {
            $pending = $m
        } else {
            if ($res.Found -and $stack.Count -eq $res.Depth -and $pending.Groups[1].Value -ieq 'LaunchOptions') {
                $res.Value = ConvertFrom-VdfString $m.Groups[1].Value
                $res.ValueIndex = $m.Groups[1].Index; $res.ValueLength = $m.Groups[1].Length
            }
            $pending = $null
        }
    }
    return $res
}

function Get-SteamConfigs {
    $list = New-Object System.Collections.Generic.List[object]
    $root = Get-SteamRoot
    if (-not $root) { return ,$list }
    $ud = Join-Path $root 'userdata'
    if (-not (Test-Path -LiteralPath $ud)) { return ,$list }
    foreach ($d in @(Get-ChildItem -LiteralPath $ud -Directory -ErrorAction SilentlyContinue)) {
        $p = Join-Path (Join-Path $d.FullName 'config') 'localconfig.vdf'
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
            $f = Find-VdfLaunchOptions $text
            if ($f.Found) {
                $cur = ''; if ($null -ne $f.Value) { $cur = $f.Value }
                $list.Add([pscustomobject]@{ Path = $p; Account = $d.Name; Current = $cur })
            }
        } catch { }
    }
    return ,$list
}

function Set-VdfLaunchOptions([string]$Path, [string]$NewValue) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $f = Find-VdfLaunchOptions $text
    if (-not $f.Found) { throw "Apex Legends isn't listed in $Path." }
    $esc = ConvertTo-VdfString $NewValue
    if ($f.ValueIndex -ge 0) {
        $out = $text.Substring(0, $f.ValueIndex) + $esc + $text.Substring($f.ValueIndex + $f.ValueLength)
    } else {
        # No LaunchOptions line yet: add one straight after the block's opening brace, matching Steam's tabs.
        $nl = "`n"; if ($text.Contains("`r`n")) { $nl = "`r`n" }
        $lineStart = $text.LastIndexOf("`n", [math]::Max(0, $f.BraceIndex - 1)) + 1
        $indent = ([regex]::Match($text.Substring($lineStart), '^\t*')).Value + "`t"
        $ins = $nl + $indent + '"LaunchOptions"' + "`t`t" + '"' + $esc + '"'
        $out = $text.Substring(0, $f.BraceIndex + 1) + $ins + $text.Substring($f.BraceIndex + 1)
    }
    Write-TextSafely $Path $out
    # Check what Steam will read back
    $check = Find-VdfLaunchOptions ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
    if (-not $check.Found -or $check.Value -cne $NewValue) { throw "Steam launch options didn't save correctly in $Path." }
}

# Keeps every other launch option and only replaces the +fps_max part.
function Get-NewLaunchOptions([string]$Current, $Cap) {
    $s = [regex]::Replace([string]$Current, '(^|\s)[+-]fps_max(\s+\S+)?', ' ')
    $s = ([regex]::Replace($s, '\s+', ' ')).Trim()
    if ($null -ne $Cap) { $s = ("$s +fps_max $Cap").Trim() }
    return $s
}

function Test-SteamRunning { return [bool](Get-Process -Name steam -ErrorAction SilentlyContinue) }

function Stop-SteamCleanly {
    $root = Get-SteamRoot
    $exe = $(if ($root) { Join-Path $root 'steam.exe' } else { $null })
    if ($exe -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe -ArgumentList '-shutdown' | Out-Null }
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Test-SteamRunning)) { Start-Sleep -Milliseconds 800; return $true }   # give it a moment to finish writing
        Start-Sleep -Milliseconds 500
    }
    return (-not (Test-SteamRunning))
}

# ---------------------------------------------------------------------------------------------
#  Hardware detection (each step falls back to what the game itself recorded)
# ---------------------------------------------------------------------------------------------
# Built-in graphics on the CPU (Ryzen "Radeon Graphics", Intel UHD/Iris) - never the card you game on
$IntegratedGpu = '^(AMD )?Radeon(\(TM\))? (Graphics|Vega|\d{3}M)|Intel\(R\) (UHD|Iris|HD) |Basic|Virtual|Parsec|Remote|Meta|Mirage|DisplayLink'

function Get-GpuRank([string]$Name) {
    if (-not $Name -or $Name -match $IntegratedGpu) { return 0 }
    if ($Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon|Arc') { return 2 }
    return 1
}

# Every graphics adapter Windows knows, with its real video memory (WMI caps VRAM at 4 GB, the registry doesn't).
function Get-GpuList {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.PSObject.Properties['DriverDesc']) { continue }
            $bytes = [uint64]0
            $q = $p.PSObject.Properties['HardwareInformation.qwMemorySize']
            if ($q -and $null -ne $q.Value) {
                $bytes = $(if ($q.Value -is [byte[]]) { [BitConverter]::ToUInt64($q.Value, 0) } else { [uint64]$q.Value })
            } else {
                $d = $p.PSObject.Properties['HardwareInformation.MemorySize']
                if ($d -and $null -ne $d.Value) { $bytes = $(if ($d.Value -is [byte[]]) { [uint64][BitConverter]::ToUInt32($d.Value, 0) } else { [uint64]$d.Value }) }
            }
            $list.Add([pscustomobject]@{ Name = [string]$p.DriverDesc; Bytes = $bytes })
        }
    } catch { }
    if ($list.Count -eq 0) {
        try { foreach ($c in @(Get-CimInstance Win32_VideoController)) { $list.Add([pscustomobject]@{ Name = [string]$c.Name; Bytes = [uint64]$c.AdapterRAM }) } } catch { }
    }
    return ,$list
}

# The gaming card: a dedicated GPU first, then the one with the most video memory.
function Select-GamingGpu {
    $all = Get-GpuList
    $pick = $all | Sort-Object @{ Expression = { Get-GpuRank $_.Name }; Descending = $true }, @{ Expression = { $_.Bytes }; Descending = $true } | Select-Object -First 1
    if (-not $pick) { return $null }
    $vram = $null
    if ($pick.Bytes -gt 0) { $vram = [int][math]::Round($pick.Bytes / 1GB); if ($vram -lt 1) { $vram = $null } }
    if (-not $vram -and $pick.Name -match 'NVIDIA|GeForce|RTX|GTX') {
        try {
            $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if ($smi) {
                $mib = & $smi.Source --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                if ($mib) { $vram = [int][math]::Round([double]$mib / 1024) }
            }
        } catch { }
    }
    [pscustomobject]@{ Name = $pick.Name; VramGB = $vram }
}

# Refresh rate and resolution of the main monitor, straight from Windows' display settings.
function Get-PrimaryDisplayMode {
    try {
        if (-not ('ApexTool.Display' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace ApexTool {
  public static class Display {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
      public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
      public int dmFields; public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
      public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
      public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
      public int dmDisplayFlags; public int dmDisplayFrequency;
      public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
      public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    public static int[] Current() {
      DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(null, -1, ref dm)) return null;
      return new int[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency };
    }
  }
}
"@
        }
        $m = [ApexTool.Display]::Current()
        if ($m -and $m[2] -gt 1) { return [pscustomobject]@{ Width = $m[0]; Height = $m[1]; Hz = $m[2] } }
    } catch { }
    # Fallback: whichever adapter is actually driving a screen
    try {
        $vc = @(Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentRefreshRate -gt 1 }) | Sort-Object CurrentRefreshRate -Descending | Select-Object -First 1
        if ($vc) { return [pscustomobject]@{ Width = [int]$vc.CurrentHorizontalResolution; Height = [int]$vc.CurrentVerticalResolution; Hz = [int]$vc.CurrentRefreshRate } }
    } catch { }
    return $null
}

function Get-HardwareInfo($File) {
    $v = $File.Values
    $hw = [ordered]@{
        CpuName = ''; Cores = $null; Threads = $null
        GpuName = ''; VramGB = $null
        Width = $null; Height = $null; RefreshHz = $null; RamGB = $null
    }
    try {
        $cpu = @(Get-CimInstance Win32_Processor)
        $hw.CpuName = ([string]$cpu[0].Name).Trim()
        $hw.Cores   = [int](($cpu | Measure-Object NumberOfCores -Sum).Sum)
        $hw.Threads = [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    } catch { }
    if (-not $hw.Threads) { $hw.Threads = [Environment]::ProcessorCount }
    if (-not $hw.Cores)   { $hw.Cores = $hw.Threads }

    $gpu = Select-GamingGpu
    if ($gpu) { $hw.GpuName = $gpu.Name; $hw.VramGB = $gpu.VramGB }
    $disp = Get-PrimaryDisplayMode
    if ($disp) { $hw.RefreshHz = $disp.Hz }

    # Resolution: the one the game is set to, else the desktop's
    $w = ConvertTo-PositiveInt $(if ($v.Contains('defaultres')) { $v['defaultres'] } else { $null })
    $h = ConvertTo-PositiveInt $(if ($v.Contains('defaultresheight')) { $v['defaultresheight'] } else { $null })
    if ($w -and $h) { $hw.Width = $w; $hw.Height = $h }
    elseif ($disp -and $disp.Width -gt 0) { $hw.Width = $disp.Width; $hw.Height = $disp.Height }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.TotalPhysicalMemory) { $hw.RamGB = [int][math]::Round([double]$cs.TotalPhysicalMemory / 1GB) }
    } catch { }
    return $hw
}

# ---------------------------------------------------------------------------------------------
#  Presets - the same values as the online Config Builder (fithgaming.co.uk/apex)
# ---------------------------------------------------------------------------------------------
$PresetOrder = @('Competitive', 'MaxFPS', 'Extreme', 'Balanced', 'GameLow', 'GameHigh', 'FiTH')
$Presets = @{
    Competitive = @{ Name = 'Competitive'; Desc = 'Everything low except what helps you see players. Model detail stays at full distance, textures stay fairly sharp, and sun shadows are off so enemies don''t hide in them.'
        V = @{ stream = '1000000'; picmip = 1; filter = 'a4'; lod = 1; mapDetail = 1; fade = 1; effects = 'low'; particleCpu = 0; ragdolls = 0; ragdollCol = 0; gibs = 0; decals = 0; spot = 'off'; sun = 'off'; volumetric = 0; ssao = 0; aa = 0 } }
    MaxFPS = @{ Name = 'Max FPS'; Desc = 'The game''s own Low, plus the extras the menu can''t do. Sun shadows and ragdoll physics off. Everything else stays within normal ranges.'
        V = @{ stream = '0'; picmip = 2; filter = 'bilinear'; lod = 0.6; mapDetail = 1; fade = 1; effects = 'low'; particleCpu = 0; ragdolls = 0; ragdollCol = 0; gibs = 0; decals = 0; spot = 'off'; sun = 'off'; volumetric = 0; ssao = 0; aa = 0 } }
    Extreme = @{ Name = 'Extreme'; Desc = 'Below the game''s Low, for weak PCs. Very blurry textures, the lowest model detail and small objects fading out early.'
        V = @{ stream = '0'; picmip = 4; filter = 'bilinear'; lod = 0; mapDetail = 1; fade = 0.75; effects = 'low'; particleCpu = 0; ragdolls = 0; ragdollCol = 0; gibs = 0; decals = 0; spot = 'off'; sun = 'off'; volumetric = 0; ssao = 0; aa = 0 } }
    Balanced = @{ Name = 'Balanced'; Desc = 'Looks good, runs well. High textures and effects with the most expensive lighting turned down. For mid-range and better PCs.'
        V = @{ stream = '1000000'; picmip = 0; filter = 'a4'; lod = 1; mapDetail = 2; fade = 1; effects = 'high'; particleCpu = 1; ragdolls = 4; ragdollCol = 1; gibs = 0; decals = 1; spot = 'off'; sun = 'low'; volumetric = 0; ssao = 2; aa = 12 } }
    GameLow = @{ Name = 'Game Low'; Desc = 'Exactly what the in-game menu writes at its lowest setting, saved from the game on 17 Oct 2026. Useful as a reference.'
        V = @{ stream = '0'; picmip = 2; filter = 'bilinear'; lod = 0.6; mapDetail = 1; fade = 1; effects = 'low'; particleCpu = 0; ragdolls = 0; ragdollCol = 1; gibs = 0; decals = 0; spot = 'off'; sun = 'low'; volumetric = 0; ssao = 0; aa = 0 } }
    GameHigh = @{ Name = 'Game High'; Desc = 'Exactly what the in-game menu writes at its highest setting, saved from the game on 17 Oct 2026.'
        V = @{ stream = '3000000'; picmip = 0; filter = 'a16'; lod = 2; mapDetail = 2; fade = 1; effects = 'high'; particleCpu = 2; ragdolls = 8; ragdollCol = 1; gibs = 1; decals = 1; spot = 'high'; sun = 'high'; volumetric = 1; ssao = 4; aa = 12 } }
    FiTH = @{ Name = 'g1gGLe''s settings'; Desc = 'The FiTH competitive config from the GitHub page: maximum texture budget and sharper textures, model detail 0.75, sun shadows and ragdoll collision off. Tested in-game on 17 Oct 2026.'
        V = @{ stream = '3000000'; picmip = 1; filter = 'a4'; lod = 0.75; mapDetail = 1; fade = 1; effects = 'low'; particleCpu = 0; ragdolls = 0; ragdollCol = 0; gibs = 0; decals = 0; spot = 'off'; sun = 'off'; volumetric = 0; ssao = 0; aa = 0 } }
}

# Picks a preset from the hardware. Returns the preset id and the reason.
function Get-AutoPreset($Hw) {
    $vram = $Hw.VramGB; $threads = [int]$Hw.Threads
    if (($vram -and $vram -lt 4) -or ($threads -and $threads -le 4)) {
        return @('Extreme', "Your PC has $(if ($vram) { "$vram GB of video memory" } else { 'unknown video memory' }) and $threads CPU threads, so Extreme squeezes out every frame.")
    }
    if ($vram -and $vram -lt 6) {
        return @('MaxFPS', "With $vram GB of video memory, Max FPS keeps the texture budget at zero so the card never runs out and stutters.")
    }
    $vtext = $(if ($vram) { "$vram GB of video memory" } else { 'your graphics card' })
    return @('Competitive', "$vtext handles sharper textures easily, so Competitive keeps players readable at range while everything else stays low.")
}

# ---------------------------------------------------------------------------------------------
#  Settings knowledge base - powers the tooltips in the change list
#  Format: Key | Group | Friendly name | Impact | What it does
# ---------------------------------------------------------------------------------------------
$SettingInfoText = @'
defaultres|Display|Resolution width|FPS|The resolution the game renders at. Kept equal to your screen so the image stays sharp.
defaultresheight|Display|Resolution height|FPS|The resolution the game renders at. Kept equal to your screen so the image stays sharp.
last_display_width|Display|Last display width|STABILITY|The last resolution the game used. Kept equal to the resolution so the game doesn't switch modes on launch.
last_display_height|Display|Last display height|STABILITY|The last resolution the game used. Kept equal to the resolution so the game doesn't switch modes on launch.
fullscreen|Display|Fullscreen|LATENCY|1 with borderless 1 is Fullscreen, 0/1 is a borderless window, 0/0 is windowed. Fullscreen gives the lowest input lag.
nowindowborder|Display|Window border|LATENCY|Part of the display mode, together with fullscreen.
mat_vsync_mode|Display|V-sync|LATENCY|Stops screen tearing but adds input lag. 0 is off: standard for competitive play.
mat_backbuffer_count|Display|Back buffer|LATENCY|2 only with triple-buffered V-sync, 1 for every other mode. Set to match V-sync automatically.
dvs_enable|Display|Adaptive resolution|BIG FPS|Lowers your resolution on the fly to hold an FPS target. Steadier frame rate on weak PCs, but the image goes soft in fights.
gamma|Display|Brightness|CLARITY|Same as the in-game brightness slider. In the file, a lower number means brighter.
sound_volume|Display|Master volume|AUDIO|Master volume is stored in this file too, so the tool keeps yours unless you move the slider.
stream_memory|Textures|Texture streaming budget|SMALL FPS|How much video memory goes to textures. Lower saves VRAM and reduces stutter on 4-6 GB cards, at the cost of blurrier surfaces. The menu writes 0 at Low and 3000000 at High.
mat_picmip|Textures|Texture quality|SMALL FPS|How much textures are scaled down. 0 is sharpest. The menu stops at 2; 3 and 4 are only possible in the file.
mat_forceaniso|Textures|Texture filtering|SMALL FPS|Keeps textures sharp at an angle, like the floor in front of you. 1 is bilinear/trilinear, up to 16x anisotropic. Cheap on modern cards.
mat_mip_linear|Textures|Trilinear filtering|SMALL FPS|Smooths the switch between texture detail levels. Part of texture filtering.
r_lod_switch_scale|Models|Model detail|FPS|How far away models keep full detail. This includes players, so higher keeps distant enemies easier to read. The menu goes from 0.6 to 2; below 0.6 is file only.
map_detail_level|Models|Map detail|FPS|Extra environment clutter. 1 is the menu's Low, 2 its High.
fadeDistScale|Models|Small object fade distance|SMALL FPS|How far away small objects keep drawing before they fade out. The menu always writes 1.0. File only, effect not yet confirmed in-game.
cl_particle_fallback_base|Effects|Effects detail|FPS|Explosions, smoke and ability effects. 3 is Low, 0 is High. Matters most in big fights.
cl_particle_fallback_multiplier|Effects|Effects detail|FPS|Second half of effects detail: 2 is Low, 1 is High.
particle_cpu_level|Effects|CPU particle detail|SMALL FPS|Particle work done on the processor. Lower helps CPU-limited PCs.
cl_ragdoll_maxcount|Effects|Ragdolls|SMALL FPS|How many knocked-down bodies run physics at once.
cl_ragdoll_self_collision|Effects|Ragdoll self-collision|SMALL FPS|Lets ragdoll limbs collide with each other. The menu leaves this on even at Low; off is file only.
cl_gib_allow|Effects|Gib effects|SMALL FPS|Extra physics debris effects.
r_decals|Effects|Impact marks|SMALL FPS|Bullet holes and scorch marks on walls. 0 turns them off, 256 is the menu's High.
r_createmodeldecals|Effects|Impact marks on models|SMALL FPS|Bullet holes and marks on models and players.
csm_enabled|Shadows|Sun shadows|BIG FPS|Live shadows cast by the sun, including from players. The menu keeps them on even at Low. Off is only possible in the file.
csm_coverage|Shadows|Sun shadow distance|FPS|How far out sun shadows are drawn. 1 is Low, 2 is High.
csm_cascade_res|Shadows|Sun shadow detail|FPS|Resolution of sun shadows. 512 is Low, 1024 is High.
shadow_enable|Shadows|Spot shadows|BIG FPS|Shadows from lamps and other light sources.
shadow_maxdynamic|Shadows|Dynamic spot shadows|FPS|How many spot shadows can move and update at once.
shadow_depth_dimen_min|Shadows|Spot shadow resolution|FPS|Sharpness of spot shadows.
shadow_depth_upres_factor_max|Shadows|Spot shadow upscaling|FPS|How much spot shadows are upscaled.
volumetric_lighting|Shadows|Volumetric lighting|FPS|Visible light shafts through dust and windows. Looks great, costs frames, and can wash out targets.
volumetric_fog|Shadows|Volumetric fog|FPS|Volumetric fog. File only; the menu writes 0.
ssao_quality|Shadows|Ambient occlusion|FPS|Soft shading in corners and creases. 0 turns it off, 4 is max.
mat_antialias_mode|Shadows|Anti-aliasing|SMALL FPS|Smooths jagged edges. 12 is TSAA, the game's only option; it softens the image slightly. 0 is off.
dynamic_streaming_budget|Textures|Dynamic texture budget|STABILITY|Lets the game size the texture budget automatically. File only; the game writes 1.
new_shadow_settings|Shadows|Shadow settings flag|STABILITY|Internal flag. Leave at 1.
'@

$SettingInfo = @{}
foreach ($line in ($SettingInfoText -split "`r?`n")) {
    $p = $line -split '\|'
    if ($p.Count -ge 5) { $SettingInfo[$p[0].Trim()] = [pscustomobject]@{ Group = $p[1]; Title = $p[2]; Impact = $p[3]; Info = $p[4] } }
}

function Get-SettingInfo([string]$Key) {
    if ($SettingInfo.ContainsKey($Key)) { return $SettingInfo[$Key] }
    return [pscustomobject]@{ Group = 'Other'; Title = $Key; Impact = ''; Info = 'Game setting.' }
}

# ---------------------------------------------------------------------------------------------
#  Rules: hardware + preferences -> the values to set
# ---------------------------------------------------------------------------------------------
function New-DefaultPrefs {
    [ordered]@{
        Preset     = 'Auto'          # Auto | one of $PresetOrder
        Display    = 'full'          # full | borderless | windowed | keep
        Cap        = 'minus3'        # minus3 | refresh | unlimited | custom | keep
        CapValue   = 0
        SteamCap   = $true           # write the FPS cap into Steam's launch options
        Brightness = $null           # 0-100, $null = keep the file's value
        Volume     = $null           # 0-100, $null = keep the file's value
        ReadOnly   = $false
    }
}

function Get-FpsCap($Hw, $Prefs) {
    $hz = $Hw.RefreshHz
    switch ($Prefs.Cap) {
        'refresh'   { if ($hz) { return [int]$hz } else { return $null } }
        'minus3'    { if ($hz) { return [int][math]::Max(30, $hz - 3) } else { return $null } }
        'unlimited' { return 0 }
        'custom'    { $v = [int]$Prefs.CapValue; if ($v -lt 30) { $v = 30 } elseif ($v -gt 400) { $v = 400 }; return $v }
        default     { return $null }
    }
}

function Get-Plan($Hw, $Prefs, $File) {
    $c = [ordered]@{}
    $why = @{}
    $notes = New-Object System.Collections.Generic.List[string]

    $presetId = $Prefs.Preset
    $autoWhy = $null
    if ($presetId -eq 'Auto' -or -not $Presets.ContainsKey($presetId)) {
        $pick = Get-AutoPreset $Hw; $presetId = $pick[0]; $autoWhy = $pick[1]
    }
    $pr = $Presets[$presetId]; $s = $pr.V
    $presetWhy = $(if ($autoWhy) { "Auto picked $($pr.Name): $autoWhy" } else { "$($pr.Name) preset: $($pr.Desc)" })

    # --- Preset values -> file keys (same mapping as the online Config Builder)
    $aniso = @{ bilinear = @(1, 0); trilinear = @(1, 1); a2 = @(2, 1); a4 = @(4, 1); a8 = @(8, 1); a16 = @(16, 1) }[$s.filter]
    $spot  = @{ off = @(0, 0, 0, 0); med = @(1, 256, 3, 4); high = @(1, 512, 3, 4) }[$s.spot]
    $sun   = @{ off = @(0, 1, 512); low = @(1, 1, 512); high = @(1, 2, 1024) }[$s.sun]
    $eff   = $(if ($s.effects -eq 'high') { @(0, 1) } else { @(3, 2) })
    $pairs = [ordered]@{
        'cl_gib_allow' = $s.gibs; 'cl_particle_fallback_base' = $eff[0]; 'cl_particle_fallback_multiplier' = $eff[1]
        'cl_ragdoll_maxcount' = $s.ragdolls; 'cl_ragdoll_self_collision' = $s.ragdollCol
        'mat_forceaniso' = $aniso[0]; 'mat_mip_linear' = $aniso[1]; 'stream_memory' = $s.stream; 'mat_picmip' = $s.picmip
        'particle_cpu_level' = $s.particleCpu; 'r_createmodeldecals' = $s.decals; 'r_decals' = $(if ($s.decals) { 256 } else { 0 })
        'r_lod_switch_scale' = (F6 $s.lod)
        'shadow_enable' = $spot[0]; 'shadow_depth_dimen_min' = $spot[1]; 'shadow_depth_upres_factor_max' = $spot[2]; 'shadow_maxdynamic' = $spot[3]
        'dvs_enable' = 0
        'volumetric_lighting' = $s.volumetric; 'volumetric_fog' = 0
        'mat_vsync_mode' = 0; 'mat_backbuffer_count' = 1; 'mat_antialias_mode' = $s.aa
        'csm_enabled' = $sun[0]; 'csm_coverage' = $sun[1]; 'csm_cascade_res' = $sun[2]
        'fadeDistScale' = (F6 $s.fade); 'new_shadow_settings' = 1; 'dynamic_streaming_budget' = 1
        'map_detail_level' = $s.mapDetail; 'ssao_quality' = $s.ssao
    }
    foreach ($k in $pairs.Keys) { $c[$k] = [string]$pairs[$k]; $why[$k] = $presetWhy }
    if ($sun[0] -eq 0) {
        $why['csm_enabled'] = "Sun shadows off: only possible in the file, never in the menu. You gain frames and the dark shapes enemies stand in disappear. Tested in-game on 17 Oct 2026."
    }
    $why['mat_vsync_mode'] = 'V-sync off in every preset: it adds input lag. Use G-Sync/FreeSync with the FPS cap instead.'
    $why['dvs_enable'] = 'Adaptive resolution off in every preset, so the image never goes soft mid-fight.'

    # --- Display mode
    if ($Prefs.Display -ne 'keep') {
        $disp = @{ full = @(1, 1); borderless = @(0, 1); windowed = @(0, 0) }[$Prefs.Display]
        $c['fullscreen'] = [string]$disp[0]; $c['nowindowborder'] = [string]$disp[1]
        $dw = @{ full = 'Fullscreen gives the lowest input lag.'; borderless = 'Borderless window: easier alt-tabbing, a little more input lag.'; windowed = 'Windowed mode, as you chose.' }[$Prefs.Display]
        $why['fullscreen'] = $dw; $why['nowindowborder'] = $dw
    }

    # --- Resolution
    if ($Hw.Width -and $Hw.Height) {
        $c['defaultres'] = [string]$Hw.Width; $c['defaultresheight'] = [string]$Hw.Height
        $c['last_display_width'] = [string]$Hw.Width; $c['last_display_height'] = [string]$Hw.Height
        $rw = "Set to $($Hw.Width)x$($Hw.Height), from YOUR RIG. Use your monitor's native resolution for the sharpest image."
        foreach ($k in 'defaultres', 'defaultresheight', 'last_display_width', 'last_display_height') { $why[$k] = $rw }
    } else {
        $notes.Add('Resolution not detected - left as it is. Type it in on the left to set it.')
    }

    # --- Brightness / volume: kept unless the slider was moved
    if ($null -ne $Prefs.Brightness) {
        $c['gamma'] = F6 (1.75 - ([double]$Prefs.Brightness / 100) * 1.5)
        $why['gamma'] = "Brightness $($Prefs.Brightness)%, as you set it. 50% matches the game's default."
    }
    if ($null -ne $Prefs.Volume) {
        $c['sound_volume'] = FTrim ([double]$Prefs.Volume / 100)
        $why['sound_volume'] = "Master volume $($Prefs.Volume)%, as you set it."
    }

    # --- FPS cap (launch option)
    $cap = Get-FpsCap $Hw $Prefs
    $capWhy = $null
    if ($Prefs.Cap -ne 'keep') {
        if ($null -eq $cap) { $notes.Add('Refresh rate not detected - the FPS cap was left alone. Enter it on the left.') }
        elseif ($cap -eq 0) { $capWhy = 'Unlimited FPS (+fps_max 0): the most frames, but less even frame times than a cap.' }
        elseif ($Prefs.Cap -eq 'minus3') { $capWhy = "Your monitor runs at $($Hw.RefreshHz) Hz. Capping at $cap keeps G-Sync/FreeSync active and frame times even." }
        elseif ($Prefs.Cap -eq 'refresh') { $capWhy = "Capped at your $($Hw.RefreshHz) Hz refresh rate." }
        else { $capWhy = "Capped at $cap FPS, as you set it." }
    }

    if ($File.Values.Contains('configversion') -and $File.Values['configversion'] -ne $ConfigVersion) {
        $notes.Add("Your file is format version $($File.Values['configversion']); this tool was built for version $ConfigVersion. Only settings found in your file are changed.")
    }
    $notes.Add('Don''t save anything in the in-game Video menu afterwards: it rewrites the file with menu values. Run this tool again if you do.')
    [pscustomobject]@{ Changes = $c; Why = $why; Notes = $notes; PresetId = $presetId; PresetName = $pr.Name; AutoWhy = $autoWhy; Cap = $cap; CapWhy = $capWhy }
}

function Get-PreviewRows($File, $Plan, $Prefs, $Steam) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($k in $Plan.Changes.Keys) {
        $info = Get-SettingInfo $k
        $new = $Plan.Changes[$k]
        if (-not $File.Values.Contains($k)) {
            $rows.Add([pscustomobject]@{ File = $info.Group; Setting = $info.Title; Key = "setting.$k"; Info = $info.Info; Impact = $info.Impact
                Why = $Plan.Why[$k]; Current = '(missing)'; New = $new; Path = $File.Path; Status = 'skipped' })
            continue
        }
        $cur = $File.Values[$k]
        if (Test-SameValue $cur $new) { continue }
        $rows.Add([pscustomobject]@{ File = $info.Group; Setting = $info.Title; Key = "setting.$k"; Info = $info.Info; Impact = $info.Impact
            Why = $Plan.Why[$k]; Current = $cur; New = $new; Path = $File.Path; Status = 'change' })
    }
    # Steam launch options
    if ($Prefs.SteamCap -and $Prefs.Cap -ne 'keep' -and $null -ne $Plan.Cap) {
        foreach ($sc in $Steam) {
            $newLo = Get-NewLaunchOptions $sc.Current $Plan.Cap
            if ($newLo -ceq $sc.Current) { continue }
            $rows.Add([pscustomobject]@{ File = 'Steam'; Setting = 'Launch options'; Key = "LaunchOptions (Steam account $($sc.Account))"
                Info = 'Apex''s launch options in Steam. Only the +fps_max part is changed; anything else you have there stays.'
                Impact = 'STABILITY'; Why = $Plan.CapWhy
                Current = $(if ($sc.Current) { $sc.Current } else { '(empty)' }); New = $newLo; Path = $sc.Path; Status = 'change' })
        }
    }
    return ,$rows
}

# ---------------------------------------------------------------------------------------------
#  Backup / apply / restore
# ---------------------------------------------------------------------------------------------
function Test-GameRunning { return [bool](Get-Process -Name $GameProcesses -ErrorAction SilentlyContinue) }

function New-Backup([string[]]$Paths) {
    $dir = Join-Path $BackupRoot (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    $map = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($p in $Paths) {
        $i++
        $name = $(if ($p -eq $ConfigPath) { 'videoconfig.txt' } else { "steam-$i-localconfig.vdf" })
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $p -Destination (Join-Path $dir $name) -Force
        $map.Add("$name|$p")
    }
    [IO.File]::WriteAllLines((Join-Path $dir 'files.txt'), $map)
    return $dir
}

function Get-Backups {
    if (Test-Path -LiteralPath $BackupRoot) { @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending) } else { @() }
}

function Restore-Backup([string]$Dir) {
    if (Test-GameRunning) { throw 'Apex Legends is running. Close the game first.' }
    $list = Join-Path $Dir 'files.txt'
    if (-not (Test-Path -LiteralPath $list)) { throw 'This backup has no file list.' }
    $entries = @(Get-Content -LiteralPath $list | Where-Object { $_ -match '\|' })
    if (($entries | Where-Object { $_ -like 'steam-*' }) -and (Test-SteamRunning)) { throw 'Steam is running. Close Steam first, so it can''t overwrite the restored launch options.' }
    foreach ($e in $entries) {
        $name, $dest = $e -split '\|', 2
        $src = Join-Path $Dir $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).IsReadOnly = $false }
        Copy-Item -LiteralPath $src -Destination $dest -Force
    }
}

function Invoke-Apply($File, $Rows, [bool]$ReadOnly) {
    if (Test-GameRunning) { throw 'Apex Legends is running. Close the game first, then apply.' }
    $todo = @($Rows | Where-Object { $_.Status -eq 'change' })
    $steamRows = @($todo | Where-Object { $_.File -eq 'Steam' })
    if ($steamRows.Count -and (Test-SteamRunning)) { throw 'Steam is running. Close Steam first, or untick the Steam launch options box.' }
    $paths = @($File.Path) + @($steamRows | ForEach-Object { $_.Path } | Select-Object -Unique)
    $backup = New-Backup $paths

    try {
        $ch = [ordered]@{}
        foreach ($r in $todo) { if ($r.Path -eq $File.Path) { $ch[$r.Key -replace '^setting\.', ''] = $r.New } }
        $item = Get-Item -LiteralPath $File.Path
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        if ($ch.Count -gt 0) {
            Write-ApexFile $File $ch
            # Verify: read it back and check every value landed
            $check = Read-ApexFile $File.Path
            foreach ($k in $ch.Keys) { if (-not (Test-SameValue $check.Values[$k] $ch[$k])) { throw "videoconfig.txt didn't save correctly ($k)." } }
        }
        foreach ($r in $steamRows) { Set-VdfLaunchOptions $r.Path $r.New }
        if ($ReadOnly) { (Get-Item -LiteralPath $File.Path).IsReadOnly = $true }
    } catch {
        $err = $_.Exception.Message
        try { Restore-Backup $backup } catch { }
        throw "Nothing was changed - your files were put back from the backup. ($err)"
    }
    return $backup
}

# ---------------------------------------------------------------------------------------------
#  Silent mode
# ---------------------------------------------------------------------------------------------
$NoGameMsg = "Couldn't find videoconfig.txt in:`n$ConfigDir`n`nLaunch Apex Legends once, wait for the main menu, close it, then run this tool again."
$File = $null
if (Test-Path -LiteralPath $ConfigPath) { $File = Read-ApexFile $ConfigPath }

if ($Silent) {
    if (-not $File) { Write-Host $NoGameMsg -ForegroundColor Yellow; exit 1 }
    $hw    = Get-HardwareInfo $File
    $prefs = New-DefaultPrefs
    $prefs.Preset = $Preset
    $steam = Get-SteamConfigs
    $plan  = Get-Plan $hw $prefs $File
    $rows  = Get-PreviewRows $File $plan $prefs $steam
    Write-Host "$ToolName $ToolVersion" -ForegroundColor Cyan
    Write-Host ("CPU: {0} ({1} threads)  GPU: {2} [{3} GB]  Display: {4}x{5} @ {6} Hz" -f `
        $hw.CpuName, $hw.Threads, $hw.GpuName, $hw.VramGB, $hw.Width, $hw.Height, $hw.RefreshHz)
    Write-Host "Preset: $($plan.PresetName)$(if ($plan.AutoWhy) { " (auto) - $($plan.AutoWhy)" })"
    $rows | Format-Table File, Setting, Key, Current, New, Status -AutoSize | Out-String -Width 220 | Write-Host
    $n = @($rows | Where-Object { $_.Status -eq 'change' }).Count
    if ($DryRun) { Write-Host "Dry run: $n settings would change. Nothing written."; exit 0 }
    if ((@($rows | Where-Object { $_.File -eq 'Steam' }).Count) -and (Test-SteamRunning)) {
        Write-Host 'Steam is running, so the launch options were skipped. Close Steam and run again to set them.' -ForegroundColor Yellow
        $rows = @($rows | Where-Object { $_.File -ne 'Steam' })
        $n = @($rows | Where-Object { $_.Status -eq 'change' }).Count
    }
    $b = Invoke-Apply $File $rows $prefs.ReadOnly
    Write-Host "Applied $n changes. Backup: $b" -ForegroundColor Green
    $plan.Notes | ForEach-Object { Write-Host "- $_" }
    exit 0
}

# ---------------------------------------------------------------------------------------------
#  Window
# ---------------------------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not $File) {
    [Windows.MessageBox]::Show($NoGameMsg, $ToolName, 'OK', 'Warning') | Out-Null
    exit 1
}

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

function New-TipXaml([string]$Title, [string]$Impact, [string]$Body, [string]$Rec) {
    $pill = ''
    if ($Impact) {
        $pill = '<Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" VerticalAlignment="Top">' +
                '<TextBlock Text="' + (ConvertTo-XmlText $Impact) + '" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/></Border>'
    }
    $recXaml = ''
    if ($Rec) {
        $recXaml = '<Border Margin="0,10,0,0" Padding="10,7" CornerRadius="7" Background="#0E2A1F" BorderBrush="#1F5E43" BorderThickness="1">' +
                   '<TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#3DDC97"><Run FontWeight="Bold" Text="Recommended: "/><Run Text="' + (ConvertTo-XmlText $Rec) + '"/></TextBlock></Border>'
    }
    return '<StackPanel Width="320">' +
           '<DockPanel Margin="0,0,0,6">' + $pill + '<TextBlock Text="' + (ConvertTo-XmlText $Title) + '" FontWeight="Bold" FontSize="14" Foreground="White" TextWrapping="Wrap"/></DockPanel>' +
           '<TextBlock Text="' + (ConvertTo-XmlText $Body) + '" TextWrapping="Wrap" FontSize="12" Foreground="#C9CED6" LineHeight="18"/>' +
           $recXaml + '</StackPanel>'
}

$Tips = @{
    tbCpu     = New-TipXaml 'CPU' 'DETECTED' 'Your processor, as reported by Windows.' 'Nothing to change here.'
    tbThreads = New-TipXaml 'CPU threads' 'FPS' 'Auto uses this with video memory to pick a preset. 4 threads or fewer gets Extreme.' 'Leave as detected.'
    tbGpu     = New-TipXaml 'Graphics card' 'DETECTED' 'Your gaming graphics card. Built-in CPU graphics are skipped when a dedicated card is fitted.' 'If this is wrong, type your real video memory in the box below.'
    tbVram    = New-TipXaml 'Video memory' 'STABILITY' 'Auto picks the preset from this: under 4 GB gets Extreme, 4-5 GB Max FPS, 6 GB and up Competitive. Apex stutters when textures don''t fit.' 'Check Task Manager > Performance > GPU > Dedicated GPU memory.'
    tbRes     = New-TipXaml 'Resolution' 'FPS' 'Filled in from your videoconfig.txt. Written to all four resolution lines in the file.' 'Your monitor''s native resolution.'
    tbHz      = New-TipXaml 'Refresh rate' 'STABILITY' 'Sets the FPS cap. Refresh rate minus 3 keeps G-Sync/FreeSync active and frame times even.' 'Your monitor''s maximum refresh rate. Check it in Windows Settings > Display > Advanced display.'
    cbPreset  = New-TipXaml 'Preset' 'BIG FPS' 'The same presets as the online Config Builder at fithgaming.co.uk/apex. Auto picks one from your video memory and CPU.' 'Auto, or Competitive for ranked.'
    cbDisplay = New-TipXaml 'Display mode' 'LATENCY' 'Fullscreen gives the lowest input lag. Borderless is easier for alt-tabbing.' 'Fullscreen.'
    cbCap     = New-TipXaml 'FPS cap' 'STABILITY' 'Apex''s FPS cap is a launch option (+fps_max), not a file setting. Refresh minus 3 gives the smoothest frame pacing; Unlimited gives the most frames.' 'Refresh rate - 3.'
    tbCap     = New-TipXaml 'Custom FPS cap' '' 'Your own frame limit between 30 and 400. Only used when FPS cap is set to Custom.' 'A few frames under your refresh rate.'
    chkSteam  = New-TipXaml 'Write to Steam' 'STABILITY' 'Puts the FPS cap into Apex''s launch options in Steam for you. Your other launch options are kept. Steam must be closed to save it; the tool offers to close it cleanly.' 'On if you play through Steam. EA app players: copy the cap from the notes into the EA app''s launch options.'
    slBright  = New-TipXaml 'Brightness' 'CLARITY' 'The in-game brightness slider, stored in this file. Starts at your current value and is only changed if you move it.' 'Leave it where you like it.'
    slVol     = New-TipXaml 'Master volume' 'AUDIO' 'Master volume is stored in this file too. Starts at your current value and is only changed if you move it.' 'Leave it where you like it.'
    chkRO     = New-TipXaml 'Lock videoconfig.txt' 'STABILITY' 'Makes the file read-only so the game can''t rewrite it. Apex keeps a hand-edited file without this, so it''s only needed if your settings keep resetting.' 'Off. While locked, changes made in the Video menu won''t save.'
    cbBackups = New-TipXaml 'Backups' 'SAFETY' 'Every Apply saves your previous videoconfig.txt (and Steam settings, if changed) here, newest first.' 'Pick one and press Restore to roll back.'
    btnApply  = New-TipXaml 'Apply' '' 'Backs up your current files, writes the changes, then reads them back to check. If anything fails, your files are put back automatically.' 'Close Apex first. Don''t save in the Video menu afterwards.'
}

$RowTip = @'
<StackPanel Width="340">
  <DockPanel Margin="0,0,0,6">
    <Border DockPanel.Dock="Right" CornerRadius="9" Padding="8,2" Margin="12,0,0,0" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" VerticalAlignment="Top">
      <TextBlock Text="{Binding Impact}" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/>
    </Border>
    <TextBlock Text="{Binding Setting}" FontWeight="Bold" FontSize="14" Foreground="White" TextWrapping="Wrap"/>
  </DockPanel>
  <TextBlock Text="{Binding Info}" TextWrapping="Wrap" FontSize="12" Foreground="#C9CED6" LineHeight="18"/>
  <Border Margin="0,10,0,0" Padding="10,7" CornerRadius="7" Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1">
    <TextBlock TextWrapping="Wrap" FontSize="12">
      <Run Text="{Binding Current, Mode=OneWay}" Foreground="#8C94A3"/><Run Text="   &#x2192;   " Foreground="#5D6573"/><Run Text="{Binding New, Mode=OneWay}" Foreground="#FF7B45" FontWeight="Bold"/>
    </TextBlock>
  </Border>
  <Border Margin="0,6,0,0" Padding="10,7" CornerRadius="7" Background="#0E2A1F" BorderBrush="#1F5E43" BorderThickness="1">
    <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#3DDC97"><Run FontWeight="Bold" Text="Why: "/><Run Text="{Binding Why, Mode=OneWay}"/></TextBlock>
  </Border>
  <TextBlock Text="{Binding Key}" Foreground="#5D6573" FontSize="10" Margin="0,8,0,0"/>
</StackPanel>
'@

$PresetItemsXaml = '<ComboBoxItem Tag="Auto">Auto (picked for your rig)</ComboBoxItem>' +
    (($PresetOrder | ForEach-Object { '<ComboBoxItem Tag="' + $_ + '">' + (ConvertTo-XmlText $Presets[$_].Name) + '</ComboBoxItem>' }) -join '')

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$ToolName" Width="1320" Height="860" MinWidth="1200" MinHeight="700"
        WindowStartupLocation="CenterScreen" Background="#0B0D11" FontFamily="Segoe UI" FontSize="13"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#0B0D11"/>
    <SolidColorBrush x:Key="Card"    Color="#13161C"/>
    <SolidColorBrush x:Key="Field"   Color="#1A1E26"/>
    <SolidColorBrush x:Key="Line"    Color="#272D38"/>
    <SolidColorBrush x:Key="Ink"     Color="#ECEEF1"/>
    <SolidColorBrush x:Key="Muted"   Color="#8C94A3"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF5A1F"/>
    <SolidColorBrush x:Key="AccentHi" Color="#FF7B45"/>
    <SolidColorBrush x:Key="Good"    Color="#3DDC97"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Ink}"/></Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,10,0,4"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/><Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="CardBox" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Card}"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/><Setter Property="Margin" Value="8"/>
    </Style>

    <!-- Text boxes -->
    <Style TargetType="TextBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="Bd" Background="{StaticResource Field}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="7" Padding="9,6">
            <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4250"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsReadOnly" Value="True"><Setter TargetName="Bd" Property="Background" Value="#151920"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Combo boxes -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="Transparent" Padding="10,7" CornerRadius="5" Margin="3,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#262C37"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Bd" Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="7">
                    <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"
                          Data="M0,0 L5,5 L10,0" Stroke="#8C94A3" StrokeThickness="1.6"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
                    <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible="False" Margin="10,7,30,7" VerticalAlignment="Center"
                              Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
              <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="8" Margin="0,4,0,0" Padding="0,3"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="320">
                <ScrollViewer><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Check boxes and radio buttons -->
    <Style TargetType="CheckBox">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Margin" Value="0,5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" Background="#1A1E26" BorderBrush="#3A4250" BorderThickness="1.5" VerticalAlignment="Center">
              <Path x:Name="Tick" Data="M3,9 L7,13 L15,4" Stroke="White" StrokeThickness="2.2" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="#FF5A1F"/><Setter TargetName="Box" Property="BorderBrush" Value="#FF5A1F"/>
              <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#FF7B45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Margin" Value="0,4,18,4"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Grid Width="18" Height="18" VerticalAlignment="Center">
              <Ellipse x:Name="Ring" Stroke="#3A4250" StrokeThickness="1.5" Fill="#1A1E26"/>
              <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF5A1F" Visibility="Collapsed"/>
            </Grid>
            <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Ring" Property="Stroke" Value="#FF5A1F"/><Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Stroke" Value="#FF7B45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Sliders -->
    <Style x:Key="SliderRail" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/><Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Grid Background="Transparent"><Border Background="{TemplateBinding Background}" Height="4" CornerRadius="2"/></Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="Slider">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Height" Value="24"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Track x:Name="PART_Track">
            <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SliderRail}" Background="#FF5A1F" Command="{x:Static Slider.DecreaseLarge}"/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SliderRail}" Background="#272D38" Command="{x:Static Slider.IncreaseLarge}"/></Track.IncreaseRepeatButton>
            <Track.Thumb>
              <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                <Ellipse Width="16" Height="16" Fill="White" Stroke="#FF5A1F" StrokeThickness="3"/>
              </ControlTemplate></Thumb.Template></Thumb>
            </Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Buttons -->
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/><Setter Property="Background" Value="#1A1E26"/>
      <Setter Property="BorderBrush" Value="#272D38"/><Setter Property="Padding" Value="16,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#FF5A1F"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.8"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#FF5A1F"/><Setter Property="BorderBrush" Value="#FF5A1F"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="34,10"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF7B45"/></Trigger></Style.Triggers>
    </Style>
    <Style x:Key="BtnSocial" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#1C1512"/><Setter Property="BorderBrush" Value="#3A2418"/>
      <Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="6,0,0,0"/>
    </Style>

    <Style x:Key="BtnBrand" TargetType="Button">
      <Setter Property="ToolTipService.InitialShowDelay" Value="350"/><Setter Property="ToolTipService.ShowDuration" Value="60000"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="6,0,0,0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="12,8">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="14" ShadowDepth="0" Opacity="0.45" Color="White"/></Setter.Value></Setter>
              <Setter TargetName="Bd" Property="RenderTransformOrigin" Value="0.5,0.5"/>
              <Setter TargetName="Bd" Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1.05" ScaleY="1.05"/></Setter.Value></Setter>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Change list -->
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="GridViewColumnHeader">
          <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="0,0,0,1" Padding="10,8">
            <ContentPresenter TextElement.Foreground="#8C94A3" TextElement.FontSize="12" TextElement.FontWeight="SemiBold"/>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ListViewItem">
          <Border x:Name="Bd" Background="Transparent" BorderBrush="#1C2029" BorderThickness="0,0,0,1" Padding="0,5"
                  ToolTipService.InitialShowDelay="250" ToolTipService.ShowDuration="60000" ToolTipService.Placement="Mouse">
            <Border.ToolTip><ToolTip>$RowTip</ToolTip></Border.ToolTip>
            <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1A1E26"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22180F"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <!-- Slim scroll bars -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#343B47" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#343B47" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Placement" Value="Right"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToolTip">
          <Border Margin="6,6,18,18" Background="#161A21" BorderBrush="#3A2418" BorderThickness="1" CornerRadius="12">
            <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="5" Opacity="0.6" Color="Black"/></Border.Effect>
            <Grid>
              <Border Width="4" HorizontalAlignment="Left" CornerRadius="12,0,0,12" Background="#FF5A1F"/>
              <ContentPresenter Margin="18,14,16,14" TextElement.Foreground="#ECEEF1" TextElement.FontSize="12"/>
            </Grid>
          </Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

    <!-- ================= HEADER ================= -->
    <Border Grid.Row="0" Padding="26,16,26,16" BorderBrush="#FF5A1F" BorderThickness="0,0,0,2">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#2E1407" Offset="0"/>
          <GradientStop Color="#160D09" Offset="0.45"/>
          <GradientStop Color="#0B0D11" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <DockPanel LastChildFill="True">
        <Grid DockPanel.Dock="Left" Width="96" Height="96" Margin="0,0,18,0">
          <Border x:Name="logoFallback" CornerRadius="16" BorderBrush="#FF5A1F" BorderThickness="2">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FF7B45" Offset="0"/><GradientStop Color="#B8320A" Offset="1"/></LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="FiTH" Foreground="White" FontWeight="Black" FontSize="22" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <Image x:Name="imgLogo" Stretch="Uniform" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
        </Grid>

        <!-- Game badge -->
        <Border DockPanel.Dock="Right" VerticalAlignment="Center" Background="#AA0B0D11" BorderBrush="#3A2418" BorderThickness="1" CornerRadius="16" Padding="14,10,22,10">
          <StackPanel Orientation="Horizontal">
            <Grid Width="70" Height="70" Margin="0,0,14,0">
              <Ellipse Stroke="#FF5A1F" StrokeThickness="2" Opacity="0.7" Fill="#160D09">
                <Ellipse.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="0" Opacity="0.8" Color="#FF5A1F"/></Ellipse.Effect>
              </Ellipse>
              <TextBlock x:Name="gameFallback" Text="APEX" Foreground="#FF7B45" FontWeight="Black" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Image x:Name="imgGame" Margin="3" Visibility="Collapsed" RenderOptions.BitmapScalingMode="HighQuality"/>
            </Grid>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="GAME" Foreground="#8C94A3" FontSize="10" FontWeight="Bold"/>
              <TextBlock Text="Apex Legends" Foreground="White" FontSize="17" FontWeight="Bold" Margin="0,1,0,4"/>
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="dotStatus" Width="8" Height="8" Fill="#3DDC97" VerticalAlignment="Center" Margin="0,0,7,0">
                  <Ellipse.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="0" Opacity="0.9" Color="#3DDC97"/></Ellipse.Effect>
                </Ellipse>
                <TextBlock x:Name="tbGameStatus" Text="videoconfig.txt found" Foreground="#3DDC97" FontSize="12" FontWeight="SemiBold"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
        </Border>

        <StackPanel VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="g1gGLe'z " FontSize="30" FontWeight="Black" Foreground="#FF5A1F"/>
            <TextBlock Text="APEX PERFORMANCE" FontSize="30" FontWeight="Black" Foreground="White"/>
          </StackPanel>
          <TextBlock Text="Tuned to YOUR rig  &#183;  tested in-game  &#183;  settings the menu can't reach" Foreground="#B9BFCA" FontSize="13" Margin="2,2,0,10"/>
          <StackPanel Orientation="Horizontal">
            <Border Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="2,0,8,0">
              <TextBlock Text="FiTH GAMING" Foreground="#FF7B45" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="0,0,8,0">
              <TextBlock Text="v$ToolVersion" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2" Margin="0,0,8,0">
              <TextBlock Text="CONFIGVERSION $ConfigVersion" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
            <Border Background="#1A1E26" BorderBrush="#272D38" BorderThickness="1" CornerRadius="10" Padding="10,2">
              <TextBlock Text="FIRE IN THE HOLE" Foreground="#B9BFCA" FontSize="10" FontWeight="Bold"/>
            </Border>
          </StackPanel>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ================= BODY ================= -->
    <Grid Grid.Row="1" Margin="12,10,12,4">
      <Grid.ColumnDefinitions><ColumnDefinition Width="320"/><ColumnDefinition Width="320"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- YOUR RIG -->
      <Border Grid.Column="0" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <TextBlock Style="{StaticResource CardTitle}" Text="YOUR RIG"/>
            <TextBlock Text="Auto-detected  &#183;  edit anything that's wrong" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,4,0">
            <TextBlock Style="{StaticResource Lbl}" Text="CPU"/>
            <TextBox x:Name="tbCpu" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbCpu'])</ToolTip></TextBox.ToolTip></TextBox>
            <TextBlock Style="{StaticResource Lbl}" Text="Graphics card"/>
            <TextBox x:Name="tbGpu" IsReadOnly="True" Focusable="False"><TextBox.ToolTip><ToolTip>$($Tips['tbGpu'])</ToolTip></TextBox.ToolTip></TextBox>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="Video memory (GB)"/>
                <TextBox x:Name="tbVram"><TextBox.ToolTip><ToolTip>$($Tips['tbVram'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="CPU threads"/>
                <TextBox x:Name="tbThreads"><TextBox.ToolTip><ToolTip>$($Tips['tbThreads'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="0">
                <TextBlock Style="{StaticResource Lbl}" Text="Resolution"/>
                <TextBox x:Name="tbRes"><TextBox.ToolTip><ToolTip>$($Tips['tbRes'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="2">
                <TextBlock Style="{StaticResource Lbl}" Text="Refresh rate (Hz)"/>
                <TextBox x:Name="tbHz"><TextBox.ToolTip><ToolTip>$($Tips['tbHz'])</ToolTip></TextBox.ToolTip></TextBox>
              </StackPanel>
            </Grid>
            <Border Background="#1A1E26" CornerRadius="8" Padding="12,9" Margin="0,16,0,0">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE950;" Foreground="#FF7B45" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="tbRam" Foreground="#B9BFCA" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </DockPanel>
            </Border>
            <Border Background="#1A1E26" CornerRadius="8" Padding="12,9" Margin="0,8,0,0">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE7FC;" Foreground="#FF7B45" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="tbSteam" Foreground="#B9BFCA" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </DockPanel>
            </Border>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- LOADOUT -->
      <Border Grid.Column="1" Style="{StaticResource CardBox}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <TextBlock Style="{StaticResource CardTitle}" Text="LOADOUT"/>
            <TextBlock Text="How you want the game to look and feel" Foreground="#8C94A3" FontSize="11"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="0,0,4,0">
            <TextBlock Style="{StaticResource Lbl}" Text="Preset"/>
            <ComboBox x:Name="cbPreset"><ComboBox.ToolTip><ToolTip>$($Tips['cbPreset'])</ToolTip></ComboBox.ToolTip>$PresetItemsXaml</ComboBox>
            <Border Background="#1A1E26" CornerRadius="8" Padding="11,9" Margin="0,8,0,0">
              <TextBlock x:Name="tbPresetDesc" TextWrapping="Wrap" Foreground="#B9BFCA" FontSize="12" LineHeight="17"/>
            </Border>
            <TextBlock Style="{StaticResource Lbl}" Text="Display mode"/>
            <ComboBox x:Name="cbDisplay"><ComboBox.ToolTip><ToolTip>$($Tips['cbDisplay'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="full">Fullscreen</ComboBoxItem>
              <ComboBoxItem Tag="borderless">Borderless window</ComboBoxItem>
              <ComboBoxItem Tag="windowed">Windowed</ComboBoxItem>
            </ComboBox>
            <TextBlock Style="{StaticResource Lbl}" Text="FPS cap"/>
            <ComboBox x:Name="cbCap"><ComboBox.ToolTip><ToolTip>$($Tips['cbCap'])</ToolTip></ComboBox.ToolTip>
              <ComboBoxItem Tag="minus3">Refresh rate - 3 (recommended)</ComboBoxItem>
              <ComboBoxItem Tag="refresh">Match refresh rate</ComboBoxItem>
              <ComboBoxItem Tag="unlimited">Unlimited</ComboBoxItem>
              <ComboBoxItem Tag="custom">Custom</ComboBoxItem>
              <ComboBoxItem Tag="keep">Don't change</ComboBoxItem>
            </ComboBox>
            <TextBox x:Name="tbCap" Visibility="Collapsed" Margin="0,6,0,0"><TextBox.ToolTip><ToolTip>$($Tips['tbCap'])</ToolTip></TextBox.ToolTip></TextBox>
            <CheckBox x:Name="chkSteam" Content="Write the cap to Steam launch options" Margin="0,8,0,0"><CheckBox.ToolTip><ToolTip>$($Tips['chkSteam'])</ToolTip></CheckBox.ToolTip></CheckBox>
            <DockPanel Margin="0,12,0,0">
              <TextBlock x:Name="lblBright" DockPanel.Dock="Right" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
              <TextBlock Text="Brightness" Foreground="#8C94A3" FontSize="12"/>
            </DockPanel>
            <Slider x:Name="slBright" Minimum="0" Maximum="100" TickFrequency="1" IsSnapToTickEnabled="True"><Slider.ToolTip><ToolTip>$($Tips['slBright'])</ToolTip></Slider.ToolTip></Slider>
            <DockPanel Margin="0,6,0,0">
              <TextBlock x:Name="lblVol" DockPanel.Dock="Right" Foreground="#FF7B45" FontWeight="Bold" FontSize="12"/>
              <TextBlock Text="Master volume" Foreground="#8C94A3" FontSize="12"/>
            </DockPanel>
            <Slider x:Name="slVol" Minimum="0" Maximum="100" TickFrequency="1" IsSnapToTickEnabled="True"><Slider.ToolTip><ToolTip>$($Tips['slVol'])</ToolTip></Slider.ToolTip></Slider>
            <Border Height="1" Background="#272D38" Margin="0,12,0,6"/>
            <CheckBox x:Name="chkRO" Content="Lock videoconfig.txt (read-only)"><CheckBox.ToolTip><ToolTip>$($Tips['chkRO'])</ToolTip></CheckBox.ToolTip></CheckBox>
          </StackPanel></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- CHANGES -->
      <Border Grid.Column="2" Style="{StaticResource CardBox}">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,12">
            <Border DockPanel.Dock="Right" Background="#2A1206" BorderBrush="#FF5A1F" BorderThickness="1" CornerRadius="12" Padding="12,4" VerticalAlignment="Center">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="tbCount" Text="0" Foreground="#FF7B45" FontWeight="Black" FontSize="13"/>
                <TextBlock Text=" CHANGES" Foreground="#FF7B45" FontWeight="Bold" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <StackPanel>
              <TextBlock Style="{StaticResource CardTitle}" Text="CHANGES TO APPLY"/>
              <TextBlock Text="Hover any row to see what it does and why" Foreground="#8C94A3" FontSize="11"/>
            </StackPanel>
          </DockPanel>

          <Grid Grid.Row="1">
            <ListView x:Name="lvPreview" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Foreground="#ECEEF1">
              <ListView.View><GridView>
                <GridViewColumn Header="GROUP" Width="84"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding File}" Foreground="#8C94A3" Margin="4,0,0,0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="SETTING" Width="196"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Setting}" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="NOW" Width="128"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Current}" Foreground="#8C94A3" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="NEW" Width="128"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding New}" Foreground="#FF7B45" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="STATUS" Width="76"><GridViewColumn.CellTemplate><DataTemplate>
                  <TextBlock Text="{Binding Status}" Foreground="#3DDC97" TextTrimming="CharacterEllipsis"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              </GridView></ListView.View>
            </ListView>
            <Border x:Name="emptyState" Background="#101318" BorderBrush="#272D38" BorderThickness="1" Visibility="Collapsed">
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <Grid Width="84" Height="84" HorizontalAlignment="Center">
                  <Ellipse Fill="#0E2A1F" Stroke="#3DDC97" StrokeThickness="2">
                    <Ellipse.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="#3DDC97"/></Ellipse.Effect>
                  </Ellipse>
                  <Path Data="M24,43 L37,56 L61,30" Stroke="#3DDC97" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
                <TextBlock Text="LOCKED AND LOADED" Foreground="White" FontSize="20" FontWeight="Black" HorizontalAlignment="Center" Margin="0,18,0,4"/>
                <TextBlock Text="Your config already matches this loadout. Nothing to change." Foreground="#8C94A3" FontSize="13" HorizontalAlignment="Center"/>
                <TextBlock Text="Change an option on the left to see what it would do." Foreground="#5D6573" FontSize="12" HorizontalAlignment="Center" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
          </Grid>

          <Border Grid.Row="2" Background="#1A1E26" CornerRadius="8" Padding="12,10" Margin="0,12,0,0">
            <DockPanel>
              <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE946;" Foreground="#FF7B45" VerticalAlignment="Top" Margin="0,2,10,0"/>
              <TextBlock x:Name="tbNotes" TextWrapping="Wrap" Foreground="#B9BFCA" FontSize="12" LineHeight="18"/>
            </DockPanel>
          </Border>

          <DockPanel Grid.Row="3" Margin="0,12,0,0" LastChildFill="False">
            <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE81C;" Foreground="#8C94A3" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock DockPanel.Dock="Left" Text="BACKUPS" VerticalAlignment="Center" Foreground="#8C94A3" FontSize="11" FontWeight="Bold"/>
            <ComboBox x:Name="cbBackups" DockPanel.Dock="Left" Width="190" Margin="12,0,0,0" VerticalAlignment="Center"><ComboBox.ToolTip><ToolTip>$($Tips['cbBackups'])</ToolTip></ComboBox.ToolTip></ComboBox>
            <Button x:Name="btnRestore" DockPanel.Dock="Left" Style="{StaticResource BtnBase}" Content="Restore" Margin="8,0,0,0"/>
            <Button x:Name="btnFolder" DockPanel.Dock="Right" Style="{StaticResource BtnBase}" Content="Open folder" ToolTip="Open the folder with videoconfig.txt"/>
          </DockPanel>
        </Grid>
      </Border>
    </Grid>

    <!-- ================= FOOTER ================= -->
    <Border Grid.Row="2" Background="#0E1015" BorderBrush="#272D38" BorderThickness="0,1,0,0" Padding="24,14">
      <DockPanel LastChildFill="False">
        <StackPanel DockPanel.Dock="Left" VerticalAlignment="Center">
          <TextBlock Text="JOIN THE SQUAD" Foreground="#8C94A3" FontSize="10" FontWeight="Bold" Margin="0,0,0,7"/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="lnkDiscord" Style="{StaticResource BtnBrand}" Background="#5865F2" BorderBrush="#5865F2" Margin="0,0,6,0" ToolTip="Join the FiTH Gaming Discord">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE8BD;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="DISCORD" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkYouTube" Style="{StaticResource BtnBrand}" Background="#FF0000" BorderBrush="#FF0000" Margin="0,0,6,0" ToolTip="FiTH Gaming on YouTube">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE714;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="YOUTUBE" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkFacebook" Style="{StaticResource BtnBrand}" Background="#1877F2" BorderBrush="#1877F2" Margin="0,0,6,0" ToolTip="FiTH Gaming on Facebook">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE716;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="FACEBOOK" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkSteam" Style="{StaticResource BtnBrand}" Background="#171A21" BorderBrush="#66C0F4" Margin="0,0,6,0" ToolTip="FiTH Gaming Steam group">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE7FC;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="STEAM" Foreground="White"/></StackPanel>
            </Button>
            <Button x:Name="lnkWeb" Style="{StaticResource BtnBrand}" Background="#FF5A1F" BorderBrush="#FF5A1F" Margin="0" ToolTip="Config Builder and Sensitivity Finder on fithgaming.co.uk">
              <StackPanel Orientation="Horizontal"><TextBlock FontFamily="{StaticResource Icons}" Text="&#xE774;" Foreground="White" VerticalAlignment="Center" Margin="0,0,7,0"/><TextBlock Text="WEBSITE" Foreground="White"/></StackPanel>
            </Button>
          </StackPanel>
        </StackPanel>

        <Button x:Name="btnApply" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" VerticalAlignment="Center" Padding="40,13" FontSize="15">
          <Button.ToolTip><ToolTip>$($Tips['btnApply'])</ToolTip></Button.ToolTip>
          <StackPanel Orientation="Horizontal">
            <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE945;" Foreground="White" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <TextBlock Text="APPLY" Foreground="White"/>
          </StackPanel>
        </Button>
        <StackPanel DockPanel.Dock="Right" VerticalAlignment="Center" Margin="0,0,18,0">
          <TextBlock x:Name="tbStatus" HorizontalAlignment="Right" FontWeight="SemiBold" FontSize="13"/>
          <TextBlock Text="made by g1gGLe  &#183;  FiTH Gaming" HorizontalAlignment="Right" Foreground="#5D6573" FontSize="11" Margin="0,3,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@

try {
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
    [Windows.MessageBox]::Show("The window failed to load:`n`n$($inner.Message)", $ToolName, 'OK', 'Error') | Out-Null
    exit 1
}
$ui = @{}
foreach ($n in 'tbCpu','tbGpu','tbVram','tbThreads','tbRes','tbHz','tbRam','tbSteam',
               'cbPreset','tbPresetDesc','cbDisplay','cbCap','tbCap','chkSteam','lblBright','slBright','lblVol','slVol','chkRO',
               'lvPreview','tbNotes','tbCount','cbBackups','btnRestore','btnFolder','btnApply','tbStatus',
               'imgLogo','logoFallback','imgGame','gameFallback','emptyState','tbGameStatus','dotStatus',
               'lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
    $ui[$n] = $Window.FindName($n)
}

function Get-AssetImage([string]$Name) {
    $path = Join-Path $PSScriptRoot "assets\$Name"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.UriSource = New-Object Uri($path); $bmp.EndInit()
        return $bmp
    } catch { return $null }
}
$logo = Get-AssetImage 'logo.png'
if ($logo) {
    $ui.imgLogo.Source = $logo; $ui.imgLogo.Visibility = 'Visible'; $ui.logoFallback.Visibility = 'Collapsed'
    $Window.Icon = $logo
}
$game = Get-AssetImage 'game.png'
if ($game) { $ui.imgGame.Source = $game; $ui.imgGame.Visibility = 'Visible'; $ui.gameFallback.Visibility = 'Collapsed' }

$work = [System.Windows.SystemParameters]::WorkArea
if ($Window.Height -gt $work.Height - 20) { $Window.Height = [math]::Max($Window.MinHeight, $work.Height - 20) }
if ($Window.Width  -gt $work.Width  - 20) { $Window.Width  = [math]::Max($Window.MinWidth,  $work.Width  - 20) }

$ui.lnkDiscord.Tag = $Links.Discord; $ui.lnkYouTube.Tag = $Links.YouTube; $ui.lnkFacebook.Tag = $Links.Facebook
$ui.lnkSteam.Tag   = $Links.Steam;   $ui.lnkWeb.Tag     = $Links.Website
foreach ($n in 'lnkDiscord','lnkYouTube','lnkFacebook','lnkSteam','lnkWeb') {
    $ui[$n].Add_Click({ param($s, $e) try { Start-Process ([string]$s.Tag) } catch { } })
}

function Select-ComboTag($Combo, [string]$Tag) {
    foreach ($i in $Combo.Items) { if ([string]$i.Tag -eq $Tag) { $Combo.SelectedItem = $i; return } }
    $Combo.SelectedIndex = 0
}

function Update-GameStatus {
    $ver = $(if ($script:File.Values.Contains('configversion')) { $script:File.Values['configversion'] } else { '?' })
    if ($ver -eq $ConfigVersion) {
        $ui.tbGameStatus.Text = "videoconfig found  /  version $ver"
        $ui.tbGameStatus.Foreground = [Windows.Media.Brushes]::MediumSeaGreen; $ui.dotStatus.Fill = [Windows.Media.Brushes]::MediumSeaGreen
    } else {
        $ui.tbGameStatus.Text = "videoconfig found  /  version $ver (tool: $ConfigVersion)"
        $ui.tbGameStatus.Foreground = [Windows.Media.Brushes]::Orange; $ui.dotStatus.Fill = [Windows.Media.Brushes]::Orange
    }
}

function Show-Hardware($hw) {
    $ui.tbCpu.Text     = $hw.CpuName
    $ui.tbGpu.Text     = $hw.GpuName
    $ui.tbVram.Text    = [string]$hw.VramGB
    $ui.tbThreads.Text = [string]$hw.Threads
    $ui.tbRes.Text     = $(if ($hw.Width) { "$($hw.Width)x$($hw.Height)" } else { '' })
    $ui.tbHz.Text      = [string]$hw.RefreshHz
    $ram = $(if ($hw.RamGB) { "System memory: $($hw.RamGB) GB" } else { 'System memory: not detected' })
    $ui.tbRam.Text     = "$ram  /  $($hw.Cores) cores"
}

function Update-SteamInfo {
    $n = $script:Steam.Count
    if ($n -gt 0) {
        $ui.tbSteam.Text = $(if ($n -eq 1) { 'Steam: Apex found in 1 account' } else { "Steam: Apex found in $n accounts" })
        $ui.chkSteam.IsEnabled = $true
    } else {
        $ui.tbSteam.Text = 'Steam: Apex not found (EA app? Copy the cap from the notes into its launch options)'
        $ui.chkSteam.IsChecked = $false; $ui.chkSteam.IsEnabled = $false
    }
}

function Read-Hardware {
    $hw = $script:Hw
    $hw.VramGB  = ConvertTo-PositiveInt $ui.tbVram.Text
    $t = ConvertTo-PositiveInt $ui.tbThreads.Text
    if ($t) { $hw.Threads = $t }
    $m = [regex]::Match($ui.tbRes.Text, '(\d+)\s*[xX]\s*(\d+)')
    if ($m.Success) { $hw.Width = [int]$m.Groups[1].Value; $hw.Height = [int]$m.Groups[2].Value } else { $hw.Width = $null; $hw.Height = $null }
    $hw.RefreshHz = ConvertTo-PositiveInt $ui.tbHz.Text
    return $hw
}

function Read-Prefs {
    $p = New-DefaultPrefs
    $p.Preset   = [string]$ui.cbPreset.SelectedItem.Tag
    $p.Display  = [string]$ui.cbDisplay.SelectedItem.Tag
    $p.Cap      = [string]$ui.cbCap.SelectedItem.Tag
    $capValue = ConvertTo-PositiveInt $ui.tbCap.Text
    if ($capValue) { $p.CapValue = $capValue }
    $p.SteamCap = [bool]$ui.chkSteam.IsChecked
    if ([int]$ui.slBright.Value -ne $script:BrightStart) { $p.Brightness = [int]$ui.slBright.Value }
    if ([int]$ui.slVol.Value -ne $script:VolStart)       { $p.Volume = [int]$ui.slVol.Value }
    $p.ReadOnly = [bool]$ui.chkRO.IsChecked
    return $p
}

function Set-SlidersFromFile {
    $g = ConvertTo-Num $(if ($script:File.Values.Contains('gamma')) { $script:File.Values['gamma'] } else { '1' })
    if ($null -eq $g) { $g = 1 }
    $script:BrightStart = [int][math]::Round([math]::Min(100, [math]::Max(0, (1.75 - $g) / 1.5 * 100)))
    $vol = ConvertTo-Num $(if ($script:File.Values.Contains('sound_volume')) { $script:File.Values['sound_volume'] } else { '1' })
    if ($null -eq $vol) { $vol = 1 }
    $script:VolStart = [int][math]::Round([math]::Min(100, [math]::Max(0, $vol * 100)))
    $ui.slBright.Value = $script:BrightStart; $ui.slVol.Value = $script:VolStart
}

function Update-Backups {
    $ui.cbBackups.Items.Clear()
    foreach ($b in (Get-Backups)) { [void]$ui.cbBackups.Items.Add($b.Name) }
    if ($ui.cbBackups.Items.Count) { $ui.cbBackups.SelectedIndex = 0 }
    $ui.btnRestore.IsEnabled = ($ui.cbBackups.Items.Count -gt 0)
}

function Update-Preview {
    if (-not $script:Ready) { return }
    try {
        $ui.lblBright.Text = "$([int]$ui.slBright.Value)%"
        $ui.lblVol.Text    = "$([int]$ui.slVol.Value)%"
        if ([string]$ui.cbCap.SelectedItem.Tag -eq 'custom') { $ui.tbCap.Visibility = [System.Windows.Visibility]::Visible }
        else { $ui.tbCap.Visibility = [System.Windows.Visibility]::Collapsed }
        $prefs = Read-Prefs
        $plan = Get-Plan (Read-Hardware) $prefs $script:File
        $ui.tbPresetDesc.Text = $(if ($plan.AutoWhy) { "Auto picked $($plan.PresetName). $($plan.AutoWhy)`n`n$($Presets[$plan.PresetId].Desc)" } else { $Presets[$plan.PresetId].Desc })
        $script:Rows = Get-PreviewRows $script:File $plan $prefs $script:Steam
        $notes = New-Object System.Collections.Generic.List[string]
        foreach ($x in $plan.Notes) { $notes.Add($x) }
        if ($null -ne $plan.Cap -and $prefs.Cap -ne 'keep' -and -not $prefs.SteamCap) {
            $notes.Insert(0, "FPS cap: add +fps_max $($plan.Cap) to Apex's launch options (Steam or EA app).")
        }
        # A DataTable binds cleanly in Windows PowerShell 5.1 (a PowerShell array here throws "Argument types do not match").
        $dt = New-Object System.Data.DataTable
        $cols = 'File', 'Setting', 'Key', 'Current', 'New', 'Status', 'Info', 'Impact', 'Why'
        foreach ($col in $cols) { [void]$dt.Columns.Add($col, [string]) }
        foreach ($r in $script:Rows) {
            $dr = $dt.NewRow()
            foreach ($col in $cols) { $dr[$col] = [string]$r.$col }
            $dt.Rows.Add($dr)
        }
        $ui.lvPreview.ItemsSource = $dt.DefaultView
        $ui.tbNotes.Text = ($notes | ForEach-Object { "- $_" }) -join "`n"
        $n = @($script:Rows | Where-Object { $_.Status -eq 'change' }).Count
        $lockNow = (Get-Item -LiteralPath $script:File.Path).IsReadOnly
        $extra = $(if ([bool]$ui.chkRO.IsChecked -ne $lockNow) { ' + file lock' } else { '' })
        $ui.tbCount.Text = "$n"
        $rowCount = $dt.Rows.Count
        if ($rowCount -eq 0) { $ui.emptyState.Visibility = [System.Windows.Visibility]::Visible }
        else { $ui.emptyState.Visibility = [System.Windows.Visibility]::Collapsed }
        $ui.tbStatus.Foreground = [Windows.Media.Brushes]::White
        $ui.tbStatus.Text = $(if ($n -eq 0 -and -not $extra) { 'Already tuned - nothing to change.' } else { "$n settings will change$extra." })
    } catch { $ui.tbStatus.Foreground = [Windows.Media.Brushes]::OrangeRed; $ui.tbStatus.Text = "Error (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" }
}

function Update-Lock {
    # Lock/unlock even when no setting changes
    try {
        $item = Get-Item -LiteralPath $script:File.Path
        $want = [bool]$ui.chkRO.IsChecked
        if ($item.IsReadOnly -ne $want) { $item.IsReadOnly = $want }
    } catch { }
}

# Initial state
$script:Ready = $false
$script:Hw = Get-HardwareInfo $File
$script:File = $File
$script:Steam = Get-SteamConfigs
$script:Rows = @()
Show-Hardware $script:Hw
Update-GameStatus
$ui.cbPreset.SelectedIndex = 0
$curDisp = 'full'
if ($File.Values.Contains('fullscreen') -and $File.Values['fullscreen'] -eq '0') {
    $curDisp = $(if ($File.Values.Contains('nowindowborder') -and $File.Values['nowindowborder'] -eq '1') { 'borderless' } else { 'windowed' })
}
Select-ComboTag $ui.cbDisplay $curDisp
$ui.cbCap.SelectedIndex = 0
$ui.chkSteam.IsChecked = $true
Update-SteamInfo
Set-SlidersFromFile
$ui.chkRO.IsChecked = (Get-Item -LiteralPath $File.Path).IsReadOnly
Update-Backups

foreach ($n in 'tbVram','tbThreads','tbRes','tbHz','tbCap') { $ui[$n].Add_LostFocus({ Update-Preview }) }
foreach ($n in 'cbPreset','cbDisplay','cbCap') { $ui[$n].Add_SelectionChanged({ Update-Preview }) }
foreach ($n in 'chkSteam','chkRO') { $ui[$n].Add_Click({ Update-Preview }) }
foreach ($n in 'slBright','slVol') { $ui[$n].Add_ValueChanged({ Update-Preview }) }

$ui.btnApply.Add_Click({
    try {
        Update-Preview
        $prefs = Read-Prefs
        $rows = @($script:Rows)
        $steamSkipped = $false
        if (@($rows | Where-Object { $_.File -eq 'Steam' -and $_.Status -eq 'change' }).Count -and (Test-SteamRunning)) {
            $ask = [Windows.MessageBox]::Show("Steam is running, and it overwrites launch options when it closes.`n`nClose Steam now so the FPS cap can be saved? (You can open it again straight after.)`n`nNo = apply everything else and skip the launch options.", $ToolName, 'YesNoCancel', 'Question')
            if ($ask -eq 'Cancel') { return }
            if ($ask -eq 'Yes') {
                $ui.tbStatus.Text = 'Closing Steam...'
                if (-not (Stop-SteamCleanly)) { $steamSkipped = $true }
            } else { $steamSkipped = $true }
            if ($steamSkipped) { $rows = @($rows | Where-Object { $_.File -ne 'Steam' }) }
        }
        $b = Invoke-Apply $script:File $rows $prefs.ReadOnly
        Update-Lock
        $script:File = Read-ApexFile $ConfigPath
        $script:Steam = Get-SteamConfigs
        Set-SlidersFromFile
        Update-Backups
        Update-Preview
        $msg = "Done. Your previous settings were backed up ($(Split-Path $b -Leaf)).`n`nLaunch Apex and play. Don't save anything in the Video menu, or it rewrites the file."
        if ($steamSkipped) {
            $plan = Get-Plan (Read-Hardware) $prefs $script:File
            if ($null -ne $plan.Cap) {
                try { Set-Clipboard -Value "+fps_max $($plan.Cap)" } catch { }
                $msg += "`n`nSteam launch options were skipped. '+fps_max $($plan.Cap)' is on your clipboard: paste it into Apex > Properties > Launch options, or run the tool again with Steam closed."
            }
        }
        [Windows.MessageBox]::Show($msg, $ToolName, 'OK', 'Information') | Out-Null
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
    }
})

$ui.btnRestore.Add_Click({
    $name = [string]$ui.cbBackups.SelectedItem
    if (-not $name) { return }
    $ok = [Windows.MessageBox]::Show("Put back the settings from $name ?", $ToolName, 'YesNo', 'Question')
    if ($ok -ne 'Yes') { return }
    try {
        Restore-Backup (Join-Path $BackupRoot $name)
        $script:File = Read-ApexFile $ConfigPath
        $script:Steam = Get-SteamConfigs
        $ui.chkRO.IsChecked = (Get-Item -LiteralPath $ConfigPath).IsReadOnly
        Set-SlidersFromFile
        Update-Preview
        [Windows.MessageBox]::Show("Restored settings from $name.", $ToolName, 'OK', 'Information') | Out-Null
    } catch {
        [Windows.MessageBox]::Show($_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
    }
})

$ui.btnFolder.Add_Click({ Start-Process explorer.exe $ConfigDir })

$script:Ready = $true
Update-Preview
[void]$Window.ShowDialog()
