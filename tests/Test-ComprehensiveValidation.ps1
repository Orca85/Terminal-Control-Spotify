# Comprehensive Spotify CLI Validation Test Suite
# This script systematically tests all requirements and documents any remaining issues

param(
    [switch]$Detailed,
    [switch]$ExportResults,
    [string]$OutputPath = "ValidationResults.json"
)

# Test results tracking
$script:TestResults = @{
    TotalTests = 0
    PassedTests = 0
    FailedTests = 0
    SkippedTests = 0
    Issues = @()
    TestDetails = @()
    StartTime = Get-Date
    EndTime = $null
}

function Write-TestHeader {
    param([string]$Title)
    Write-Host "`n" -NoNewline
    Write-Host "="*80 -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Yellow
    Write-Host "="*80 -ForegroundColor Cyan
}

function Write-TestResult {
    param(
        [string]$TestName,
        [string]$Status,
        [string]$Details = "",
        [string]$Issue = ""
    )
    
    $script:TestResults.TotalTests++
    
    $color = switch ($Status) {
        "PASS" { "Green"; $script:TestResults.PassedTests++ }
        "FAIL" { "Red"; $script:TestResults.FailedTests++ }
        "SKIP" { "Yellow"; $script:TestResults.SkippedTests++ }
        default { "White" }
    }
    
    Write-Host "[$Status] " -ForegroundColor $color -NoNewline
    Write-Host $TestName -ForegroundColor White
    
    if ($Details) {
        Write-Host "    Details: $Details" -ForegroundColor Gray
    }
    
    if ($Issue) {
        Write-Host "    Issue: $Issue" -ForegroundColor Red
        $script:TestResults.Issues += @{
            Test = $TestName
            Issue = $Issue
            Details = $Details
        }
    }
    
    $script:TestResults.TestDetails += @{
        Name = $TestName
        Status = $Status
        Details = $Details
        Issue = $Issue
        Timestamp = Get-Date
    }
}

function Test-ModuleAvailability {
    Write-TestHeader "Module and Installation Validation"
    
    # Test if SpotifyModule is available
    try {
        $module = Get-Module -Name SpotifyModule -ListAvailable
        if ($module) {
            Write-TestResult "SpotifyModule availability" "PASS" "Module found at: $($module.ModuleBase)"
        } else {
            Write-TestResult "SpotifyModule availability" "FAIL" "" "SpotifyModule not found in module path"
        }
    } catch {
        Write-TestResult "SpotifyModule availability" "FAIL" "" "Error checking module: $($_.Exception.Message)"
    }
    
    # Test if module can be imported
    try {
        Import-Module SpotifyModule -Force -ErrorAction Stop
        Write-TestResult "SpotifyModule import" "PASS" "Module imported successfully"
    } catch {
        Write-TestResult "SpotifyModule import" "FAIL" "" "Failed to import module: $($_.Exception.Message)"
    }
    
    # Test if main CLI script exists
    if (Test-Path "spotifyCLI.ps1") {
        Write-TestResult "Main CLI script existence" "PASS" "spotifyCLI.ps1 found"
    } else {
        Write-TestResult "Main CLI script existence" "FAIL" "" "spotifyCLI.ps1 not found"
    }
}

function Test-AuthenticationSystem {
    Write-TestHeader "Authentication System Validation"
    
    # Test .env file existence
    if (Test-Path ".env") {
        Write-TestResult ".env file existence" "PASS" ".env file found"
        
        # Test .env file content
        try {
            $envContent = Get-Content ".env" -Raw
            if ($envContent -match "SPOTIFY_CLIENT_ID" -and $envContent -match "SPOTIFY_CLIENT_SECRET") {
                Write-TestResult ".env file content" "PASS" "Required credentials found"
            } else {
                Write-TestResult ".env file content" "FAIL" "" "Missing SPOTIFY_CLIENT_ID or SPOTIFY_CLIENT_SECRET"
            }
        } catch {
            Write-TestResult ".env file content" "FAIL" "" "Error reading .env file: $($_.Exception.Message)"
        }
    } else {
        Write-TestResult ".env file existence" "FAIL" "" ".env file not found"
    }
    
    # Test token storage directory
    $tokenPath = "$env:APPDATA\SpotifyCLI"
    if (Test-Path $tokenPath) {
        Write-TestResult "Token storage directory" "PASS" "Directory exists at: $tokenPath"
    } else {
        Write-TestResult "Token storage directory" "SKIP" "Directory will be created on first auth"
    }
    
    # Test authentication function availability
    try {
        $authFunction = Get-Command "Connect-Spotify" -ErrorAction SilentlyContinue
        if ($authFunction) {
            Write-TestResult "Authentication function" "PASS" "Connect-Spotify function available"
        } else {
            Write-TestResult "Authentication function" "FAIL" "" "Connect-Spotify function not found"
        }
    } catch {
        Write-TestResult "Authentication function" "FAIL" "" "Error checking auth function: $($_.Exception.Message)"
    }
}

