```  
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force .\update-cxs-collector.ps1 -Migrate


or

powershell -ExecutionPolicy Bypass -File "C:\CXS\update-cxs-collector.ps1" -Migrate
```

```
API_KEY=e208da46d44dcd96f4ff1732f85ed306
```

```
  1. Scheduled tasks weren't actually created

  The installer might have reported success but failed silently when creating the tasks.

  Check on store server:
  # See if the tasks exist
  Get-ScheduledTask -TaskName "CXS *" | Where-Object {$_.TaskName -like "*ACCBBR*"} | Format-List TaskName, State, LastRunTime

  2. Tasks exist but aren't running

  Task scheduler might have them but they're disabled or failing.

  Check:
  Get-ScheduledTask -TaskName "CXS *ACCBBR*" | Select-Object TaskName, State, Enabled
  # Try to run manually
  Start-ScheduledTask -TaskName "CXS Agent Heartbeat - ACCBBR"
  # Wait 10 seconds, then check logs
  Get-Content C:\CXS\logs\agent-ACCBBR.log -Tail 20

  3. Folder permission issue

  The CXS folder exists but the scheduled task (running as SYSTEM) can't write to it.

  Check:
  # Check CXS folder exists and is writable
  Test-Path C:\CXS
  Test-Path C:\CXS\logs
  icacls C:\CXS

  4. API key wrong or missing

  The heartbeat is being sent but rejected by the collector (401 Unauthorized).

  Check collector logs:
  railway logs --service collector --lines 500 | grep -i "accbbr"

  5. PowerShell execution policy blocking tasks

  The installer runs with bypass, but the scheduled tasks run in a fresh session without it.

  Check task action:
  $scht = Get-ScheduledTask -TaskName "CXS Agent Heartbeat - ACCBBR"
  $scht.Actions.Execute

  ---
  Quick diagnostic commands (run on store server):

  # 1. Check if tasks exist
  Get-ScheduledTask | Where-Object {$_.TaskName -like "*CXS*"} | Format-Table TaskName, State, Enabled

  # 2. Check if logs folder exists
  Get-ChildItem C:\CXS\logs -ErrorAction SilentlyContinue

  # 3. Try running heartbeat manually
  C:\CXS\cxs-agent-ACCBBR.ps1
  Start-Sleep 5
  Get-Content C:\CXS\logs\agent-ACCBBR.log -Tail 10
  ```
