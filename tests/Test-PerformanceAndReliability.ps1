# Spotify CLI Performance and Reliability Testing Script
# Tests system performance, memory usage, and reliability over extended sessions

param(
    [int]$TestDurationMinutes = 5,
    [int]$OperationsPerMinute = 12,
    [switch]$DetailedOutput,
    [switch]$ExportResults,
    [string]$OutputPath = "PerformanceResults.json"
)

# Performance tracking
$script:PerformanceResults = @{
    TestConfiguration = @{
        DurationMinutes = $TestDurationMinutes
        OperationsPerMinute = $OperationsPerMinute
        StartTime = Get-Date
        EndTime = $null
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OSVersion = [System.Environment]::OSVersion.ToString()
    }
    ModuleLoadingTests = @{
        ImportTime = 0
        ImportMemoryUsage = 0
        ReImportTime = 0
        FunctionCount = 0
    }
    ApiResponseTests = @{
        AverageResponseTime = 0
        MinResponseTime = 999999
        MaxResponseTime = 0
        SuccessfulCalls = 0
        FailedCalls = 0
        TimeoutCalls = 0
        ResponseTimes = @()
    }
    MemoryUsageTests = @{
        InitialMemoryMB = 0
        PeakMemoryMB = 0
        FinalMemoryMB = 0
        MemoryLeakDetected = $false
        MemoryGrowthMB = 0
        GarbageCollections = 0
    }
    ReliabilityTests = @{
        ConsecutiveSuccesses = 0
        LongestSuccessStreak = 0
        ErrorRecoveryTime = 0
        SessionStateConsistency = $true
        ConfigurationPersistence = $true
    }
    Issues = @()
    Recommendations = @()
}

function Write-PerformanceHeader {
    param([string]$Title)
    Write-Host "`n" -NoNewline
    Write-Host "="*80 -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Yellow
    Write-Host "="*80 -ForegroundColor Cyan
}

function Write-PerformanceResult {
    param(
        [string]$TestName,
        [string]$Result,
        [string]$Details = "",
        [string]$Issue = ""
    )
    
    $color = if ($Issue) { "Red" } else { "Green" }
    $status = if ($Issue) { "ISSUE" } else { "OK" }
    
    Write-Host "[$status] " -ForegroundColor $color -NoNewline
    Write-Host $TestName -ForegroundColor White
    
    if ($Details) {
        Write-Host "    Result: $Details" -ForegroundColor Gray
    }
    
    if ($Issue) {
        Write-Host "    Issue: $Issue" -ForegroundColor Red
        $script:PerformanceResults.Issues += @{
            Test = $TestName
            Issue = $Issue
            Details = $Details
        }
    }
}

function Get-ProcessMemoryUsage {
    $process = Get-Process -Id $PID
    return [Math]::Round($process.WorkingSet64 / 1MB, 2)
}

function Test-ModuleLoadingPerformance {
    Write-PerformanceHeader "Module Loading Performance Tests"
    
    # Test initial memory usage
    $initialMemory = Get-ProcessMemoryUsage
    $script:PerformanceResults.MemoryUsageTests.InitialMemoryMB = $initialMemory
    Write-PerformanceResult "Initial memory usage" "$initialMemory MB"
    
    # Test module import time
    $importStart = Get-Date
    try {
        Import-Module .\SpotifyModule.psm1 -Force -ErrorAction Stop
        $importEnd = Get-Date
        $importTime = ($importEnd - $importStart).TotalMilliseconds
        $script:PerformanceResults.ModuleLoadingTests.ImportTime = $importTime
        
        if ($importTime -lt 1000) {
            Write-PerformanceResult "Module import time" "$([Math]::Round($importTime, 2)) ms"
        } elseif ($importTime -lt 3000) {
            Write-PerformanceResult "Module import time" "$([Math]::Round($importTime, 2)) ms" "" "Import time is slow (>1s)"
        } else {
            Write-PerformanceResult "Module import time" "$([Math]::Round($importTime, 2)) ms" "" "Import time is very slow (>3s)"
        }
        
        # Test memory usage after import
        $postImportMemory = Get-ProcessMemoryUsage
        $importMemoryUsage = $postImportMemory - $initialMemory
        $script:PerformanceResults.ModuleLoadingTests.ImportMemoryUsage = $importMemoryUsage
        
        if ($importMemoryUsage -lt 10) {
            Write-PerformanceResult "Module memory usage" "$importMemoryUsage MB"
        } elseif ($importMemoryUsage -lt 25) {
            Write-PerformanceResult "Module memory usage" "$importMemoryUsage MB" "" "High memory usage for module import"
        } else {
            Write-PerformanceResult "Module memory usage" "$importMemoryUsage MB" "" "Very high memory usage for module import"
        }
        
        # Count available functions
        $functions = Get-Command -Module SpotifyModule
        $functionCount = $functions.Count
        $script:PerformanceResults.ModuleLoadingTests.FunctionCount = $functionCount
        Write-PerformanceResult "Available functions" "$functionCount functions exported"
        
        # Test re-import time (should be faster due to caching)
        $reImportStart = Get-Date
        Import-Module .\SpotifyModule.psm1 -Force -ErrorAction Stop
        $reImportEnd = Get-Date
        $reImportTime = ($reImportEnd - $reImportStart).TotalMilliseconds
        $script:PerformanceResults.ModuleLoadingTests.ReImportTime = $reImportTime
        
        if ($reImportTime -lt $importTime) {
            Write-PerformanceResult "Module re-import time" "$([Math]::Round($reImportTime, 2)) ms (faster than initial)"
        } else {
            Write-PerformanceResult "Module re-import time" "$([Math]::Round($reImportTime, 2)) ms" "" "Re-import not optimized"
        }
        
    } catch {
        Write-PerformanceResult "Module import" "FAILED" "" "Could not import module: $($_.Exception.Message)"
        return $false
    }
    
    return $true
}

