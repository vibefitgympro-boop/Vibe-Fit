$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
  Write-Host "`n== $Message ==" -ForegroundColor Cyan
}

function Read-Required([string]$Label, [string]$Hint = "") {
  while ($true) {
    if ($Hint) { Write-Host $Hint -ForegroundColor DarkGray }
    $Value = Read-Host $Label
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value.Trim() }
    Write-Host "This value is required." -ForegroundColor Yellow
  }
}

function Read-Secret([string]$Label, [string]$Hint = "") {
  while ($true) {
    if ($Hint) { Write-Host $Hint -ForegroundColor DarkGray }
    $SecureValue = Read-Host $Label -AsSecureString
    if ($SecureValue.Length -eq 0) {
      Write-Host "This value is required." -ForegroundColor Yellow
      continue
    }
    $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer) }
  }
}

function Get-GhExecutable {
  $Command = Get-Command gh -ErrorAction SilentlyContinue
  if ($Command) { return $Command.Source }
  $PossiblePaths = @(
    (Join-Path $env:ProgramFiles "GitHub CLI\gh.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\gh.exe")
  )
  foreach ($Path in $PossiblePaths) { if (Test-Path -LiteralPath $Path) { return $Path } }
  return $null
}

function Ensure-GitHubCli {
  $GhPath = Get-GhExecutable
  if ($GhPath) { return $GhPath }
  $Winget = Get-Command winget -ErrorAction SilentlyContinue
  if (-not $Winget) { throw "GitHub CLI is missing. Install it from https://cli.github.com/ and run this assistant again." }
  Write-Host "Installing GitHub CLI for secure GitHub sign-in..." -ForegroundColor Yellow
  & $Winget.Source install --id GitHub.cli --exact --source winget --accept-source-agreements --accept-package-agreements
  if ($LASTEXITCODE -ne 0) { throw "GitHub CLI could not be installed. Install it from https://cli.github.com/ and run this assistant again." }
  $GhPath = Get-GhExecutable
  if (-not $GhPath) { throw "GitHub CLI was installed. Close this window, open it again, then rerun setup-assistant.bat." }
  return $GhPath
}

function Invoke-GhSecretSet([string]$GhPath, [string]$Repository, [string]$Name, [string]$Value) {
  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo.FileName = $GhPath
  $Process.StartInfo.Arguments = "secret set $Name --repo $Repository"
  $Process.StartInfo.UseShellExecute = $false
  $Process.StartInfo.RedirectStandardInput = $true
  $Process.StartInfo.RedirectStandardOutput = $true
  $Process.StartInfo.RedirectStandardError = $true
  if (-not $Process.Start()) { throw "Could not start GitHub CLI while saving $Name." }
  $Process.StandardInput.Write($Value)
  $Process.StandardInput.Close()
  $StdOut = $Process.StandardOutput.ReadToEnd()
  $StdErr = $Process.StandardError.ReadToEnd()
  $Process.WaitForExit()
  if ($Process.ExitCode -ne 0) {
    $Details = ($StdErr + " " + $StdOut).Trim()
    if ($Details.Length -gt 300) { $Details = $Details.Substring(0, 300) }
    throw "GitHub could not save $Name. $Details"
  }
}

function Invoke-NetlifyApi([string]$Path, [string]$Method, [string]$Token, $Body = $null) {
  $Headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }
  try {
    if ($null -eq $Body) {
      return Invoke-RestMethod -Method $Method -Uri "https://api.netlify.com/api/v1$Path" -Headers $Headers
    }
    $Json = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    return Invoke-RestMethod -Method $Method -Uri "https://api.netlify.com/api/v1$Path" -Headers $Headers -ContentType "application/json" -Body $Json
  } catch {
    $Status = ""
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $Status = " (HTTP $([int]$_.Exception.Response.StatusCode))" }
    throw "Netlify request failed$Status for $Method $Path. Check that the token can manage this site and that the requested operation is valid."
  }
}

