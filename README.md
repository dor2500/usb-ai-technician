<p align="center">
  <img src="docs/images/banner.svg" alt="USB AI Technician" width="100%">
</p>

<p align="center">
  <a href="README.he.md"><b>🇮🇱 קראו בעברית</b></a>
</p>

**USB AI Technician** is a portable PC-maintenance tool that runs from a USB stick. Plug it into a Windows PC, run `Start.cmd`, and it can:

1. **Clean up**: a local AI flags bloatware, you choose what to keep, the rest is uninstalled.
2. **Install programs** from the `Installers` folder on the USB, silently when possible.
3. **Update Windows**, then keep only security updates automatic.

The AI is [gpt-oss-20b](https://huggingface.co/openai/gpt-oss-20b), run offline through [llama.cpp](https://github.com/ggml-org/llama.cpp) on `127.0.0.1` only. Nothing is installed on the PC. Logs and backups stay on the USB.

<p align="center">
  <img src="docs/images/screen-cleanup.svg" alt="Cleanup: the AI suggests, you decide" width="80%">
</p>

## Quick start

**Requirements:** a 32 GB+ USB stick formatted **exFAT or NTFS** (the model is 12 GB, too big for FAT32), and Windows 10/11 with admin rights. The AI needs about 16 GB of RAM. On smaller PCs, use `-NoAI`.

1. **Prepare the USB (once).** Extract the latest [release](https://github.com/dor2500/usb-ai-technician/releases/latest) onto the USB (the `-with-llama.cpp` zip saves a download), then run `Setup-USB.cmd`. It downloads llama.cpp and the model and checks both with SHA-256.
2. **Add installers.** Copy `.exe` / `.msi` / `.msix` files into `Installers\`. See [Installers/README.md](Installers/README.md).
3. **Run.** On the target PC, double-click `Start.cmd` and pick from the menu: cleanup, install, update, all three, chat with the AI, or undo the update lock.

```powershell
Start.cmd -Action All    # also: Cleanup, Install, Update, UndoUpdateLock, Chat
Start.cmd -NoAI          # no model; you pick what to remove yourself
Start.cmd -DryRun        # show what would happen, change nothing

Setup-USB.cmd -Backend cpu       # CPU-only llama.cpp instead of Vulkan
Setup-USB.cmd -Force -SkipModel  # update llama.cpp only
```

## How it works

- **Cleanup**: drivers, runtimes and security software are never offered for removal ([`config/protected.json`](config/protected.json)). Before anything is uninstalled you type `YES`, and the tool creates a restore point. It can also delete temp files older than a day.
- **Install**: detects MSI, MSIX/AppX, Inno Setup, NSIS and WiX Burn installers and uses their silent switches. Unknown installers open normally.
- **Update**: installs pending updates through the built-in Windows Update API, then sets policies that pin the current Windows version, block driver updates and prevent forced restarts. Monthly security updates stay automatic. The original settings are backed up to `backups\` on the USB, and menu option 6 restores them. Set `"mode": "ManualOnly"` in [`config/settings.json`](config/settings.json) to turn automatic updates off completely.
- **AI**: it only makes suggestions and cannot run anything. All changes are made by plain PowerShell after you confirm. The model is unloaded as soon as the review is done.

Every action is logged to `logs\` on the USB. Use this only on computers you are allowed to administer.

## FAQ

- **"Windows protected your PC"**: click *More info → Run anyway*, or run `Get-ChildItem -Recurse E:\ | Unblock-File`.
- **AI is slow or won't start**: check `logs\llama-server.err.log`. The first load from a USB 2 stick can take minutes. Use `-NoAI` on low-RAM PCs.
- **"Some settings are managed by your organization"**: that message comes from the update policies. Menu option 6 removes them.
- **Windows Home**: it may ignore the version pin and the driver block. Security updates keep working either way.

## Development

```powershell
.\tests\Run-Tests.ps1        # Windows PowerShell 5.1 and PowerShell 7
.\Start.cmd -DryRun -NoAI    # safe end-to-end run
```

## License

[MIT](LICENSE). gpt-oss-20b is Apache-2.0 (OpenAI). llama.cpp is MIT. Provided as-is: you are responsible for the changes you confirm.