function Test-ApiResponsePerformance {
    Write-PerformanceHeader "API Response Performance Tests"
    
    # Test basic API calls that don't require authentication
    $testCalls = @(
        @{ Name = "Show current track"; Command = "Show-SpotifyTrack" },
        @{ Name = "Get help"; Command = "Get-SpotifyHelp" },
        @{ Name = "Get configuration"; Command = "Get-SpotifyConfig" }
    )
    
    $responseTimes = @()
    $successCount = 0
    $failCount = 0
    
    foreach ($test in $testCalls) {
        try {
            $startTime = Get-Date
            
            # Execute the command with timeout
            $job = Start-Job -ScriptBlock {
                param($Command)
                try {
                    & $Command 2>&1 | Out-Null
                    return "SUCCESS"
                } catch {
                    return "ERROR: $($_.Exception.Message)"
                }
            } -ArgumentList $test.Command
            
            # Wait for job with timeout
            $completed = Wait-Job $job -Timeout 10
            $endTime = Get-Date
            $responseTime = ($endTime - $startTime).TotalMilliseconds
            
            if ($completed) {
                $result = Receive-Job $job
                Remove-Job $job
                
                if ($result -eq "SUCCESS") {
                    $responseTimes += $responseTime
                    $successCount++
                    
                    if ($responseTime -lt 500) {
                        Write-PerformanceResult $test.Name "$([Math]::Round($responseTime, 2)) ms"
                    } elseif ($responseTime -lt 2000) {
                        Write-PerformanceResult $test.Name "$([Math]::Round($responseTime, 2)) ms" "" "Slow response time"
                    } else {
                        Write-PerformanceResult $test.Name "$([Math]::Round($responseTime, 2)) ms" "" "Very slow response time"
                    }
                } else {
                    $failCount++
                    Write-PerformanceResult $test.Name "FAILED" "" $result
                }
            } else {
                Remove-Job $job -Force
                $failCount++
                $script:PerformanceResults.ApiResponseTests.TimeoutCalls++
                Write-PerformanceResult $test.Name "TIMEOUT" "" "Command timed out after 10 seconds"
            }
            
        } catch {
            $failCount++
            Write-PerformanceResult $test.Name "ERROR" "" $_.Exception.Message
        }
    }
    
    # Calculate statistics
    if ($responseTimes.Count -gt 0) {
        $avgResponse = ($responseTimes | Measure-Object -Average).Average
        $minResponse = ($responseTimes | Measure-Object -Minimum).Minimum
        $maxResponse = ($responseTimes | Measure-Object -Maximum).Maximum
        
        $script:PerformanceResults.ApiResponseTests.AverageResponseTime = $avgResponse
        $script:PerformanceResults.ApiResponseTests.MinResponseTime = $minResponse
        $script:PerformanceResults.ApiResponseTests.MaxResponseTime = $maxResponse
        $script:PerformanceResults.ApiResponseTests.ResponseTimes = $responseTimes
        
        Write-PerformanceResult "Average response time" "$([Math]::Round($avgResponse, 2)) ms"
        Write-PerformanceResult "Response time range" "$([Math]::Round($minResponse, 2)) - $([Math]::Round($maxResponse, 2)) ms"
    }
    
    $script:PerformanceResults.ApiResponseTests.SuccessfulCalls = $successCount
    $script:PerformanceResults.ApiResponseTests.FailedCalls = $failCount
    
    $successRate = if (($successCount + $failCount) -gt 0) { 
        ($successCount / ($successCount + $failCount) * 100) 
    } else { 0 }
    
    if ($successRate -eq 100) {
        Write-PerformanceResult "API call success rate" "$([Math]::Round($successRate, 1))%"
    } elseif ($successRate -ge 80) {
        Write-PerformanceResult "API call success rate" "$([Math]::Round($successRate, 1))%" "" "Some API calls failed"
    } else {
        Write-PerformanceResult "API call success rate" "$([Math]::Round($successRate, 1))%" "" "High API failure rate"
    }
}

