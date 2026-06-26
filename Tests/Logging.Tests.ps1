#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Lib/Logging.psm1 (Code Quality Issue 5: timestamped run log).
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\Logging.psm1') -Force
}

Describe 'Start-LabLog / Stop-LabLog' {
    AfterEach {
        Stop-LabLog
    }

    It 'creates a timestamped log file and returns its path' {
        $path = Start-LabLog -RunType 'Deploy'
        $path | Should -Exist
        $path | Should -Match 'Deploy-\d{8}-\d{6}\.log$'
    }

    It 'accepts Reset as a run type' {
        $path = Start-LabLog -RunType 'Reset'
        $path | Should -Match 'Reset-\d{8}-\d{6}\.log$'
    }

    It 'does not throw when Stop-LabLog is called with no active transcript' {
        Stop-LabLog
        { Stop-LabLog } | Should -Not -Throw
    }
}

Describe 'Write-LabLog' {
    It 'writes an INFO line without throwing' {
        { Write-LabLog 'test message' } | Should -Not -Throw
    }

    It 'writes a WARN line without throwing' {
        { Write-LabLog 'test warning' -Level 'WARN' } | Should -Not -Throw
    }

    It 'writes an ERROR line without throwing the pipeline' {
        { Write-LabLog 'test error' -Level 'ERROR' } | Should -Not -Throw
    }
}
