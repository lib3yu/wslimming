# WSLimming - WSL2 Disk Compactor

Automatically compact WSL2 virtual disk files to reclaim disk space.

## Why?

WSL2 uses virtual hard disks (VHDX) to store Linux distribution data. These files automatically grow as you add data, but **they never shrink when you delete files**, leading to wasted disk space.

## Quick Start

**Requirements**: Administrator privileges, PowerShell, WSL2

```powershell
# 1. Open PowerShell or Command Prompt as Administrator
# 2. Navigate to the script directory
# 3. Run the script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\wslimming.ps1
```

## How It Works

1. Enumerates installed WSL2 distributions from the registry
2. Prompts you to select one if multiple are installed
3. Locates the `ext4.vhdx` file for that distribution
4. Shuts down WSL and uses DISKPART to compact the VHDX file

## Notes

- If multiple distributions are installed, you'll be prompted to choose one
- The script confirms your selection before proceeding
- Compaction may take a while depending on VHDX size
- **Important**: Always backup your data before running

## Compatibility

- Windows 10/11
- WSL2 distributions

## License

MIT License - see [LICENSE](LICENSE) for details