function Test-MemoryUsageOverTime {
    Write-PerformanceHeader "Memory Usage and Resource Cleanup Tests"
    
    $initialMemory = Get-ProcessMemoryUsage
    $peakMemory = $initialMemory
    $memoryReadings = @()
    
    Write-Host "Testing memory usage over $TestDurationMinutes minutes..." -ForegroundColor Cyan
    Write-Host "Performing operations every $([Math]::Round(60/$OperationsPerMinute, 1)) seconds" -ForegroundColor Gray
    
    $testStart = Get-Date
    $testEnd = $testStart.AddMinutes($TestDurationMinutes)
    $operationInterval = [TimeSpan]::FromSeconds(60 / $OperationsPerMinute)
    $nextOperation = $testStart
    $operationCount = 0
    
    while ((Get-Date) -lt $testEnd) {
        $currentTime = Get-Date
        
        # Perform operation if it's time
        if ($currentTime -ge $nextOperation) {
            try {
                # Simulate typical user operations
                $operations = @(
                    { Get-SpotifyConfig | Out-Null },
                    { Show-SpotifyTrack | Out-Null },
                    { Get-SpotifyHelp | Out-Null }
                )
                
                $operation = $operations[$operationCount % $operations.Count]
                & $operation
                
                $operationCount++
                $nextOperation = $nextOperation.Add($operationInterval)
                
                if ($DetailedOutput) {
                    Write-Host "." -NoNewline -ForegroundColor Green
                }
            } catch {
                if ($DetailedOutput) {
                    Write-Host "x" -NoNewline -ForegroundColor Red
                }
            }
        }
        
        # Record memory usage
        $currentMemory = Get-ProcessMemoryUsage
        $memoryReadings += @{
            Time = $currentTime
            MemoryMB = $currentMemory
        }
        
        if ($currentMemory -gt $peakMemory) {
            $peakMemory = $currentMemory
        }
        
        Start-Sleep -Milliseconds 500
    }
    
    if ($DetailedOutput) {
        Write-Host ""
    }
    
    $finalMemory = Get-ProcessMemoryUsage
    $memoryGrowth = $finalMemory - $initialMemory
    
    $script:PerformanceResults.MemoryUsageTests.PeakMemoryMB = $peakMemory
    $script:PerformanceResults.MemoryUsageTests.FinalMemoryMB = $finalMemory
    $script:PerformanceResults.MemoryUsageTests.MemoryGrowthMB = $memoryGrowth
    
    Write-PerformanceResult "Operations completed" "$operationCount operations"
    Write-PerformanceResult "Peak memory usage" "$peakMemory MB"
    Write-PerformanceResult "Final memory usage" "$finalMemory MB"
    
    if ($memoryGrowth -lt 5) {
        Write-PerformanceResult "Memory growth" "$([Math]::Round($memoryGrowth, 2)) MB"
    } elseif ($memoryGrowth -lt 15) {
        Write-PerformanceResult "Memory growth" "$([Math]::Round($memoryGrowth, 2)) MB" "" "Moderate memory growth detected"
    } else {
        Write-PerformanceResult "Memory growth" "$([Math]::Round($memoryGrowth, 2)) MB" "" "Significant memory growth - possible leak"
        $script:PerformanceResults.MemoryUsageTests.MemoryLeakDetected = $true
    }
    
    # Force garbage collection and test cleanup
    $preGCMemory = Get-ProcessMemoryUsage
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
    Start-Sleep -Seconds 1
    $postGCMemory = Get-ProcessMemoryUsage
    $gcReclaimed = $preGCMemory - $postGCMemory
    
    $script:PerformanceResults.MemoryUsageTests.GarbageCollections++
    
    if ($gcReclaimed -gt 1) {
        Write-PerformanceResult "Garbage collection" "Reclaimed $([Math]::Round($gcReclaimed, 2)) MB"
    } else {
        Write-PerformanceResult "Garbage collection" "Minimal cleanup ($([Math]::Round($gcReclaimed, 2)) MB)"
    }
}

