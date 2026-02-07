<#
.SYNOPSIS Compact WSL2 ext4.vhdx to recover disk space.

.DESCRIPTION wslimming.ps1
1. Enumerates installed WSL2 distros via wsl.exe.
2. If more than one, prompts you to pick one.
3. Reads the distro's BasePath and uses its virtual disk path.
3.0.1. Analyzes WSL filesystem space usage.
3.0.2. Analyzes package sizes (Debian/Ubuntu only).
3.1. Runs fstrim to trim unused blocks in the filesystem.
4. Shuts down WSL and compacts ext4.vhdx (with DISKPART).

.NOTES Must run as Administrator and ignore execution policy (see below).
.USAGE Go to the script directory and, as admin, in cmd or powershell run:

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wslimming.ps1 

#>

#------------------------------------------------------------
# Set UTF-8 encoding for proper WSL output display
#------------------------------------------------------------
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

#------------------------------------------------------------
# Helper function: Execute bash script in WSL via temp file
#------------------------------------------------------------
function Invoke-WslScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Distro,
        [Parameter(Mandatory = $true)]
        [string]$ScriptContent,
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [string]$Arguments = ""
    )

    # Convert to Unix line endings and base64 encode
    $unixContent = $ScriptContent -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($unixContent)
    $base64Content = [System.Convert]::ToBase64String($bytes)

    # Write script directly to WSL file (via base64 to avoid escaping issues)
    $wslScriptPath = "/tmp/wslimming/$ScriptName"
    wsl -d $Distro -u root -- sh -c "mkdir -p /tmp/wslimming"
    wsl -d $Distro -u root -- sh -c "echo '$base64Content' | base64 -d > $wslScriptPath"
    wsl -d $Distro -u root -- chmod +x "$wslScriptPath"
    wsl -d $Distro -u root -- bash -c "export LANG=C.UTF-8 && export LC_ALL=C.UTF-8 && '$wslScriptPath' $Arguments" 2>&1

    # Clean up WSL temporary script
    wsl -d $Distro -u root -- sh -c "rm -f $wslScriptPath"
}

#------------------------------------------------------------
# Administrator privilege check
#------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
  Write-Host ""
  Write-Host "Please:" -ForegroundColor Yellow
  Write-Host "  1. Close this window"
  Write-Host "  2. Right-click on PowerShell or Command Prompt"
  Write-Host "  3. Select 'Run as Administrator'"
  Write-Host "  4. Run the script again"
  Write-Host ""
  Write-Host "Exiting script..." -ForegroundColor Gray
  Write-Host ""
  exit 1
}

#------------------------------------------------------------
# Step 1 – Enumerate distros from the registry
#------------------------------------------------------------
$lxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'

# Grab all subkeys that have a DistributionName value
$distros = Get-ChildItem $lxssKey |
           ForEach-Object {
             $props = Get-ItemProperty $_.PSPath
             [PSCustomObject]@{
               Name     = $props.DistributionName
               BasePath = $props.BasePath
             }
           }

if ($distros.Count -eq 0) {
  Throw "No WSL distros found in the registry."
}


#------------------------------------------------------------
# Step 2 – If >1 distro, show a menu; else auto-select the only one
#------------------------------------------------------------
if ($distros.Count -gt 1) {
  Write-Host "Multiple distros detected. Please choose one to compact:`n" -ForegroundColor Cyan

  for ($i = 0; $i -lt $distros.Count; $i++) {
    $nr = $i + 1
    Write-Host "[$nr] $($distros[$i].Name)"
  }

  do {
    $choice = Read-Host "`nEnter the number (1-$($distros.Count)) of the distro to compact"
    $valid  = ($choice -as [int]) -and 
              ($choice -ge 1) -and 
              ($choice -le $distros.Count)
    if (-not $valid) {
      Write-Warning "Please enter a valid integer between 1 and $($distros.Count)."
    }
  } until ($valid)

  # zero-based index
  $selected = $distros[[int]$choice - 1]
}
else {
  # only one distro installed → pick it
  $selected = $distros[0]
}

$distro   = $selected.Name
$basePath = $selected.BasePath

