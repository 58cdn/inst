# cgpu

Windows (cmd / Windows PowerShell 5.1 / PowerShell 7) GPU monitor.
Requires NVIDIA drivers and `nvidia-smi`. No third-party dependencies.

```powershell
cgpu                  # refresh every 1 second, Ctrl+C to exit
cgpu -Interval 2      # refresh every 2 seconds
cgpu -Once            # show one snapshot
```

Installed files: `%USERPROFILE%\.command\cgpu.ps1`,
`%USERPROFILE%\.command\cgpu.cmd`, and this `cgpu.md`.
The installer adds `%USERPROFILE%\.command` to the user PATH; open a new
terminal after installation. `cgpu.cmd` launches PowerShell with
process-only execution policy Bypass. It does not change machine or user policy.