function Test-ReliabilityAndConsistency {
    Write-PerformanceHeader "Reliability and Consistency Tests"
    
    # Test configuration persistence
    try {
        $originalConfig = Get-SpotifyConfig
        $testConfig = $originalConfig.Clone()
        $testConfig.CompactMode = -not $testConfig.CompactMode
        
        Set-SpotifyConfig $testConfig | Out-Null
        $retrievedConfig = Get-SpotifyConfig
        
        if ($retrievedConfig.CompactMode -eq $testConfig.CompactMode) {
            Write-PerformanceResult "Configuration persistence" "Settings saved and retrieved correctly"
        } else {
            Write-PerformanceResult "Configuration persistence" "FAILED" "" "Configuration changes not persisted"
            $script:PerformanceResults.ReliabilityTests.ConfigurationPersistence = $false
        }
        
        # Restore original config
        Set-SpotifyConfig $originalConfig | Out-Null
        
    } catch {
        Write-PerformanceResult "Configuration persistence" "ERROR" "" $_.Exception.Message
        $script:PerformanceResults.ReliabilityTests.ConfigurationPersistence = $false
    }
    
    # Test session state consistency
    try {
        # Test that session variables are properly managed
        $sessionVars = Get-Variable -Scope Script -Name "Session*" -ErrorAction SilentlyContinue
        if ($sessionVars) {
            Write-PerformanceResult "Session state management" "$($sessionVars.Count) session variables found"
        } else {
            Write-PerformanceResult "Session state management" "No session variables detected"
        }
    } catch {
        Write-PerformanceResult "Session state management" "ERROR" "" $_.Exception.Message
        $script:PerformanceResults.ReliabilityTests.SessionStateConsistency = $false
    }
    
    # Test error recovery
    try {
        $errorRecoveryStart = Get-Date
        
        # Simulate an error condition and recovery
        try {
            # This should fail gracefully
            Invoke-SpotifyApi -Method GET -Path "/invalid/endpoint" -ErrorAction Stop
        } catch {
            # Expected to fail - test if system recovers
        }
        
        # Test if system still works after error
        Get-SpotifyConfig | Out-Null
        
        $errorRecoveryEnd = Get-Date
        $recoveryTime = ($errorRecoveryEnd - $errorRecoveryStart).TotalMilliseconds
        $script:PerformanceResults.ReliabilityTests.ErrorRecoveryTime = $recoveryTime
        
        Write-PerformanceResult "Error recovery" "System recovered in $([Math]::Round($recoveryTime, 2)) ms"
        
    } catch {
        Write-PerformanceResult "Error recovery" "FAILED" "" "System did not recover from error: $($_.Exception.Message)"
    }
}