# Remove \\?\ prefix if present (NT namespace prefix that breaks Join-Path)
if ($basePath.StartsWith("\\?\")) {
  $basePath = $basePath.Substring(4)
}

Write-Host "`nSelected distro: $distro" -ForegroundColor DarkYellow
Write-Host "BasePath: $basePath"

if (-not (Test-Path $basePath)) {
  Throw "BasePath '$basePath' does not exist on disk."
}


#------------------------------------------------------------
# Step 3 – Locate the ext4.vhdx
#------------------------------------------------------------
$possible = @(
  Join-Path $basePath 'ext4.vhdx'
  Join-Path $basePath 'LocalState\ext4.vhdx'
)
$vhdx = $possible | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $vhdx) {
  Throw "No ext4.vhdx found under '$basePath' or 'LocalState'."
}
# Confirmation prompt
Write-Host "`nAbout to compact this WSL distro:" -ForegroundColor Magenta
Write-Host "  Distro   : $distro"
Write-Host "  BasePath : $basePath"
Write-Host "  VHDX file: $vhdx`n"



#------------------------------------------------------------
# Step 3.0.1 – WSL Space Analysis
#------------------------------------------------------------

$spaceAnalysisScript = @'
#!/bin/bash

# --- Configuration ---
TARGET="/"
EXCLUDES=("/mnt" "/usr/lib/wsl")
THRESHOLD_MB=${1:-128}

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
NC='\033[0m'

# Cleanup: Remove temp folder on script exit
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"; exit' INT TERM EXIT

# Prepare exclude arguments
exclude_args=()
for ex in "${EXCLUDES[@]}"; do exclude_args+=("--exclude=$ex"); done

# Native formatting function
format_size() {
    local size_kb=$1
    if [ "$size_kb" -ge 1048576 ]; then
        local gb=$((size_kb / 1048576))
        local dec=$(((size_kb % 1048576) / 104857))
        printf "${RED}%4d.%1dG${NC}" "$gb" "$dec"
    elif [ "$size_kb" -ge 1024 ]; then
        local mb=$((size_kb / 1024))
        printf "%6dM" "$mb"
    else
        printf "%6dK" "$size_kb"
    fi
}

# Recursive function: Visual with depth control
scan_layer() {
    local dir=$1
    local depth=$2
    local max_depth=3
    local threshold_kb=$((THRESHOLD_MB * 1024))

    local items
    items=$(du -k --max-depth=1 "$dir" "${exclude_args[@]}" 2>/dev/null | \
            awk -v limit=$threshold_kb '$2 != "'"$dir"'" && $1 >= limit {print $1 "\t" $2}' | \
            sort -rn)

    if [[ -n "$items" ]]; then
        local count=0
        local total=$(echo "$items" | wc -l)
        while IFS=$'\t' read -r size path; do
            count=$((count + 1))
            local prefix=""
            for ((i=1; i<depth; i++)); do prefix="$prefix    "; done
            [ "$count" -eq "$total" ] && prefix="$prefix${GRAY}└── ${NC}" || prefix="$prefix${GRAY}├── ${NC}"

            echo -e "$(format_size "$size")  $prefix$path"
            if (( depth < max_depth - 1 )); then
                scan_layer "$path" $((depth + 1))
            fi
        done <<< "$items"
    fi
}

echo -e "${YELLOW}>>> Scanning WSL filesystem for large directories (threshold: >${THRESHOLD_MB}MB) <<<${NC}"

# 1. Find top-level directories
top_levels=$(du -k --max-depth=1 "$TARGET" "${exclude_args[@]}" 2>/dev/null | \
             awk -v limit=$((THRESHOLD_MB * 1024)) '$2 != "/" && $2 != "" && $1 >= limit {print $1 "\t" $2}' | \
             sort -rn)

# 2. Parallel distribution
while IFS=$'\t' read -r size path; do
    (
        # Use hash for safer filename mapping
        safe_name=$(echo "$path" | md5sum | cut -d' ' -f1)
        out_file="$tmp_dir/$safe_name"

        echo -e "$(format_size "$size")  $path" > "$out_file"
        scan_layer "$path" 1 >> "$out_file"
    ) &
done <<< "$top_levels"

wait

# 3. Merge output by weight order
echo "------------------------------------------------"
while IFS=$'\t' read -r size path; do
    safe_name=$(echo "$path" | md5sum | cut -d' ' -f1)
    if [ -f "$tmp_dir/$safe_name" ]; then
        cat "$tmp_dir/$safe_name"
    fi
done <<< "$top_levels"
echo "------------------------------------------------"
'@

#------------------------------------------------------------
# Step 3.0.2 – Package Size Analysis (Debian/Ubuntu only)
#------------------------------------------------------------

$packageScriptContent = @'
#!/bin/bash

# Colors
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
NC='\033[0m'

# Check if dpkg is available
if ! command -v dpkg &> /dev/null; then
    echo -e "${GRAY}Package analysis skipped: dpkg not found (non-Debian distribution)${NC}"
    exit 0
fi

