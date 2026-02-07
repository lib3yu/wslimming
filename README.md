# WSLimming

A PowerShell automation tool that compacts WSL2 `ext4.vhdx` virtual hard disk files to recover unused disk space.

The tool follows the Unix philosophy of doing one thing well - it's a single-purpose tool with minimal dependencies.

## The Problem

WSL2 stores Linux distribution data in virtual hard disk files (`ext4.vhdx`). These files automatically grow as you add data, but **they never shrink when you delete files** or uninstall applications.

This leads to wasted disk space - even after cleaning up your WSL environment, the VHDX file retains its maximum size.

## Quick Start

**Requirements**: Administrator privileges, PowerShell, WSL2

### Option 1: Run directly (no clone required)

Open PowerShell as **Administrator**:

```powershell
irm https://raw.githubusercontent.com/lib3yu/wslimming/refs/heads/main/wslimming.ps1 -OutFile wslimming.ps1; .\wslimming.ps1
```

### Option 2: Clone and run

```powershell
git clone https://github.com/lib3yu/wslimming.git
cd wslimming
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wslimming.ps1
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  1. Enumerate WSL distros from Windows Registry                 │
│  2. Prompt user to select a distro (if multiple installed)     │
│  3. Locate the ext4.vhdx file for the selected distro          │
│  4. [Optional] Analyze disk usage and package sizes            │
│  5. [Optional] Run fstrim to trim unused filesystem blocks     │
│  6. Shutdown WSL and compact the VHDX using DISKPART           │
└─────────────────────────────────────────────────────────────────┘
```

### Pre-compaction Analysis

Before compacting, you can optionally run analysis to identify what's consuming space:

| Analysis | Description | Availability |
|----------|-------------|--------------|
| **Space Analysis** | Scans filesystem for large directories | All distros |
| **Package Analysis** | Shows largest installed packages | Debian/Ubuntu only |

### Why fstrim matters

Running `fstrim` before compaction marks unused filesystem blocks as free, allowing DISKPART to recover more space. This step is optional but recommended for maximum space recovery.

## Usage Notes

- The script prompts for confirmation before each major step
- Compaction time depends on VHDX size and system performance
- The process cannot be interrupted once DISKPART compaction begins
- **Always backup your data before running** - see WARNING below

> **WARNING**: This script modifies your WSL virtual disk files. While the compaction process is safe, backup your important data before proceeding.

## Compatibility

| Platform | Status |
|----------|--------|
| Windows 10 | ✅ Supported |
| Windows 11 | ✅ Supported |
| WSL2 distributions | ✅ Supported |
| WSL1 | ❌ Not supported (different storage format) |

## License

MIT License - see [LICENSE](LICENSE) for details
