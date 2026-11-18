# Claude Code Migrate (Windows)

Two PowerShell scripts for moving Claude Code and Claude Desktop projects, sessions and history from one Windows computer to another — **without losing anything on either side**.

There's no built-in export/import for Claude Code session history yet. These scripts copy and merge the local files Claude uses so that your projects show up in `claude --resume` **and** in the Claude Desktop sidebar on the new computer.

## What gets moved

| Data | Location | How it's merged |
|---|---|---|
| Session transcripts, settings, todos | `%USERPROFILE%\.claude` | Missing files are copied. If a session exists on both computers, the longer copy is kept. Genuine conflicts keep the new computer's copy and set the other aside. |
| Session history | `%USERPROFILE%\.claude\history.jsonl` | Combined line by line, de-duplicated, sorted by time. |
| Project list & SSH trust approvals | `%USERPROFILE%\.claude.json` | Projects missing on the new computer are added; missing per-project settings are filled in. The new computer's login, plugins and preferences are kept. |
| Claude Desktop sidebar | `...\claude-code-sessions` (location depends on how Claude Desktop was installed, found automatically) | Missing sessions are added. Sessions you deleted on the new computer are not restored. |

Your login (`.credentials.json`) is never copied — just sign in on the new computer.

## Usage

Quit Claude Desktop (including from the system tray) and any Claude Code terminals on **both** computers first.

### 1. On the old computer

```powershell
powershell -ExecutionPolicy Bypass -File .\Export-ClaudeData.ps1
```

This creates a `ClaudeExport-<computer>-<date>` folder on your Desktop. To export straight to a network share or USB drive:

```powershell
powershell -ExecutionPolicy Bypass -File .\Export-ClaudeData.ps1 -Dest "\\SERVER\Share\ClaudeExport-OldPC"
```

The old computer is not modified.

### 2. Move the export folder to the new computer

Skip this if you exported to a share both computers can reach.

### 3. On the new computer

```powershell
powershell -ExecutionPolicy Bypass -File .\Import-ClaudeData.ps1 -Source "C:\path\to\ClaudeExport-OldPC-20261118-1000"
```

Without `-Source`, it uses the newest `ClaudeExport-*` folder in `-ShareRoot` (default: your Desktop):

```powershell
powershell -ExecutionPolicy Bypass -File .\Import-ClaudeData.ps1 -ShareRoot "\\SERVER\Share"
```

It shows what it's about to do and asks for confirmation (`-Yes` skips the prompt). Then start Claude Desktop and check the sidebar.

## Safety

- The import backs up everything it changes to `%USERPROFILE%\claude-import-backup-<date>\` before touching anything, along with an `import.log` and any conflicting files under `conflicts-from-other-computer\`.
- Both scripts refuse to run while Claude is open, since Claude rewrites these files on exit.
- The import only ever adds; running it twice is safe.
- To undo, quit Claude and copy the contents of the backup folder back.

## Notes & limitations

- Windows only. The import needs Windows PowerShell 5.1 (built into Windows); if started from PowerShell 7 it relaunches itself in 5.1.
- Session history is keyed by the project's folder path. Projects open fastest on the new computer if they live at the same paths (same drive letters / folder names) as on the old one.
- Claude's local file formats are undocumented and can change between versions. Keep the backup until you've confirmed everything works.
- Not affiliated with or supported by Anthropic.