echo -e "${YELLOW}>>> Detected Debian/Ubuntu-based distribution. Analyzing package sizes... <<<${NC}"
echo ""

# Display header
echo "Top 16 largest installed packages:"
echo "----------------------------------------"

# Execute dpkg-query and format output
dpkg-query -Wf '${Installed-Size}\t${Package}\n' | \
    sort -n | \
    awk '{printf "%.2f MB\t%s\n", $1/1024, $2}' | \
    tail -n 16

echo "----------------------------------------"
'@

Write-Host "`nDo you want to run analysis WSL space? (Y/N) " -ForegroundColor DarkCyan -NoNewline
$analysisChoice = Read-Host
if ($analysisChoice.ToUpper() -eq 'Y') {
  Write-Host "`n--- WSL Space Analysis ---" -ForegroundColor Cyan
  Invoke-WslScript -Distro $distro -ScriptContent $spaceAnalysisScript -ScriptName "where-space-lost.sh" -Arguments "255"
  Write-Host "`n--- Package Size Analysis ---" -ForegroundColor Cyan
  Invoke-WslScript -Distro $distro -ScriptContent $packageScriptContent -ScriptName "package-analysis.sh"
  Write-Host ""
}
else {
  Write-Host "Skipping analysis." -ForegroundColor Yellow
}



Write-Host "Are you sure you want to proceed? (Y/N) " -ForegroundColor DarkCyan -NoNewline
# Then read the response
$answer = Read-Host
if ($answer.ToUpper() -ne 'Y') {
  Write-Warning "Operation canceled"
  exit
}

#------------------------------------------------------------
# Step 3.1 – Trim filesystem before compaction
#------------------------------------------------------------
Write-Host "`nDo you want to run fstrim to trim unused blocks? (Y/N) " -ForegroundColor DarkCyan -NoNewline
$fstrimChoice = Read-Host
if ($fstrimChoice.ToUpper() -eq 'Y') {
  Write-Host "`nTrimming unused blocks in '$distro'..." -ForegroundColor Cyan
  $fstrimResult = wsl.exe -d $distro -u root -- sh -c "fstrim -av" 2>&1
  Write-Host $fstrimResult
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "fstrim failed (exit code $LASTEXITCODE), but continuing with compaction..."
  }
  else {
    Write-Host "Filesystem trim completed." -ForegroundColor Green
  }
}
else {
  Write-Host "Skipping fstrim." -ForegroundColor Yellow
}



#------------------------------------------------------------
# Step 4 – Shutdown WSL & Compact
#------------------------------------------------------------
Write-Host "Shutting down WSL to ensure VHDX is released..." -ForegroundColor Cyan
wsl.exe --shutdown
if ($LASTEXITCODE -ne 0) {
  Throw "Failed to shut down WSL. Are you running as Administrator?"
}
Write-Host "WSL has been shut down successfully.`n" -ForegroundColor Green

# Build and run diskpart script
$dpScript = @"
select vdisk file="$vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@

$tempFile = [IO.Path]::GetTempFileName()
Set-Content -LiteralPath $tempFile -Value $dpScript -Encoding ASCII

# Pre-compaction confirmation
Write-Host "The VHDX file is ready for compaction." -ForegroundColor Cyan
Write-Host "WARNING: This process cannot be interrupted!" -ForegroundColor Yellow
Write-Host "Do you want to proceed with the compaction? (Y/N) " -ForegroundColor DarkCyan -NoNewline
$confirmCompact = Read-Host
if ($confirmCompact.ToUpper() -ne 'Y') {
  Write-Warning "Compaction canceled."
  exit
}

Write-Host "`nRunning DiskPart to compact the VHDX. Be patient, this might take a while..." -ForegroundColor Cyan
Write-Host ""

# Prevent Ctrl+C interruption
[Console]::TreatControlCAsInput = $true

# Avoids to print too many same lines
# Keep track of the last % we printed
try {
  $lastPct = -1

  diskpart /s $tempFile | ForEach-Object {
    # Does this line look like "20 percent completed"?
    if ($_ -match '(\d+)\s+percent') {
      $pct = [int]$Matches[1]
      if ($pct -ne $lastPct) {
        Write-Host "$pct% completed"
        $lastPct = $pct
      }
    }
    else {
      # non‐percent lines we print verbatim
      if ($_ -match '\S') {
        Write-Host $_
      }
    }
  }
}
finally {
  # Restore Ctrl+C behavior
  [Console]::TreatControlCAsInput = $false
}

# Clean up
Remove-Item $tempFile -ErrorAction SilentlyContinue

Write-Host "Compaction completed`n" -ForegroundColor Green
