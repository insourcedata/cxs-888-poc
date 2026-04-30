  On the Wendy's UAT machine (ITLAB-SVR-AZ)                                                                                                                                                       
                                                                                                                                                                              
  .\install-cxs-collector.ps1                                                                                                                                                 
    -ApiUrl     "https://888.insourcedata.org/api/collect"                                                                                                              
    -ApiKey     "e208da46d44dcd96f4ff1732f85ed306" `
    -SqlServer  "ITLAB-SVR-AZ\np-master"                                                                                                   
    -Database   "NEWPOS"                                                                                                                                     
    -StoreCode  "DK003" 
    -OracleCode "4058"                                                                                                                                                                            
                                                                                                                                                                                                  
  Brand/Company/ExtGuid default to Wendy's UAT values — no need to pass them.                                                                                                                     
                                                                                                                                                                          
  On the Conti's NOC machine (SSTSERVER)                                  
  .\install-cxs-collector.ps1 
    -ApiUrl     "https://888.insourcedata.org/api/collect" `
    -ApiKey     "e208da46d44dcd96f4ff1732f85ed306"                                                                                                                      
    -SqlServer  "SSTSERVER"                                                                                                                        
    -Database   "NOCSSTDB"
    -StoreCode  "NOCSST"                                                                                                                                                  
    -OracleCode ""                                                                                                                                                           
    -Brand      "contis" 
    -Company    "NOC"                                                                                                                                                              
    -ExtGuid    ""   