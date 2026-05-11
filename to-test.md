  Start-ScheduledTask -TaskName "CXS Daily Sync"
  Start-Sleep -Seconds 15                                                                                                                                                                                   
  
  Get-ScheduledTask -TaskName "CXS Daily Sync" | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult                   
                                                    