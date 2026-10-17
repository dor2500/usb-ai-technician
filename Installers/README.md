# Installers

Put the setup files you want to offer here: `.exe`, `.msi`, `.msix`, `.msixbundle`, `.appx`, `.appxbundle`.
Files in sub-folders one level deep are found too (for example `Installers\Office\setup.exe`).

The tool detects the installer type and installs silently when it can:

| Type | How it is detected | Silent switches used |
|------|--------------------|----------------------|
| MSI | `.msi` extension | `msiexec /i file /qn /norestart` |
| MSIX / AppX | extension | `Add-AppxPackage` |
| Inno Setup | marker inside the `.exe` | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` |
| NSIS | marker inside the `.exe` | `/S` |
| WiX Burn bundle | marker inside the `.exe` | `/quiet /norestart` |
| anything else | - | opens normally, you click through it |

## Custom switches

Copy `installers.example.json` to `installers.json` and add rules. `file` accepts wildcards:

```json
{
  "installers": [
    { "file": "ChromeSetup*.exe", "args": "/silent /install" },
    { "file": "OldTool.exe", "interactive": true }
  ]
}
```

Your setup files are ignored by git (see `.gitignore`), so they never end up in the repository.