function Set-NetlifyVariables([string]$Token, [string]$SiteId, [string]$AccountId, $Variables) {
  $SiteQuery = [Uri]::EscapeDataString($SiteId)
  $AccountPath = "/accounts/$([Uri]::EscapeDataString($AccountId))/env"
  $Current = Invoke-NetlifyApi "$AccountPath`?site_id=$SiteQuery" "GET" $Token
  $Existing = @{}
  foreach ($Variable in @($Current)) { $Existing[$Variable.key] = $true }
  $ToCreate = @()

  foreach ($Variable in $Variables) {
    $Entry = @{
      key = $Variable.key
      values = @(@{ context = "all"; value = $Variable.value })
      is_secret = [bool]$Variable.secret
    }
    $EncodedKey = [Uri]::EscapeDataString($Variable.key)
    if ($Existing.ContainsKey($Variable.key)) {
      $null = Invoke-NetlifyApi "$AccountPath/$EncodedKey`?site_id=$SiteQuery" "PUT" $Token $Entry
      Write-Host "Updated Netlify variable: $($Variable.key)" -ForegroundColor Green
    } else {
      $ToCreate += $Entry
      Write-Host "Queued Netlify variable: $($Variable.key)" -ForegroundColor DarkGray
    }
  }

  if ($ToCreate.Count -gt 0) {
    $null = Invoke-NetlifyApi "$AccountPath`?site_id=$SiteQuery" "POST" $Token $ToCreate
    foreach ($Entry in $ToCreate) { Write-Host "Created Netlify variable: $($Entry.key)" -ForegroundColor Green }
  }
}

function New-SetupCode {
  $Bytes = New-Object byte[] 48
  $Random = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $Random.GetBytes($Bytes) } finally { $Random.Dispose() }
  return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

