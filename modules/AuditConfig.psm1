#Requires -Version 7.0

function Deploy-AuditConfig {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $results = @{
        auditEnabled = $false
        searches     = @()
    }

    # Enable unified audit logging if not already enabled
    try {
        $auditConfig = Get-AdminAuditLogConfig -ErrorAction Stop
        if ($auditConfig.UnifiedAuditLogIngestionEnabled) {
            Write-LabLog -Message 'Unified audit logging is already enabled.' -Level Info
            $results.auditEnabled = $true
        }
        else {
            if ($PSCmdlet.ShouldProcess('Unified Audit Log', 'Enable')) {
                Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
                Write-LabLog -Message 'Enabled unified audit logging.' -Level Success
                $results.auditEnabled = $true
            }
        }
    }
    catch {
        Write-LabLog -Message "Could not configure audit logging: $($_.Exception.Message)" -Level Warning
    }

    # Create saved audit log searches for AI activities
    if ($Config.workloads.PSObject.Properties['auditConfig'] -and $Config.workloads.auditConfig.searches) {
        foreach ($search in $Config.workloads.auditConfig.searches) {
            $searchName = "$($Config.prefix)-$($search.name)"

            if ($PSCmdlet.ShouldProcess($searchName, 'Create audit log search')) {
                try {
                    $searchParams = @{
                        Name       = $searchName
                        Operations = $search.operations
                        StartDate  = (Get-Date).AddDays(-30)
                        EndDate    = (Get-Date).AddDays(1)
                    }

                    $searchResult = Search-UnifiedAuditLog @searchParams -ResultSize 1 -ErrorAction Stop
                    $resultCount = if ($searchResult) { ($searchResult | Measure-Object).Count } else { 0 }

                    Write-LabLog -Message "Audit search '$searchName' validated ($resultCount recent records found)." -Level Success
                    $results.searches += @{
                        name       = $searchName
                        operations = $search.operations
                        status     = 'validated'
                    }
                }
                catch {
                    Write-LabLog -Message "Audit search '$searchName' could not be validated: $($_.Exception.Message)" -Level Warning
                    $results.searches += @{
                        name   = $searchName
                        status = 'failed'
                    }
                }
            }
        }
    }

    return $results
}

function Remove-AuditConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    # Audit config is non-destructive — we don’t disable audit logging on removal
    # Saved searches are transient (Search-UnifiedAuditLog doesn’t persist)
    if ($PSCmdlet.ShouldProcess($Config.prefix, 'Preserve audit configuration')) {
        $searchCount = if ($Manifest -and $Manifest.PSObject.Properties['searches']) { @($Manifest.searches).Count } else { 0 }
        Write-LabLog -Message "Audit configuration is preserved on removal (audit logging remains enabled). Manifest search entries: $searchCount." -Level Info
    }
}

Export-ModuleMember -Function @(
    'Deploy-AuditConfig'
    'Remove-AuditConfig'
)