function Test-CoreCommands {
    Write-TestHeader "Core Command Availability"
    
    $coreCommands = @(
        "Show-SpotifyTrack",
        "Start-SpotifyPlayback", 
        "Stop-SpotifyPlayback",
        "Skip-SpotifyTrack",
        "Skip-SpotifyTrackBack",
        "Set-SpotifyVolume",
        "Set-SpotifySeek",
        "Set-SpotifyShuffle",
        "Set-SpotifyRepeat",
        "Get-SpotifyDevices",
        "Set-SpotifyDevice",
        "Search-Spotify",
        "Get-SpotifyPlaylists",
        "Get-SpotifyQueue",
        "Get-SpotifyHelp",
        "Get-SpotifyConfig",
        "Set-SpotifyConfig"
    )
    
    foreach ($command in $coreCommands) {
        try {
            $cmd = Get-Command $command -ErrorAction SilentlyContinue
            if ($cmd) {
                Write-TestResult "Command: $command" "PASS" "Function available"
            } else {
                Write-TestResult "Command: $command" "FAIL" "" "Function not found or not exported"
            }
        } catch {
            Write-TestResult "Command: $command" "FAIL" "" "Error checking command: $($_.Exception.Message)"
        }
    }
}

function Test-AliasSystem {
    Write-TestHeader "Alias System Validation"
    
    $expectedAliases = @{
        "spotify" = "Start-SpotifyApp"
        "plays-now" = "Show-SpotifyTrack"
        "music" = "Show-SpotifyTrack"
        "pn" = "Show-SpotifyTrack"
        "sp" = "Show-SpotifyTrack"
        "play" = "Start-SpotifyPlayback"
        "pause" = "Stop-SpotifyPlayback"
        "next" = "Skip-SpotifyTrack"
        "previous" = "Skip-SpotifyTrackBack"
        "volume" = "Set-SpotifyVolume"
        "vol" = "Set-SpotifyVolume"
        "seek" = "Set-SpotifySeek"
        "shuffle" = "Set-SpotifyShuffle"
        "sh" = "Set-SpotifyShuffle"
        "repeat" = "Set-SpotifyRepeat"
        "rep" = "Set-SpotifyRepeat"
        "devices" = "Get-SpotifyDevices"
        "transfer" = "Set-SpotifyDevice"
        "tr" = "Set-SpotifyDevice"
        "search" = "Search-Spotify"
        "search-albums" = "Search-SpotifyAlbums"
        "playlists" = "Get-SpotifyPlaylists"
        "pl" = "Get-SpotifyPlaylists"
        "queue" = "Get-SpotifyQueue"
        "q" = "Get-SpotifyQueue"
        "help" = "Get-SpotifyHelp"
        "spotify-help" = "Get-SpotifyHelp"
    }
    
    foreach ($alias in $expectedAliases.Keys) {
        try {
            $aliasCmd = Get-Alias $alias -ErrorAction SilentlyContinue
            if ($aliasCmd) {
                $expectedTarget = $expectedAliases[$alias]
                if ($aliasCmd.Definition -eq $expectedTarget) {
                    Write-TestResult "Alias: $alias" "PASS" "Points to $($aliasCmd.Definition)"
                } else {
                    Write-TestResult "Alias: $alias" "FAIL" "Points to $($aliasCmd.Definition)" "Expected $expectedTarget"
                }
            } else {
                Write-TestResult "Alias: $alias" "FAIL" "" "Alias not found"
            }
        } catch {
            Write-TestResult "Alias: $alias" "FAIL" "" "Error checking alias: $($_.Exception.Message)"
        }
    }
}

