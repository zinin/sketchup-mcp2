# Live checks on a Windows VM, unattended

How an agent (or a person at a terminal) runs the live checks of a release against SketchUp on a Windows VM without anyone at the VM: install a plugin build, restart SketchUp, drive the Settings dialog with real clicks, and test what only a running SketchUp shows (the handshake, the token, Regenerate, a crash). It complements [`examples/smoke_check.py`](../examples/smoke_check.py), which covers the tools.

Placeholders: `<vm>` is the VM's SSH host, `<year>` the SketchUp version (`2027`), `<probe>` a scratch folder on the VM such as `%LOCALAPPDATA%\Temp\live-check`. Nothing here needs a secret in a file of the repository.

## Ground rules

- **Ask the VM's owner first** before anything that changes the VM beyond the plugin: scheduled tasks, an antivirus exception, killing SketchUp. Undo all of it at the end ([Clean up](#clean-up)).
- **Nobody uses the VM's mouse or keyboard** while the checks run: the clicks are real and land wherever the cursor is.
- **The token never reaches output, a log or a commit.** Copy it over SSH into a file readable only by you (`umask 077`), compare it by length, format and equality, and delete the copies afterwards. Print `hex64=True`, never the value.
- **Leave the model as you found it.** Name probes `probe_*` and erase them; `examples/smoke_check.py` deletes its components but leaves the tag "MCP Test" and a material ([`release.md`](release.md) §3).

## Requirements

- Windows with SketchUp and the OpenSSH server; key login for the account that is **logged in at the console** (`query user` shows it `Active`). An administrator account is needed only for the antivirus step.
- On the dev box: this repository, `uv`, and `SKETCHUP_MCP_HOST=<vm>`.

## Reaching the desktop from SSH

An SSH session has no desktop: a window started from it is invisible, and nothing in it can take a screenshot or click. Run those steps as a **scheduled task with an interactive logon** for the same user; it runs in the console session.

```powershell
# Once, over SSH (the remote shell is PowerShell). wscript keeps a console window from flashing.
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name   # not $env:USERDOMAIN: it may not resolve over SSH
$p  = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$s  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$a  = New-ScheduledTaskAction -Execute wscript.exe -Argument '"<probe>\run.vbs"'
Register-ScheduledTask -TaskName LiveCheckProbe -Action $a -Principal $p -Settings $s
```

