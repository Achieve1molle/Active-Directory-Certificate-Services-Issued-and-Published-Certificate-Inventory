#requires -Version 4.0
<#
.SYNOPSIS
  Read-only AD CS inventory for Windows Server 2012 R2 and later.
.DESCRIPTION
  Run locally on EACH PKI server. Exports installed roles, local CA type,
  issued request database records, and (for enterprise CAs) published template
  configuration and permissions. Every run gets a separate server/CA folder.
  Requires ActiveDirectory module for template export only.
#>
[CmdletBinding()]
param(
    [ValidateSet('Inventory','Issued','Templates','All')]
    [string]$Export = 'All',
    [string]$OutputRoot = 'C:\ADCS-Inventory'
)
$ErrorActionPreference = 'Stop'
function SafeName([string]$Value) { return ($Value -replace '[\\/:*?"<>|]', '_') }
function Save-Certutil([string[]]$Arguments, [string]$Path) {
    $lines = @(& certutil.exe @Arguments 2>&1)
    $exit = $LASTEXITCODE
    $lines | Out-File -LiteralPath $Path -Encoding UTF8 -Width 32767
    if ($exit -ne 0) { throw "certutil exit code $exit. See $Path" }
}
function StringValue($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return [Convert]::ToBase64String($Value) }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    return [string]$Value
}
$server = $env:COMPUTERNAME
$caName = ''
$caType = 'Not a local CA'
$caCode = ''
$caConfig = ''
$serviceState = ''
$roles = @()
$warnings = New-Object 'System.Collections.Generic.List[string]'
$rootKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
try {
    if (Test-Path -LiteralPath $rootKey) {
        $caName = [string](Get-ItemProperty -LiteralPath $rootKey -Name Active -ErrorAction Stop).Active
        if ($caName) {
            $caKey = Join-Path $rootKey $caName
            $caCode = (Get-ItemProperty -LiteralPath $caKey -Name CAType -ErrorAction Stop).CAType
            $caConfig = '{0}\{1}' -f $server,$caName
            switch ([int]$caCode) {
                0 { $caType = 'Enterprise Root CA' }
                1 { $caType = 'Enterprise Subordinate CA' }
                3 { $caType = 'Standalone Root CA' }
                4 { $caType = 'Standalone Subordinate CA' }
                default { $caType = "Unknown CA type ($caCode)" }
            }
            $serviceState = [string](Get-Service CertSvc -ErrorAction Stop).Status
        }
    }
} catch { $warnings.Add("CA detection: $($_.Exception.Message)") }
$folder = Join-Path $OutputRoot ('{0}_{1}_{2}' -f (SafeName $server),(SafeName $caName),(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -Path $folder -ItemType Directory -Force | Out-Null
try {
    Import-Module ServerManager -ErrorAction Stop
    $roles = @(Get-WindowsFeature -Name 'ADCS*' -ErrorAction Stop | Where-Object { $_.Installed } | Select-Object Name,DisplayName,InstallState)
    if ($roles.Count) {
        $roles | Export-Csv -LiteralPath (Join-Path $folder 'InstalledADCSRoles.csv') -NoTypeInformation -Encoding UTF8
    }
} catch { $warnings.Add("Role detection: $($_.Exception.Message)") }
$fqdn = $server
try { $fqdn = ([System.Net.Dns]::GetHostEntry($server)).HostName } catch { $warnings.Add("FQDN lookup: $($_.Exception.Message)") }
[pscustomobject]@{
    RunTime=(Get-Date).ToString('o'); Server=$server; FQDN=$fqdn
    InstalledADCSRoles=(($roles | ForEach-Object { $_.Name }) -join ' | ')
    LocalCA=[bool]$caConfig; CAName=$caName; CAConfig=$caConfig
    CAType=$caType; CATypeCode=$caCode; CertSvcStatus=$serviceState
    RequestedExport=$Export
} | Export-Csv -LiteralPath (Join-Path $folder 'ServerAndCAInventory.csv') -NoTypeInformation -Encoding UTF8

if ($Export -in @('Issued','All')) {
    if (-not $caConfig) { $warnings.Add('Issued export skipped: no local CA detected.') }
    else {
        try {
            $raw = Join-Path $folder 'IssuedCertificates_Raw.csv'
            Save-Certutil @('-config',$caConfig,'-view','-restrict','Disposition=20','csv') $raw
            # Keep native CSV untouched. Normalize only if its header can be identified.
            $rows = @(Import-Csv -LiteralPath $raw)
            $id = $null
            if ($rows.Count) {
                $id = @($rows[0].PSObject.Properties.Name | Where-Object { ($_ -replace '[^a-zA-Z]','') -ieq 'RequestID' } | Select-Object -First 1)
            }
            if ($id.Count -gt 0 -and $id[0]) {
                $idName = [string]$id[0]
                $out = Join-Path $folder 'IssuedCertificates_ByCA.csv'
                $count = 0
                $rows | Where-Object { $_.$idName -match '^\s*\d+\s*$' } | ForEach-Object {
                    $r = [ordered]@{ CAServer=$server; CAName=$caName; CAType=$caType }
                    foreach ($prop in $_.PSObject.Properties) { $r[$prop.Name] = $prop.Value }
                    $count++
                    [pscustomobject]$r
                } | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
                if (-not $count) { $warnings.Add('No issued rows parsed; inspect IssuedCertificates_Raw.csv.') }
            } else { $warnings.Add('Issued CSV header not recognized; native CSV retained. Inspect IssuedCertificates_Raw.csv.') }
        } catch { $warnings.Add("Issued records: $($_.Exception.Message)") }
        # Independent steps so one unsupported option does not suppress other exports.
        $tasks = @(
            @{ Name='RequestCertificateSchema.txt'; Args=@('-config',$caConfig,'-schema') },
            @{ Name='ExtensionSchema.txt'; Args=@('-config',$caConfig,'-schema','Ext') },
            @{ Name='AttributeSchema.txt'; Args=@('-config',$caConfig,'-schema','Attrib') },
            @{ Name='Extensions_Raw.csv'; Args=@('-config',$caConfig,'-view','Ext','csv') },
            @{ Name='RequestAttributes_Raw.csv'; Args=@('-config',$caConfig,'-view','Attrib','csv') }
        )
        foreach ($task in $tasks) {
            try { Save-Certutil $task.Args (Join-Path $folder $task.Name) }
            catch { $warnings.Add("$($task.Name): $($_.Exception.Message)") }
        }
    }
}
if ($Export -in @('Templates','All')) {
    if ($caType -notlike 'Enterprise *') { $warnings.Add('Template export skipped: no enterprise CA detected on this server.') }
    else {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $configDN = (Get-ADRootDSE -ErrorAction Stop).ConfigurationNamingContext
            $pki = 'CN=Public Key Services,CN=Services,{0}' -f $configDN
            $enrollmentBase = 'CN=Enrollment Services,{0}' -f $pki
            $templateBase = 'CN=Certificate Templates,{0}' -f $pki
            $caObjects = @(Get-ADObject -SearchBase $enrollmentBase -SearchScope OneLevel -LDAPFilter '(objectClass=pKIEnrollmentService)' -Properties certificateTemplates,dNSHostName,displayName -ErrorAction Stop | Where-Object {
                ($_.Name -ieq $caName -or $_.displayName -ieq $caName) -and
                ($_.dNSHostName -ieq $fqdn -or ([string]$_.dNSHostName -split '\.')[0] -ieq $server)
            })
            if ($caObjects.Count -ne 1) { throw "Expected one AD enrollment object for $caConfig; found $($caObjects.Count)." }
            $caObject = $caObjects[0]
            $names = @($caObject.certificateTemplates | Where-Object { $_ })
            if ($names.Count) {
                $mapping = foreach ($name in $names) {
                    [pscustomobject]@{ CAServer=$server; CAName=$caName; CAType=$caType; TemplateName=[string]$name; EnrollmentObjectDN=$caObject.DistinguishedName }
                }
                $mapping | Export-Csv -LiteralPath (Join-Path $folder 'CAPublishedTemplateMapping.csv') -NoTypeInformation -Encoding UTF8
            } else { $warnings.Add('Enterprise CA has no published template names in its AD enrollment object.') }
            $templates = @(Get-ADObject -SearchBase $templateBase -SearchScope OneLevel -LDAPFilter '(objectClass=pKICertificateTemplate)' -Properties * -ErrorAction Stop | Where-Object { $names -contains $_.Name } | Sort-Object Name)
            if ($templates.Count -ne $names.Count) { $warnings.Add("Published templates: $($names.Count) names; $($templates.Count) AD objects read.") }
            $attrFile = Join-Path $folder 'PublishedTemplateAttributes.csv'
            $aclFile = Join-Path $folder 'PublishedTemplatePermissions.csv'
            $attrCount = 0; $aclCount = 0
            foreach ($template in $templates) {
                $attributes = foreach ($prop in $template.PSObject.Properties) {
                    if ($prop.Name -like 'PS*') { continue }
                    $values = if ($null -eq $prop.Value) { @('') } elseif ($prop.Value -is [byte[]]) { ,$prop.Value } elseif ($prop.Value -is [System.Array]) { @($prop.Value) } else { @($prop.Value) }
                    for ($i=0; $i -lt $values.Count; $i++) {
                        [pscustomobject]@{ CAServer=$server; CAName=$caName; TemplateName=$template.Name; TemplateDN=$template.DistinguishedName; AttributeName=$prop.Name; ValueIndex=$i; AttributeValue=(StringValue $values[$i]) }
                    }
                }
                if ($attributes) {
                    $attributes | Export-Csv -LiteralPath $attrFile -NoTypeInformation -Encoding UTF8 -Append:($attrCount -gt 0)
                    $attrCount += @($attributes).Count
                }
                try {
                    $acl = Get-Acl -LiteralPath ('AD:\' + $template.DistinguishedName) -ErrorAction Stop
                    $aces = foreach ($ace in $acl.Access) {
                        [pscustomobject]@{
                            CAServer=$server; CAName=$caName; TemplateName=$template.Name; TemplateDN=$template.DistinguishedName
                            Owner=[string]$acl.Owner; SDDL=$acl.Sddl; IdentityReference=[string]$ace.IdentityReference
                            AccessControlType=[string]$ace.AccessControlType; ActiveDirectoryRights=[string]$ace.ActiveDirectoryRights
                            ObjectType=[string]$ace.ObjectType; InheritanceType=[string]$ace.InheritanceType
                            InheritedObjectType=[string]$ace.InheritedObjectType; IsInherited=$ace.IsInherited
                            InheritanceFlags=[string]$ace.InheritanceFlags; PropagationFlags=[string]$ace.PropagationFlags
                        }
                    }
                    if ($aces) {
                        $aces | Export-Csv -LiteralPath $aclFile -NoTypeInformation -Encoding UTF8 -Append:($aclCount -gt 0)
                        $aclCount += @($aces).Count
                    }
                } catch { $warnings.Add("Template ACL $($template.Name): $($_.Exception.Message)") }
            }
        } catch { $warnings.Add("Template export: $($_.Exception.Message)") }
    }
}
if ($warnings.Count) { $warnings | Out-File -LiteralPath (Join-Path $folder 'Warnings.txt') -Encoding UTF8 }
Write-Host "Inventory folder: $folder"
foreach ($warning in $warnings) { Write-Warning $warning }
