#Requires -Version 7.0

<#
.SYNOPSIS
    Agent identity management module (scaffold — not yet implemented).
#>

function Deploy-AgentIdentity {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    if ($PSCmdlet.ShouldProcess('AgentIdentity', 'Deploy')) {
        Write-LabLog -Message "AgentIdentity: not yet implemented for prefix '$($Config.prefix)'. Managed identity and RBAC assignment coming in a future release." -Level Warning
    }
    return @{}
}

function Remove-AgentIdentity {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    if ($PSCmdlet.ShouldProcess('AgentIdentity', 'Remove')) {
        Write-LabLog -Message "AgentIdentity: not yet implemented for prefix '$($Config.prefix)'. Manifest entries: $($Manifest.Count)." -Level Warning
    }
}

Export-ModuleMember -Function @(
    'Deploy-AgentIdentity'
    'Remove-AgentIdentity'
)