function Show-PerformanceSummary {
    Write-PerformanceHeader "Performance Test Summary"
    
    $script:PerformanceResults.TestConfiguration.EndTime = Get-Date
    $totalDuration = $script:PerformanceResults.TestConfiguration.EndTime - $script:PerformanceResults.TestConfiguration.StartTime
    
    Write-Host "Test Configuration:" -ForegroundColor Yellow
    Write-Host "  Duration: $($totalDuration.TotalMinutes.ToString('F1')) minutes" -ForegroundColor White
    Write-Host "  PowerShell: $($script:PerformanceResults.TestConfiguration.PowerShellVersion)" -ForegroundColor White
    Write-Host "  OS: $($script:PerformanceResults.TestConfiguration.OSVersion)" -ForegroundColor White
    
    Write-Host "`nPerformance Metrics:" -ForegroundColor Yellow
    Write-Host "  Module Import: $($script:PerformanceResults.ModuleLoadingTests.ImportTime.ToString('F0')) ms" -ForegroundColor White
    Write-Host "  Functions Available: $($script:PerformanceResults.ModuleLoadingTests.FunctionCount)" -ForegroundColor White
    Write-Host "  Memory Growth: $($script:PerformanceResults.MemoryUsageTests.MemoryGrowthMB.ToString('F1')) MB" -ForegroundColor White
    Write-Host "  Peak Memory: $($script:PerformanceResults.MemoryUsageTests.PeakMemoryMB.ToString('F1')) MB" -ForegroundColor White
    
    if ($script:PerformanceResults.ApiResponseTests.ResponseTimes.Count -gt 0) {
        Write-Host "  Avg Response Time: $($script:PerformanceResults.ApiResponseTests.AverageResponseTime.ToString('F0')) ms" -ForegroundColor White
        Write-Host "  API Success Rate: $((($script:PerformanceResults.ApiResponseTests.SuccessfulCalls / ($script:PerformanceResults.ApiResponseTests.SuccessfulCalls + $script:PerformanceResults.ApiResponseTests.FailedCalls)) * 100).ToString('F1'))%" -ForegroundColor White
    }
    
    # Overall performance rating
    $performanceScore = 100
    
    if ($script:PerformanceResults.ModuleLoadingTests.ImportTime -gt 3000) { $performanceScore -= 20 }
    elseif ($script:PerformanceResults.ModuleLoadingTests.ImportTime -gt 1000) { $performanceScore -= 10 }
    
    if ($script:PerformanceResults.MemoryUsageTests.MemoryGrowthMB -gt 15) { $performanceScore -= 25 }
    elseif ($script:PerformanceResults.MemoryUsageTests.MemoryGrowthMB -gt 5) { $performanceScore -= 10 }
    
    if ($script:PerformanceResults.ApiResponseTests.AverageResponseTime -gt 2000) { $performanceScore -= 20 }
    elseif ($script:PerformanceResults.ApiResponseTests.AverageResponseTime -gt 500) { $performanceScore -= 10 }
    
    if (-not $script:PerformanceResults.ReliabilityTests.ConfigurationPersistence) { $performanceScore -= 15 }
    if (-not $script:PerformanceResults.ReliabilityTests.SessionStateConsistency) { $performanceScore -= 10 }
    
    Write-Host "`nOverall Performance Score: " -NoNewline -ForegroundColor Yellow
    $scoreColor = if ($performanceScore -ge 90) { "Green" } elseif ($performanceScore -ge 70) { "Yellow" } else { "Red" }
    Write-Host "$performanceScore/100" -ForegroundColor $scoreColor
    
    # Recommendations
    if ($script:PerformanceResults.Issues.Count -gt 0) {
        Write-Host "`nIssues Found:" -ForegroundColor Red
        foreach ($issue in $script:PerformanceResults.Issues) {
            Write-Host "  • $($issue.Test): $($issue.Issue)" -ForegroundColor Red
        }
    }
    
    # Generate recommendations
    $recommendations = @()
    
    if ($script:PerformanceResults.ModuleLoadingTests.ImportTime -gt 1000) {
        $recommendations += "Consider optimizing module loading by reducing function count or using lazy loading"
    }
    
    if ($script:PerformanceResults.MemoryUsageTests.MemoryLeakDetected) {
        $recommendations += "Investigate potential memory leaks in session variable management"
    }
    
    if ($script:PerformanceResults.ApiResponseTests.FailedCalls -gt 0) {
        $recommendations += "Improve error handling and retry logic for API calls"
    }
    
    if ($recommendations.Count -gt 0) {
        Write-Host "`nRecommendations:" -ForegroundColor Cyan
        foreach ($rec in $recommendations) {
            Write-Host "  • $rec" -ForegroundColor White
        }
        $script:PerformanceResults.Recommendations = $recommendations
    }
}

# Main execution
Write-Host "Starting Spotify CLI Performance and Reliability Testing..." -ForegroundColor Cyan
Write-Host "Test Duration: $TestDurationMinutes minutes" -ForegroundColor Gray
Write-Host "Operations per minute: $OperationsPerMinute" -ForegroundColor Gray

# Execute all test categories
$moduleLoaded = Test-ModuleLoadingPerformance
if ($moduleLoaded) {
    Test-ApiResponsePerformance
    Test-MemoryUsageOverTime
    Test-ReliabilityAndConsistency
} else {
    Write-Host "Skipping remaining tests due to module loading failure" -ForegroundColor Red
}

# Show summary
Show-PerformanceSummary

# Export results if requested
if ($ExportResults) {
    try {
        $script:PerformanceResults | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding UTF8
        Write-Host "`nResults exported to: $OutputPath" -ForegroundColor Green
    } catch {
        Write-Host "`nFailed to export results: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Return results for programmatic use
return $script:PerformanceResults