- `run.vbs` runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <probe>\job.ps1` hidden and waits (`WScript.Shell.Run cmd, 0, True`).
- `job.ps1` dot-sources a helper library, runs `body.ps1` with every stream redirected to `out.txt` (`Out-File -Encoding utf8`: Windows PowerShell's `*>` writes UTF-16), and writes `done.txt` in `finally`.
- One step from the dev box: `scp` a new `body.ps1`, `Start-ScheduledTask LiveCheckProbe`, wait for `done.txt`, read `out.txt`. A step takes three to five seconds.

The helper library (keep it ASCII: Windows PowerShell reads a script without a BOM as ANSI):

| Need | How |
|---|---|
| Physical coordinates | call `SetProcessDPIAware()` (user32) first, before anything asks for screen sizes |
| Screenshot | `System.Drawing`: `Graphics.CopyFromScreen` into a bitmap, saved as PNG; `scp` it back and look at it |
| Click | `SetCursorPos(x, y)`, then `mouse_event` left down and up |
| Typing | `System.Windows.Forms.SendKeys.SendWait` |
| Windows, buttons | UI Automation (`UIAutomationClient`): find an element by name and `InvokePattern.Invoke()` it — the confirm's **Yes**, for instance. An `HtmlDialog`'s page shows up as an element named after the page `<title>`; its rectangle is the content area |
| Clipboard | `Get-Clipboard` (it is per session, so it runs in the task too) |

**Microsoft Defender** flags a screenshot script as `HackTool:PowerShell/EmpireGetScreenshot` and blocks it (AMSI). It is a false positive for this use; with the owner's consent allow that one detection, and remove the allowance at the end:

```powershell
$id = (Get-MpThreatDetection | Sort-Object InitialDetectionTime -Descending | Select-Object -First 1).ThreatID
Add-MpPreference -ThreatIDDefaultAction_Ids $id -ThreatIDDefaultAction_Actions Allow
# at the end
Remove-MpPreference -ThreatIDDefaultAction_Ids $id
```

A VNC server on the VM with `vncdotool` on the dev box does the same (screenshots, clicks, typing) faster and without the antivirus step, at the cost of installing it.

## Installing a build and restarting SketchUp

1. **Close SketchUp cleanly**, so it writes its preferences: through the session's `eval_ruby`, `UI.start_timer(0.5, false) { Sketchup.quit }`. Check `Sketchup.active_model.modified?` first; a modified model would ask to be saved.
2. **Unpack the `.rbz`** — what Extension Manager's *Install Extension* does — over SSH: copy it as `<probe>\build.zip`, then `Expand-Archive -Force` into `%APPDATA%\SketchUp\SketchUp <year>\SketchUp\Plugins`. Compare one file's hash with the checkout (`Get-FileHash` against `sha256sum`). Over a **signed** build, delete its `mcp_for_sketchup` folder and `mcp_for_sketchup.rb` first: its `.rbe` files and signature would stay beside the new files ([`release.md`](release.md) §3).
3. **Start SketchUp** through a second interactive task whose action is `SketchUp.exe -RubyStartup "<probe>\start_mcp.rb"`, with `start_mcp.rb` containing `UI.start_timer(2, false) { MCPforSketchUp::Core::Application.start }`. The server starts without a menu click.
4. **The Welcome screen** waits for a template: list the windows (UI Automation) until `Welcome to SketchUp` appears, take a screenshot, click the template the model used before.
5. **Wait for the port** (`bash -c 'exec 3<>/dev/tcp/<vm>/9876'` in a loop), then `get_version` through the MCP session.

## The checks

- **Protocol and token.** A short Python script on the dev box using `sketchup_mcp.connection.SketchUpConnection`: a wrong token (random 64 hex), no token, a raw socket that sends `hello` and then `auth` with a wrong proof (expect `-32003` and a closed socket), a `hello` with `client_version` `0.4.0` and no `client_nonce` (`-32001`, "pre-dates socket authentication"), a 5000-byte frame header before the handshake (refused at the header), and a fake server on the dev box that answers `hello` with a made-up proof (the client refuses it and never sends `auth`).
- **Tools.** `SKETCHUP_MCP_HOST=<vm> SKETCHUP_MCP_SMOKE_REMOTE=1 SKETCHUP_MCP_TOKEN=… uv run python examples/smoke_check.py`, with the token read from the MCP config inside the command, not echoed. Then an `eval_ruby` call over 4 KiB and `get_viewport_screenshot`.
- **The server log.** SketchUp's Ruby Console cannot be read from outside. For the checks, set `Config.log_to_file = true` and `Config.log_file_path` to a file in `%TEMP%` through `eval_ruby` — in memory only, the saved settings stay as they were — and read the file over SSH. Look for `auth_failed` and `handshake_rejected` at WARN, with no token or proof in the line.
- **The Settings dialog.**
  - Open it with `MCPforSketchUp::UI::SettingsDialog.show`. `get_size` and `get_content_size` give the window in logical pixels.
  - A screenshot may show an `HtmlDialog` blank: its page is drawn on the GPU, and the capture does not always see it. Check the page from inside instead. `execute_script` runs in the page, but a callback added after the page loaded is not visible to it. So answer through one the dialog already has: replace `on_check_host` for one call with `define_singleton_method`, keep the payload, and put the original back.
  - Read layout from the DOM (`getBoundingClientRect`, `clientHeight`, `scrollHeight`). For a real click, multiply the page coordinates by the display scale and add the content area's origin.
  - Type into a field from JavaScript (`value =` plus an `input` event) when the page's reaction is what is tested. Click for real when the click is.
- **Regenerate.**
  1. Click Regenerate twice quickly. The screenshot must show one confirm.
  2. Press **Yes** through UI Automation.
  3. Click **Copy** and read the clipboard into `<probe>`. `scp` it into a private file and delete it on the VM.
  4. The MCP session, still on the old token, must now answer "does not know this token".
- **A crash after Regenerate.**
  1. `Stop-Process -Name SketchUp -Force` (what *End task* does), then restart as above.
  2. Connect once with the old token and once with the new one. Only the new one may be accepted.
  
  The token lives in its own file, written at once, for this reason. SketchUp's preferences reach the disk only on a clean exit.

## Clean up

- `Unregister-ScheduledTask` both tasks; remove the Defender allowance (and only yours: list `ThreatIDDefaultAction_Ids` before and after); delete `<probe>` and the log file in `%TEMP%`.
- Put the token SketchUp now has into the MCP client's config, delete the local copies, and reconnect the client (`/mcp` in Claude Code).
- Check that the model holds nothing of the checks (`get_model_info`).
