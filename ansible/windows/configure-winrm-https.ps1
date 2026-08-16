[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DnsName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{40,64}$')]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory = $true)]
    [string[]]$AllowedRemoteAddress,

    [bool]$DisableHttpListener = $true
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

$privateAddressPattern = '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|f[c-d][0-9a-f]:)'
if (-not $AllowedRemoteAddress -or ($AllowedRemoteAddress | Where-Object { $_ -notmatch $privateAddressPattern })) {
    throw 'AllowedRemoteAddress must contain only RFC1918 or unique-local IPv6 execution-node addresses/CIDRs.'
}

$thumbprint = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
$certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint"
$now = Get-Date
if (-not $certificate.HasPrivateKey) {
    throw 'The WinRM server certificate must include its private key.'
}
if ($certificate.NotBefore -gt $now -or $certificate.NotAfter -le $now) {
    throw 'The WinRM server certificate is not currently valid.'
}
if ($certificate.Subject -eq $certificate.Issuer) {
    throw 'A self-signed certificate is not accepted by the secure profile. Use a certificate issued by a trusted CA.'
}
$chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
if (-not $chain.Build($certificate)) {
    $chainErrors = ($chain.ChainStatus.StatusInformation.Trim() -join '; ')
    throw "Windows does not trust the WinRM certificate chain: $chainErrors"
}

$serverAuthenticationOid = '1.3.6.1.5.5.7.3.1'
$hasServerAuthentication = $certificate.EnhancedKeyUsageList.ObjectId.Value -contains $serverAuthenticationOid
if (-not $hasServerAuthentication) {
    throw 'The certificate must include the Server Authentication enhanced key usage.'
}

$certificateDnsName = $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)
$sanExtension = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
$sanText = if ($sanExtension) { $sanExtension.Format($false) } else { '' }
if ($certificateDnsName -ne $DnsName -and $sanText -notmatch "(?i)(DNS Name=|DNS:)\s*$([regex]::Escape($DnsName))(,|\r?\n|$)") {
    throw "The certificate DNS name/SAN does not match '$DnsName'."
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Configure secure WinRM HTTPS listener')) {
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM

    Set-Item -LiteralPath WSMan:\localhost\Service\AllowUnencrypted -Value $false
    Set-Item -LiteralPath WSMan:\localhost\Service\Auth\Basic -Value $false
    Set-Item -LiteralPath WSMan:\localhost\Service\Auth\CredSSP -Value $false
    Set-Item -LiteralPath WSMan:\localhost\Service\Auth\Negotiate -Value $true
    Set-Item -LiteralPath WSMan:\localhost\Service\Auth\Kerberos -Value $true

    Get-ChildItem -LiteralPath WSMan:\localhost\Listener |
        Where-Object { $_.Keys -contains 'Transport=HTTPS' } |
        Remove-Item -Recurse -Force

    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * `
        -Hostname $DnsName -CertificateThumbPrint $thumbprint -Force | Out-Null

    if ($DisableHttpListener) {
        Get-ChildItem -LiteralPath WSMan:\localhost\Listener |
            Where-Object { $_.Keys -contains 'Transport=HTTP' } |
            Remove-Item -Recurse -Force
    }

    Get-NetFirewallRule -DisplayName 'MigrationLab WinRM HTTPS 5986' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'MigrationLab WinRM HTTPS 5986' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5986 `
        -RemoteAddress $AllowedRemoteAddress -Profile Domain,Private | Out-Null

    Restart-Service -Name WinRM
}

$httpsListener = Get-ChildItem -LiteralPath WSMan:\localhost\Listener |
    Where-Object { $_.Keys -contains 'Transport=HTTPS' }
if (-not $httpsListener) {
    throw 'WinRM HTTPS listener validation failed.'
}
if ($DisableHttpListener) {
    $httpListener = Get-ChildItem -LiteralPath WSMan:\localhost\Listener |
        Where-Object { $_.Keys -contains 'Transport=HTTP' }
    if ($httpListener) {
        throw 'The WinRM HTTP listener is still enabled.'
    }
}

Write-Host 'Secure WinRM HTTPS listener is configured.'
Write-Host "DNS name: $DnsName"
Write-Host 'Port: 5986'
Write-Host "Allowed source: $($AllowedRemoteAddress -join ', ')"
Write-Host 'Certificate validation must remain enabled in AAP.'