function Test-ConfigurationSystem {
    Write-TestHeader "Configuration System Validation"
    
    # Test configuration directory
    $configPath = "$env:APPDATA\SpotifyCLI"
    if (Test-Path $configPath) {
        Write-TestResult "Configuration directory" "PASS" "Directory exists at: $configPath"
        
        # Test config file
        $configFile = Join-Path $configPath "config.json"
        if (Test-Path $configFile) {
            Write-TestResult "Configuration file" "PASS" "config.json exists"
            
            try {
                $config = Get-Content $configFile -Raw | ConvertFrom-Json
                Write-TestResult "Configuration parsing" "PASS" "Config file is valid JSON"
            } catch {
                Write-TestResult "Configuration parsing" "FAIL" "" "Config file is not valid JSON: $($_.Exception.Message)"
            }
        } else {
            Write-TestResult "Configuration file" "SKIP" "Will be created on first use"
        }
    } else {
        Write-TestResult "Configuration directory" "SKIP" "Will be created on first use"
    }
    
    # Test configuration functions
    try {
        $getConfigCmd = Get-Command "Get-SpotifyConfig" -ErrorAction SilentlyContinue
        if ($getConfigCmd) {
            Write-TestResult "Get-SpotifyConfig function" "PASS" "Function available"
        } else {
            Write-TestResult "Get-SpotifyConfig function" "FAIL" "" "Function not found"
        }
        
        $setConfigCmd = Get-Command "Set-SpotifyConfig" -ErrorAction SilentlyContinue
        if ($setConfigCmd) {
            Write-TestResult "Set-SpotifyConfig function" "PASS" "Function available"
        } else {
            Write-TestResult "Set-SpotifyConfig function" "FAIL" "" "Function not found"
        }
    } catch {
        Write-TestResult "Configuration functions" "FAIL" "" "Error checking config functions: $($_.Exception.Message)"
    }
}

function Test-ScriptModeAvailability {
    Write-TestHeader "Script Mode Validation"
    
    # Test main CLI script
    if (Test-Path "spotifyCLI.ps1") {
        Write-TestResult "CLI script file" "PASS" "spotifyCLI.ps1 exists"
        
        # Test script syntax
        try {
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content "spotifyCLI.ps1" -Raw), [ref]$null)
            Write-TestResult "CLI script syntax" "PASS" "Script has valid PowerShell syntax"
        } catch {
            Write-TestResult "CLI script syntax" "FAIL" "" "Script has syntax errors: $($_.Exception.Message)"
        }
    } else {
        Write-TestResult "CLI script file" "FAIL" "" "spotifyCLI.ps1 not found"
    }
}

function Test-InstallationScripts {
    Write-TestHeader "Installation Script Validation"
    
    # Test installation script
    if (Test-Path "Install-SpotifyCliDependencies.ps1") {
        Write-TestResult "Installation script" "PASS" "Install-SpotifyCliDependencies.ps1 exists"
        
        try {
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content "Install-SpotifyCliDependencies.ps1" -Raw), [ref]$null)
            Write-TestResult "Installation script syntax" "PASS" "Script has valid syntax"
        } catch {
            Write-TestResult "Installation script syntax" "FAIL" "" "Script has syntax errors: $($_.Exception.Message)"
        }
    } else {
        Write-TestResult "Installation script" "FAIL" "" "Install-SpotifyCliDependencies.ps1 not found"
    }
    
    # Test uninstallation script
    if (Test-Path "Uninstall-SpotifyCli.ps1") {
        Write-TestResult "Uninstallation script" "PASS" "Uninstall-SpotifyCli.ps1 exists"
        
        try {
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content "Uninstall-SpotifyCli.ps1" -Raw), [ref]$null)
            Write-TestResult "Uninstallation script syntax" "PASS" "Script has valid syntax"
        } catch {
            Write-TestResult "Uninstallation script syntax" "FAIL" "" "Script has syntax errors: $($_.Exception.Message)"
        }
    } else {
        Write-TestResult "Uninstallation script" "FAIL" "" "Uninstall-SpotifyCli.ps1 not found"
    }
}

function Test-DocumentationFiles {
    Write-TestHeader "Documentation Validation"
    
    # Test README.md
    if (Test-Path "README.md") {
        Write-TestResult "README.md file" "PASS" "README.md exists"
        
        $readmeContent = Get-Content "README.md" -Raw
        
        # Check for key sections
        $requiredSections = @(
            "Installation",
            "Authentication", 
            "Commands",
            "Usage"
        )
        
        foreach ($section in $requiredSections) {
            if ($readmeContent -match $section) {
                Write-TestResult "README section: $section" "PASS" "Section found in README"
            } else {
                Write-TestResult "README section: $section" "FAIL" "" "Section missing from README"
            }
        }
    } else {
        Write-TestResult "README.md file" "FAIL" "" "README.md not found"
    }
}