try {
  Clear-Host
  Write-Host "GYM MANAGER · First-time setup" -ForegroundColor Green
  Write-Host "This assistant puts provider credentials directly into Netlify and GitHub. It does not write secret values to this repository."
  Write-Host "Keep this window open until setup finishes. Do not share its screen while entering secrets."

  Write-Step "Supabase project"
  $SupabaseUrl = Read-Required "Supabase project URL" "Example: https://your-project-ref.supabase.co"
  $ParsedSupabaseUrl = $null
  if (-not [Uri]::TryCreate($SupabaseUrl, [UriKind]::Absolute, [ref]$ParsedSupabaseUrl) -or $ParsedSupabaseUrl.Scheme -ne "https") { throw "The Supabase project URL must start with https://." }
  $PublishableKey = Read-Required "Supabase publishable key" "This is the sb_publishable_ key from the Supabase API keys page."
  $ProjectId = Read-Required "Supabase project ID" "This is the project reference, usually the same value shown in the project URL."
  $ServiceRoleKey = Read-Secret "Supabase service-role key" "Server-only key from Supabase. It will be stored as a Netlify secret."
  $SupabaseAccessToken = Read-Secret "Supabase personal access token" "Create a Supabase access token for GitHub Actions. It will be sent only to GitHub Secrets."
  $DatabasePassword = Read-Secret "Supabase database password" "Use the password set when creating the Supabase project. It will be sent only to GitHub Secrets."

  Write-Step "Netlify site"
  $SiteId = Read-Required "Netlify site ID" "Find it in Netlify: Site configuration > General > Site details."
  $NetlifyToken = Read-Secret "Netlify personal access token" "Create a token in Netlify user settings. It is stored in this site as a server-only secret."
  $Site = Invoke-NetlifyApi "/sites/$([Uri]::EscapeDataString($SiteId))" "GET" $NetlifyToken
  $AccountId = $Site.account_id
  if (-not $AccountId -and $Site.account) { $AccountId = $Site.account.id }
  if (-not $AccountId) { $AccountId = $Site.account_slug }
  if (-not $AccountId) { throw "Could not find the Netlify account ID for this site. Verify the site ID and token." }
  $SetupToken = New-SetupCode
  $NetlifyVariables = @(
    @{ key = "SUPABASE_URL"; value = $SupabaseUrl; secret = $false },
    @{ key = "VITE_SUPABASE_URL"; value = $SupabaseUrl; secret = $false },
    @{ key = "SUPABASE_PUBLISHABLE_KEY"; value = $PublishableKey; secret = $false },
    @{ key = "VITE_SUPABASE_PUBLISHABLE_KEY"; value = $PublishableKey; secret = $false },
    @{ key = "SUPABASE_PROJECT_ID"; value = $ProjectId; secret = $false },
    @{ key = "SUPABASE_SERVICE_ROLE_KEY"; value = $ServiceRoleKey; secret = $true },
    @{ key = "SUPABASE_SETUP_TOKEN"; value = $SetupToken; secret = $true },
    @{ key = "NETLIFY_AUTH_TOKEN"; value = $NetlifyToken; secret = $true },
    @{ key = "NETLIFY_SITE_ID"; value = $SiteId; secret = $false },
    @{ key = "NETLIFY_ACCOUNT_ID"; value = $AccountId; secret = $false }
  )
  Set-NetlifyVariables $NetlifyToken $SiteId $AccountId $NetlifyVariables
  # A repository build is triggered with an empty POST. Sending JSON `{}` here
  # is rejected by Netlify's build endpoint with HTTP 422 (it expects multipart
  # form data only when uploading a ZIP).
  $null = Invoke-NetlifyApi "/sites/$([Uri]::EscapeDataString($SiteId))/builds" "POST" $NetlifyToken
  Write-Host "Netlify variables are configured and a fresh deploy was queued." -ForegroundColor Green

  Write-Step "GitHub Actions secrets"
  $Repository = Read-Required "GitHub repository" "Enter owner/repository, for example koush/GYM-MANAGEMENT."
  if ($Repository -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") { throw "Enter the GitHub repository as owner/repository." }
  $GhPath = Ensure-GitHubCli
  & $GhPath auth status --hostname github.com *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "GitHub sign-in will open a browser. Sign in with an account that administers this repository." -ForegroundColor Yellow
    & $GhPath auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw "GitHub sign-in did not finish." }
  }
  foreach ($Secret in @(
    @{ Name = "SUPABASE_ACCESS_TOKEN"; Value = $SupabaseAccessToken },
    @{ Name = "SUPABASE_PROJECT_ID"; Value = $ProjectId },
    @{ Name = "SUPABASE_DB_PASSWORD"; Value = $DatabasePassword }
  )) {
    Invoke-GhSecretSet $GhPath $Repository $Secret.Name $Secret.Value
    Write-Host "Saved GitHub Actions secret: $($Secret.Name)" -ForegroundColor Green
  }

  Write-Step "Optional: apply Supabase migrations"
  Write-Host "Choose Yes only if this Supabase project is new/blank and its schema migrations have not already been applied."
  $ApplyMigrations = Read-Host "Run the migration workflow from GitHub now? (y/N)"
  if ($ApplyMigrations -match "^(y|yes)$") {
    & $GhPath workflow run deploy-supabase-migrations.yml --repo $Repository --ref main
    if ($LASTEXITCODE -ne 0) { throw "Could not start the migration workflow. Confirm the workflow is on the main branch and GitHub Actions are enabled." }
    Write-Host "Migration workflow started. Review its run under the repository's Actions tab." -ForegroundColor Green
  } else {
    Write-Host "Skipped database migrations. Apply them later from Supabase or run the migration workflow when appropriate." -ForegroundColor Yellow
  }

  Write-Step "Complete"
  Write-Host "Setup values were sent to the selected Netlify site and GitHub repository. No credential file was created."
  Write-Host "The generated Supabase setup access code is stored only as a Netlify secret. It is not printed or committed."
  Write-Host "Netlify environment-variable updates need the queued deployment to finish before the app uses them."
  Write-Host "You can now open the Netlify site and continue with the admin registration screen."
} catch {
  Write-Host "`nSETUP STOPPED: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
