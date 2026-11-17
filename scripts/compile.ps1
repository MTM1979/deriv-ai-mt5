param(
  [string]$File = "MQL5\Experts\DerivAIPortfolioEA.mq5"
)

$ErrorActionPreference = "Stop"

# Repository root = parent of this script's directory, so the helper works
# from any checkout location.
$root = Split-Path -Parent $PSScriptRoot
$full = Join-Path $root $File
if(-not (Test-Path $full)){
  throw "Source file not found: $full"
}

$log = [System.IO.Path]::ChangeExtension($full, ".log")
if(Test-Path $log){ Remove-Item $log -Force }

$editor = "C:\Program Files\MetaTrader 5\MetaEditor64.exe"
if(-not (Test-Path $editor)){
  throw "MetaEditor64.exe not found at $editor. Install MetaTrader 5 or pass the editor path explicitly."
}

# Angle-bracket includes resolve against /inc, which must be the MQL5 root.
$args = @("/compile:`"$full`"", "/inc:`"$root\MQL5`"", "/log")
$p = Start-Process $editor -ArgumentList $args -PassThru -Wait

if(Test-Path $log){
  Get-Content $log -Encoding Unicode | Select-String -Pattern 'error|warning|Result:'
} else {
  "NO LOG: exit $($p.ExitCode)"
}
