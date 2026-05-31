<#
.SYNOPSIS
    CSV-driven, idempotent user onboarding for the lab.local domain.

.DESCRIPTION
    Reads a CSV of new hires and, for each one:
      - derives a firstname.lastname SAM and UPN
      - creates the AD user in the correct department OU (skips if already present)
      - adds the user to their AGDLP role group(s)
      - creates a home directory and sets NTFS permissions (user = Modify, Administrators = FullControl)

    Safe to re-run: existing users are skipped, not duplicated. All actions are
    logged via Start-Transcript.

.PARAMETER InitialPassword
    The temporary password assigned to new accounts. Users are forced to change it
    at first logon. Passed at runtime so no credential is stored in source.

.EXAMPLE
    .\Onboarding.ps1 -InitialPassword (Read-Host -AsSecureString)
#>

param(
    [Parameter(Mandatory = $true)]
    [System.Security.SecureString]$InitialPassword,

    [string]$CsvPath        = "C:\Scripts\users.csv",
    [string]$LogPath        = "C:\Scripts\Logs",
    [string]$HomeFolderRoot = "C:\HomeDirectories"
)

# Create log folder if it doesn't exist
if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath | Out-Null }

# Start transcript
Start-Transcript -Path "$LogPath\Onboarding_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# Import CSV
$users = Import-Csv -Path $CsvPath

# Validate required columns exist
$requiredColumns = @("FirstName","LastName","Department","JobTitle","RoleGroups")
$csvColumns = $users[0].PSObject.Properties.Name
$missing = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missing) {
    Write-Error "CSV is missing required column(s): $($missing -join ', ')"
    Stop-Transcript
    return
}

foreach ($user in $users) {
    $sam         = "$($user.FirstName.ToLower()).$($user.LastName.ToLower())"
    $upn         = "$sam@lab.local"
    $ouPath      = "OU=Users,OU=$($user.Department),OU=Corporate,DC=lab,DC=local"
    $displayName = "$($user.FirstName) $($user.LastName)"
    $homeFolder  = "$HomeFolderRoot\$sam"

    # Idempotency check
    if (Get-ADUser -Filter { SamAccountName -eq $sam } -ErrorAction SilentlyContinue) {
        Write-Warning "SKIPPED - $sam already exists"
        continue
    }

    try {
        # Create user
        New-ADUser `
            -Name $displayName `
            -SamAccountName $sam `
            -UserPrincipalName $upn `
            -GivenName $user.FirstName `
            -Surname $user.LastName `
            -Title $user.JobTitle `
            -Office $user.Office `
            -Path $ouPath `
            -AccountPassword $InitialPassword `
            -ChangePasswordAtLogon $true `
            -Enabled $true

        Write-Output "CREATED - $sam"

        # Add to role groups
        $groups = $user.RoleGroups -split ";"
        foreach ($group in $groups) {
            Add-ADGroupMember -Identity $group.Trim() -Members $sam
            Write-Output "  GROUP - $sam added to $($group.Trim())"
        }

        # Create home folder
        if (-not (Test-Path $homeFolder)) {
            New-Item -ItemType Directory -Path $homeFolder | Out-Null
        }

        # Set NTFS permissions on home folder
        $acl = Get-Acl $homeFolder
        $acl.SetAccessRuleProtection($true, $false)

        # Add user with Modify rights
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$sam", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($userRule)

        # Add Administrators with Full Control
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($adminRule)
        Set-Acl -Path $homeFolder -AclObject $acl

        Write-Output "  HOMEDIR - $homeFolder created"
    }
    catch {
        Write-Error "FAILED - $sam - $_"
    }
}

Stop-Transcript
