# Changelog

## v1.0.0 - 2026-10-17

First release.

- **Clean up**: lists installed programs and removable Store apps; gpt-oss-20b (local, via llama.cpp) labels each one
  remove / keep / ask; you choose what to keep; restore point and typed `YES` before uninstalling; drivers, runtimes and
  security software are protected; optional cleanup of temp files older than a day.
- **Install from the USB**: detects MSI, MSIX/AppX, Inno Setup, NSIS and WiX Burn installers and installs silently;
  per-file switches via `Installers/installers.json`.
- **Windows Update**: installs pending updates through the built-in Windows Update API (feature upgrades skipped), then
  pins the Windows version, blocks driver updates, keeps security updates automatic and prevents forced restarts.
  Original settings are backed up on the USB; menu option 6 restores them. `ManualOnly` mode turns automatic updates off.
- **Ask the AI technician**: advice-only chat, answers in your language.
- `Setup-USB.cmd` downloads llama.cpp and gpt-oss-20b with SHA-256 verification and resumable model download.
- `-DryRun`, `-NoAI` and `-Action` command-line options; session logs on the USB.
- Tests for Windows PowerShell 5.1 and PowerShell 7, CI on GitHub Actions.
