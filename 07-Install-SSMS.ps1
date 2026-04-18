[CmdletBinding()]
param(
    [Parameter(Mandatory)][PSCustomObject]$VMDef,
    [Parameter(Mandatory)][PSCustomObject]$Config
)

$domainCred = New-Object PSCredential(
    "$($Config.DomainNetBIOS)\Administrator",
    (Get-Secret -Name 'DomainAdminPass' -Vault $Config.SecretsVault))

Invoke-Command -ComputerName $VMDef.IP -Credential $domainCred -ScriptBlock {

    $ssmsUrl = "https://aka.ms/ssmsfullsetup"
    $dest    = "C:\Windows\Temp\SSMS-Setup.exe"

    Write-Host "Downloading SSMS..."
    Invoke-WebRequest -Uri $ssmsUrl -OutFile $dest -UseBasicParsing

    Write-Host "Installing SSMS silently..."
    $result = Start-Process -FilePath $dest `
        -ArgumentList "/install /quiet /norestart" `
        -Wait -PassThru -NoNewWindow

    if ($result.ExitCode -notin @(0, 3010)) {
        throw "SSMS install failed with exit code $($result.ExitCode)"
    }

    Write-Host "SSMS installation complete."
}