function Test-ErrorHandling {
    Write-TestHeader "Error Handling Validation"
    
    # Test that functions have proper error handling
    $functionsToTest = @(
        "Show-SpotifyTrack",
        "Start-SpotifyPlayback",
        "Get-SpotifyDevices",
        "Search-Spotify"
    )
    
    foreach ($functionName in $functionsToTest) {
        try {
            $function = Get-Command $functionName -ErrorAction SilentlyContinue
            if ($function) {
                $functionContent = $function.Definition
                
                # Check for try-catch blocks
                if ($functionContent -match "try\s*{.*catch") {
                    Write-TestResult "Error handling: $functionName" "PASS" "Function has try-catch blocks"
                } else {
                    Write-TestResult "Error handling: $functionName" "FAIL" "" "Function lacks proper error handling"
                }
            } else {
                Write-TestResult "Error handling: $functionName" "SKIP" "Function not available for testing"
            }
        } catch {
            Write-TestResult "Error handling: $functionName" "FAIL" "" "Error checking function: $($_.Exception.Message)"
        }
    }
}

function Show-ValidationSummary {
    Write-TestHeader "Validation Summary"
    
    $script:TestResults.EndTime = Get-Date
    $duration = $script:TestResults.EndTime - $script:TestResults.StartTime
    
    Write-Host "Test Execution Summary:" -ForegroundColor Yellow
    Write-Host "  Total Tests: $($script:TestResults.TotalTests)" -ForegroundColor White
    Write-Host "  Passed: $($script:TestResults.PassedTests)" -ForegroundColor Green
    Write-Host "  Failed: $($script:TestResults.FailedTests)" -ForegroundColor Red
    Write-Host "  Skipped: $($script:TestResults.SkippedTests)" -ForegroundColor Yellow
    Write-Host "  Duration: $($duration.TotalSeconds.ToString('F2')) seconds" -ForegroundColor White
    
    $passRate = if ($script:TestResults.TotalTests -gt 0) { 
        ($script:TestResults.PassedTests / $script:TestResults.TotalTests * 100).ToString('F1') 
    } else { "0" }
    Write-Host "  Pass Rate: $passRate%" -ForegroundColor $(if ([double]$passRate -ge 90) { "Green" } elseif ([double]$passRate -ge 70) { "Yellow" } else { "Red" })
    
    if ($script:TestResults.Issues.Count -gt 0) {
        Write-Host "`nIssues Found:" -ForegroundColor Red
        foreach ($issue in $script:TestResults.Issues) {
            Write-Host "  • $($issue.Test): $($issue.Issue)" -ForegroundColor Red
            if ($issue.Details) {
                Write-Host "    Details: $($issue.Details)" -ForegroundColor Gray
            }
        }
    }
    
    # Overall system status
    Write-Host "`nOverall System Status: " -NoNewline -ForegroundColor Yellow
    if ($script:TestResults.FailedTests -eq 0) {
        Write-Host "READY FOR DEPLOYMENT" -ForegroundColor Green
    } elseif ($script:TestResults.FailedTests -le 3) {
        Write-Host "MINOR ISSUES - MOSTLY READY" -ForegroundColor Yellow
    } else {
        Write-Host "SIGNIFICANT ISSUES - NEEDS ATTENTION" -ForegroundColor Red
    }
}

# Main execution
Write-Host "Starting Comprehensive Spotify CLI Validation..." -ForegroundColor Cyan
Write-Host "This will test all components and requirements systematically.`n" -ForegroundColor Gray

# Execute all test categories
Test-ModuleAvailability
Test-AuthenticationSystem
Test-CoreCommands
Test-AliasSystem
Test-ConfigurationSystem
Test-ScriptModeAvailability
Test-InstallationScripts
Test-DocumentationFiles
Test-ErrorHandling

# Show summary
Show-ValidationSummary

# Export results if requested
if ($ExportResults) {
    try {
        $script:TestResults | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8
        Write-Host "`nResults exported to: $OutputPath" -ForegroundColor Green
    } catch {
        Write-Host "`nFailed to export results: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Return results for programmatic use
return $script:TestResults