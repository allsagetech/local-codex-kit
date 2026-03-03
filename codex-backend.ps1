function Get-LmsCommand {
    $env:PATH = 'C:\Users\allsage\.lmstudio\bin;' + $env:PATH
    return Get-Command lms -ErrorAction SilentlyContinue
}

function Get-CodexCommand {
    $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)

    foreach ($command in $commands) {
        if ($command.CommandType -eq 'Application') {
            return $command
        }
    }

    foreach ($command in $commands) {
        if ($command.CommandType -eq 'ExternalScript') {
            return $command
        }
    }

    return $commands | Select-Object -First 1
}

function Get-CommandExecutionPath {
    param(
        [System.Management.Automation.CommandInfo]$Command
    )

    if (-not $Command) {
        return $null
    }

    if ($Command.Path) {
        return $Command.Path
    }

    return $Command.Source
}

function Test-GitRepo {
    param([string]$Path)

    $git = Get-GitCommand
    if (-not $git) {
        return $false
    }

    Push-Location $Path
    try {
        return Test-GitWorkTree -GitCommand $git
    } finally {
        Pop-Location
    }
}

function Get-GitCommand {
    return Get-Command git -ErrorAction SilentlyContinue
}

function Get-TempPath {
    $tempPath = [System.IO.Path]::GetTempPath()
    if ([string]::IsNullOrWhiteSpace($tempPath)) {
        throw 'Could not determine a temporary directory.'
    }
    return $tempPath
}

function Test-GitWorkTree {
    param(
        [System.Management.Automation.CommandInfo]$GitCommand
    )

    if (-not $GitCommand) {
        return $false
    }

    $tempPath = Get-TempPath
    $stdout = Join-Path $tempPath ([Guid]::NewGuid().ToString() + '.out')
    $stderr = Join-Path $tempPath ([Guid]::NewGuid().ToString() + '.err')
    try {
        $proc = Start-Process -FilePath $GitCommand.Source -ArgumentList @('rev-parse', '--is-inside-work-tree') -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        return $proc.ExitCode -eq 0
    } finally {
        Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-GitStatusLine {
    param(
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $entry = [string]$Line
    $indexStatus = if ($entry.Length -ge 1) { $entry.Substring(0, 1) } else { ' ' }
    $worktreeStatus = if ($entry.Length -ge 2) { $entry.Substring(1, 1) } else { ' ' }
    $rawPath = if ($entry.Length -gt 3) { $entry.Substring(3).Trim() } else { $entry.Trim() }
    $originalPath = $null
    $resolvedPath = $rawPath
    $kind = 'modified'

    if ($rawPath -match '^(?<from>.+?) -> (?<to>.+)$') {
        $originalPath = $Matches['from']
        $resolvedPath = $Matches['to']
    }

    $statusCode = ($entry.Substring(0, [Math]::Min(2, $entry.Length))).Trim()
    if ($statusCode -match 'R') {
        $kind = 'rename'
    } elseif ($statusCode -match 'C') {
        $kind = 'copy'
    } elseif ($statusCode -eq '??') {
        $kind = 'untracked'
    } elseif ($statusCode -match 'D') {
        $kind = 'deleted'
    }

    return [pscustomobject]@{
        key = if ($originalPath) { "$originalPath->$resolvedPath" } else { $resolvedPath }
        code = $statusCode
        path = $resolvedPath
        originalPath = $originalPath
        kind = $kind
        indexStatus = $indexStatus
        worktreeStatus = $worktreeStatus
    }
}

function Get-ModeFromPrompt {
    param([string]$TaskText)

    if ([string]::IsNullOrWhiteSpace($TaskText)) {
        return 'local-balanced'
    }

    $normalized = $TaskText.ToLowerInvariant()
    $wordCount = ($TaskText -split '\s+' | Where-Object { $_ }).Count
    if ($normalized -match 'bug|fix|test|failing|stack trace|compile|lint|refactor|function|class|api|query|sql|regex|script|typescript|javascript|python|rust|go|c#|java') {
        return 'local-coder'
    }

    return 'local-balanced'
}

function Get-CodexPromptText {
    param(
        [string]$ScriptRoot,
        [string]$ExtraPrompt,
        [bool]$NoPreamble
    )

    $prompt = ''
    if (-not $NoPreamble) {
        $promptPath = Join-Path $ScriptRoot 'codex-prompt.md'
        if (Test-Path -Path $promptPath -PathType Leaf) {
            $prompt = (Get-Content -Path $promptPath -Raw).Trim()
        }
    }
    if ($ExtraPrompt) {
        if ($prompt) {
            $prompt += "`n`nUser task:`n$ExtraPrompt"
        } else {
            $prompt = $ExtraPrompt
        }
    }
    return $prompt
}

function Resolve-CodexMode {
    param(
        [ValidateSet('local-balanced', 'local-coder', 'local-small', 'local-llvm', 'auto')]
        [string]$Mode,
        [string]$ExtraPrompt
    )

    if ($Mode -eq 'auto') {
        return (Get-ModeFromPrompt -TaskText $ExtraPrompt)
    }
    return $Mode
}

function Get-CodexLaunchSpec {
    param(
        [string]$ScriptRoot,
        [ValidateSet('local-balanced', 'local-coder', 'local-small', 'local-llvm', 'auto')]
        [string]$Mode,
        [string]$ExtraPrompt,
        [bool]$NoPreamble,
        [string]$WorkingDirectory,
        [bool]$UseToolchain,
        [bool]$SkipRepoCheck
    )

    $resolvedMode = Resolve-CodexMode -Mode $Mode -ExtraPrompt $ExtraPrompt
    $codex = Get-CodexCommand
    if ((-not $codex) -and (-not $UseToolchain)) {
        throw "Codex CLI ('codex') was not found in PATH."
    }

    $prompt = Get-CodexPromptText -ScriptRoot $ScriptRoot -ExtraPrompt $ExtraPrompt -NoPreamble $NoPreamble

    $provider = 'lmstudio'
    $model = 'gpt-oss-20b'
    $displayModel = 'Local GPT OSS 20B'
    $metadataNote = 'Codex CLI should recognize this OSS model slug.'
    $localModelKey = 'openai/gpt-oss-20b'
    $localIdentifier = $model
    $contextLength = 24576
    $localBaseUrl = $null
    $localApiKeyEnv = $null
    $localWireApi = $null
    $args = @()

    switch ($resolvedMode) {
        'local-balanced' {
            $args += @('--oss', '--local-provider', 'lmstudio', '-m', $model)
        }
        'local-coder' {
            $provider = 'lmstudio'
            $model = 'qwen2.5-coder-32b'
            $displayModel = 'Local Qwen 2.5 Coder 32B'
            $localModelKey = 'qwen2.5-coder-32b-instruct'
            $localIdentifier = $model
            $contextLength = 16384
            $metadataNote = 'Codex CLI fallback metadata is expected for this local alias.'
            $args += @('--oss', '--local-provider', 'lmstudio', '-m', $model)
        }
        'local-small' {
            $provider = 'lmstudio'
            $model = 'qwen2.5-coder-7b'
            $displayModel = 'Local Qwen 2.5 Coder 7B'
            $localModelKey = 'qwen2.5-coder-7b-instruct'
            $localIdentifier = $model
            $contextLength = 8192
            $metadataNote = 'Codex CLI fallback metadata is expected for this local alias.'
            $args += @('--oss', '--local-provider', 'lmstudio', '-m', $model)
        }
        'local-llvm' {
            $provider = 'llvm'
            $model = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLVM_MODEL)) { 'llama3' } else { $env:LOCAL_CODEX_LLVM_MODEL }
            $displayModel = 'Local LLVM/vLLM Server'
            $metadataNote = 'Codex CLI fallback metadata is expected for this custom local provider.'
            $localModelKey = $null
            $localIdentifier = $null
            $contextLength = 32768
            $localBaseUrl = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLVM_BASE_URL)) { 'http://127.0.0.1:8000/v1' } else { $env:LOCAL_CODEX_LLVM_BASE_URL }
            $localApiKeyEnv = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLVM_API_KEY_ENV)) { 'LOCAL_CODEX_LLVM_API_KEY' } else { $env:LOCAL_CODEX_LLVM_API_KEY_ENV }
            $localWireApi = if ([string]::IsNullOrWhiteSpace($env:LOCAL_CODEX_LLVM_WIRE_API)) { 'responses' } else { $env:LOCAL_CODEX_LLVM_WIRE_API }

            if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($localApiKeyEnv, 'Process'))) {
                Set-Item -Path ("Env:{0}" -f $localApiKeyEnv) -Value 'local'
            }

            $providerName = 'LLVM Local'
            $escapedProviderName = $providerName.Replace("'", "''")
            $escapedBaseUrl = $localBaseUrl.Replace("'", "''")
            $escapedApiKeyEnv = $localApiKeyEnv.Replace("'", "''")
            $escapedWireApi = $localWireApi.Replace("'", "''")

            $args += @(
                '-c', "model_provider=llvm",
                '-c', ("model_providers.llvm.name='{0}'" -f $escapedProviderName),
                '-c', ("model_providers.llvm.base_url='{0}'" -f $escapedBaseUrl),
                '-c', ("model_providers.llvm.env_key='{0}'" -f $escapedApiKeyEnv),
                '-c', ("model_providers.llvm.wire_api='{0}'" -f $escapedWireApi),
                '-m', $model
            )
        }
    }

    $args += @('--sandbox', 'workspace-write', '-a', 'on-request', '-C', $WorkingDirectory)
    if ($prompt) {
        $args += $prompt
    }

    return [pscustomobject]@{
        requestedMode = $Mode
        resolvedMode = $resolvedMode
        provider = $provider
        model = $model
        displayModel = $displayModel
        metadataNote = $metadataNote
        localModelKey = $localModelKey
        localIdentifier = $localIdentifier
        localBaseUrl = $localBaseUrl
        localApiKeyEnv = $localApiKeyEnv
        localWireApi = $localWireApi
        contextLength = $contextLength
        workingDirectory = $WorkingDirectory
        useToolchain = $UseToolchain
        skipRepoCheck = $SkipRepoCheck
        isGitRepo = (Test-GitRepo -Path $WorkingDirectory)
        prompt = $prompt
        codexPath = if ($codex) { (Get-CommandExecutionPath -Command $codex) } else { $null }
        args = $args
    }
}

function Ensure-LocalModel {
    param(
        [string]$ModelKey,
        [string]$Identifier,
        [int]$ContextLength
    )

    $lms = Get-LmsCommand
    if (-not $lms) {
        throw "LM Studio CLI ('lms') was not found. Install LM Studio first."
    }

    $tempPath = Get-TempPath
    $stdout = Join-Path $tempPath 'lms-server-start.out'
    $stderr = Join-Path $tempPath 'lms-server-start.err'
    $proc = Start-Process -FilePath $lms.Source -ArgumentList @('server', 'start', '--port', '1234') -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($proc.ExitCode -ne 0) {
        $errText = ''
        if (Test-Path $stderr) {
            $errText = Get-Content $stderr -Raw
        }
        if ($errText -notmatch 'running on port 1234') {
            throw "LM Studio server start failed: $errText"
        }
    }

    $unloadResult = Invoke-ExternalCapture -FilePath $lms.Source -ArgumentList @('unload', '--all')
    if ($unloadResult.ExitCode -ne 0) {
        throw "LM Studio unload failed: $($unloadResult.Combined.Trim())"
    }

    $loadResult = Invoke-ExternalCapture -FilePath $lms.Source -ArgumentList @('load', $ModelKey, '--gpu', 'max', '-c', $ContextLength, '--identifier', $Identifier, '-y')
    if ($loadResult.ExitCode -ne 0) {
        throw "LM Studio model load failed: $($loadResult.Combined.Trim())"
    }
    if ($loadResult.Combined) {
        $loadResult.Combined.Trim() | Out-Host
    }
}

function Invoke-ExternalCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $tempPath = Get-TempPath
    $stdout = Join-Path $tempPath ([Guid]::NewGuid().ToString() + '.out')
    $stderr = Join-Path $tempPath ([Guid]::NewGuid().ToString() + '.err')
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $outText = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { '' }
        $errText = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut = $outText
            StdErr = $errText
            Combined = (($outText, $errText) -join "`n").Trim()
        }
    } finally {
        Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-CodexStatus {
    $codex = Get-CodexCommand
    $lms = Get-LmsCommand
    $toolchainModule = Get-Module -ListAvailable Toolchain | Sort-Object Version -Descending | Select-Object -First 1

    $loadedModels = @()
    $catalogModels = @()
    $serverRunning = $false
    $serverPort = $null

    if ($lms) {
        $serverStatus = Invoke-ExternalCapture -FilePath $lms.Source -ArgumentList @('server', 'status')
        $serverRunning = ($serverStatus.Combined -match 'running on port')
        if ($serverStatus.Combined -match 'port\s+(\d+)') {
            $serverPort = [int]$Matches[1]
        }

        $loaded = Invoke-ExternalCapture -FilePath $lms.Source -ArgumentList @('ps')
        if ($loaded.Combined) { $loadedModels = @($loaded.Combined -split "`r?`n") }

        $catalog = Invoke-ExternalCapture -FilePath $lms.Source -ArgumentList @('ls')
        if ($catalog.Combined) { $catalogModels = @($catalog.Combined -split "`r?`n") }
    }

    $authText = ''
    if ($codex) {
        $codexPath = Get-CommandExecutionPath -Command $codex
        try { $authText = (& $codexPath login status 2>&1 | Out-String).Trim() } catch { }
    }

    return [pscustomobject]@{
        codex = [pscustomobject]@{
            found = [bool]$codex
            path = if ($codex) { (Get-CommandExecutionPath -Command $codex) } else { $null }
            auth = $authText
        }
        lmstudio = [pscustomobject]@{
            found = [bool]$lms
            path = if ($lms) { $lms.Source } else { $null }
            serverRunning = $serverRunning
            serverPort = $serverPort
            loadedModelsText = ($loadedModels -join "`n")
            catalogText = ($catalogModels -join "`n")
        }
        toolchain = [pscustomobject]@{
            installed = [bool]$toolchainModule
            version = if ($toolchainModule) { [string]$toolchainModule.Version } else { $null }
        }
    }
}

function Get-GitContext {
    param(
        [string]$Path
    )

    $git = Get-GitCommand
    if (-not $git) {
        return [pscustomobject]@{
            isGitRepo = $false
            branch = $null
            aheadBehind = ''
            changedFiles = @()
            stagedCount = 0
            unstagedCount = 0
            untrackedCount = 0
            diffStat = ''
            diffExcerpt = ''
        }
    }

    Push-Location $Path
    try {
        if (-not (Test-GitWorkTree -GitCommand $git)) {
            return [pscustomobject]@{
                isGitRepo = $false
                branch = $null
                aheadBehind = ''
                changedFiles = @()
                stagedCount = 0
                unstagedCount = 0
                untrackedCount = 0
                diffStat = ''
                diffExcerpt = ''
            }
        }

        $branch = (& $git.Source branch --show-current 2>$null | Out-String).Trim()
        $aheadBehind = (& $git.Source status --short --branch 2>$null | Select-Object -First 1 | Out-String).Trim()
        $statusLines = @(& $git.Source status --short 2>$null)
        $changedFiles = @()
        $stagedCount = 0
        $unstagedCount = 0
        $untrackedCount = 0

        foreach ($line in $statusLines) {
            $parsed = ConvertFrom-GitStatusLine -Line $line
            if (-not $parsed) {
                continue
            }

            if ($parsed.indexStatus -ne ' ' -and $parsed.indexStatus -ne '?') {
                $stagedCount++
            }
            if ($parsed.worktreeStatus -ne ' ' -and $parsed.worktreeStatus -ne '?') {
                $unstagedCount++
            }
            if ($parsed.indexStatus -eq '?' -or $parsed.worktreeStatus -eq '?') {
                $untrackedCount++
            }

            $changedFiles += [pscustomobject]@{
                key = $parsed.key
                code = $parsed.code
                path = $parsed.path
                originalPath = $parsed.originalPath
                kind = $parsed.kind
            }
        }

        $diffStat = (& $git.Source diff --stat --no-ext-diff 2>$null | Out-String).Trim()
        $diffText = (& $git.Source diff --no-ext-diff 2>$null | Out-String)
        $excerptLines = @($diffText -split "`r?`n" | Select-Object -First 120)

        return [pscustomobject]@{
            isGitRepo = $true
            branch = if ($branch) { $branch } else { '(detached)' }
            aheadBehind = $aheadBehind
            changedFiles = @($changedFiles | Select-Object -First 20)
            stagedCount = $stagedCount
            unstagedCount = $unstagedCount
            untrackedCount = $untrackedCount
            diffStat = $diffStat
            diffExcerpt = ($excerptLines -join "`n").Trim()
        }
    } finally {
        Pop-Location
    }
}

function Get-GitSnapshot {
    param(
        [string]$Path
    )

    $context = Get-GitContext -Path $Path
    return [pscustomobject]@{
        isGitRepo = $context.isGitRepo
        branch = $context.branch
        createdAt = (Get-Date).ToString('o')
        files = @($context.changedFiles)
    }
}

function Get-GitFileDiff {
    param(
        [string]$Path,
        [string]$RelativeFilePath,
        [string]$OriginalPath
    )

    $git = Get-GitCommand
    if (-not $git) {
        throw 'Git is not available.'
    }

    Push-Location $Path
    try {
        if (-not (Test-GitWorkTree -GitCommand $git)) {
            throw 'Selected directory is not a Git repository.'
        }

        $pathArgs = @()
        if ($OriginalPath) {
            $pathArgs += $OriginalPath
        }
        if ($RelativeFilePath -and ($pathArgs -notcontains $RelativeFilePath)) {
            $pathArgs += $RelativeFilePath
        }

        $statusLines = @(& $git.Source status --short -- @($pathArgs) 2>$null)
        $parsed = ConvertFrom-GitStatusLine -Line ($statusLines | Select-Object -First 1)
        $diffText = (& $git.Source diff --find-renames --find-copies --no-ext-diff -- @($pathArgs) 2>$null | Out-String)
        if (-not $diffText.Trim()) {
            $diffText = (& $git.Source diff --cached --find-renames --find-copies --no-ext-diff -- @($pathArgs) 2>$null | Out-String)
        }
        $excerptLines = @($diffText -split "`r?`n" | Select-Object -First 180)

        return [pscustomobject]@{
            path = $RelativeFilePath
            originalPath = $OriginalPath
            kind = if ($parsed) { $parsed.kind } else { 'modified' }
            status = if ($statusLines) { ($statusLines | Select-Object -First 1).Trim() } else { '' }
            diff = ($excerptLines -join "`n").Trim()
        }
    } finally {
        Pop-Location
    }
}

function Get-GitPatchForHunk {
    param(
        [string]$Path,
        [string]$RelativeFilePath,
        [string]$OriginalPath,
        [int]$HunkIndex
    )

    $diffInfo = Get-GitFileDiff -Path $Path -RelativeFilePath $RelativeFilePath -OriginalPath $OriginalPath
    $lines = @($diffInfo.diff -split "`r?`n")
    if (-not $lines.Count) {
        throw 'No diff available for the selected file.'
    }

    $headerLines = @()
    $hunks = @()
    $currentHunk = @()

    foreach ($line in $lines) {
        if ($line -match '^@@ ') {
            if ($currentHunk.Count -gt 0) {
                $hunks += ,@($currentHunk)
            }
            $currentHunk = @($line)
        } elseif ($currentHunk.Count -gt 0) {
            $currentHunk += $line
        } else {
            $headerLines += $line
        }
    }

    if ($currentHunk.Count -gt 0) {
        $hunks += ,@($currentHunk)
    }

    if ($HunkIndex -lt 0 -or $HunkIndex -ge $hunks.Count) {
        throw "Hunk index $HunkIndex is out of range."
    }

    return (($headerLines + $hunks[$HunkIndex]) -join "`n").Trim() + "`n"
}

function Invoke-GitFileAction {
    param(
        [string]$Path,
        [ValidateSet('stage', 'discard')]
        [string]$Action,
        [string]$RelativeFilePath,
        [string]$OriginalPath
    )

    $git = Get-GitCommand
    if (-not $git) {
        throw 'Git is not available.'
    }

    Push-Location $Path
    try {
        if (-not (Test-GitWorkTree -GitCommand $git)) {
            throw 'Selected directory is not a Git repository.'
        }

        $pathArgs = @()
        if ($OriginalPath) {
            $pathArgs += $OriginalPath
        }
        if ($RelativeFilePath -and ($pathArgs -notcontains $RelativeFilePath)) {
            $pathArgs += $RelativeFilePath
        }

        if ($Action -eq 'stage') {
            & $git.Source add -A -- @($pathArgs)
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to stage '$RelativeFilePath'."
            }
        } else {
            $isUntracked = @(& $git.Source ls-files --others --exclude-standard -- $RelativeFilePath 2>$null).Count -gt 0
            if ($isUntracked) {
                if (Test-Path $RelativeFilePath) {
                    Remove-Item -LiteralPath $RelativeFilePath -Force
                }
            } else {
                & $git.Source restore --staged --worktree --source=HEAD -- @($pathArgs)
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to discard '$RelativeFilePath'."
                }
            }
        }

        return [pscustomobject]@{
            ok = $true
            action = $Action
            path = $RelativeFilePath
            originalPath = $OriginalPath
        }
    } finally {
        Pop-Location
    }
}

function Invoke-GitCommit {
    param(
        [string]$Path,
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw 'Commit message is required.'
    }

    $git = Get-GitCommand
    if (-not $git) {
        throw 'Git is not available.'
    }

    Push-Location $Path
    try {
        if (-not (Test-GitWorkTree -GitCommand $git)) {
            throw 'Selected directory is not a Git repository.'
        }

        $result = Invoke-ExternalCapture -FilePath $git.Source -ArgumentList @('commit', '-m', $Message)
        if ($result.ExitCode -ne 0) {
            throw ($result.Combined.Trim())
        }

        return [pscustomobject]@{
            ok = $true
            message = $Message
            output = $result.Combined.Trim()
        }
    } finally {
        Pop-Location
    }
}

function Invoke-GitHunkAction {
    param(
        [string]$Path,
        [ValidateSet('stage', 'discard')]
        [string]$Action,
        [string]$RelativeFilePath,
        [string]$OriginalPath,
        [int]$HunkIndex
    )

    $git = Get-GitCommand
    if (-not $git) {
        throw 'Git is not available.'
    }

    $patch = Get-GitPatchForHunk -Path $Path -RelativeFilePath $RelativeFilePath -OriginalPath $OriginalPath -HunkIndex $HunkIndex
    $patchFile = Join-Path (Get-TempPath) ("codex-hunk-" + [Guid]::NewGuid().ToString() + ".patch")

    Push-Location $Path
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($patchFile, $patch, $utf8NoBom)
        if ($Action -eq 'stage') {
            & $git.Source apply --cached --whitespace=nowarn --recount $patchFile
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to stage the selected hunk.'
            }
        } else {
            & $git.Source apply -R --whitespace=nowarn --recount $patchFile
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to discard the selected hunk.'
            }
        }

        return [pscustomobject]@{
            ok = $true
            action = $Action
            path = $RelativeFilePath
            originalPath = $OriginalPath
            hunkIndex = $HunkIndex
        }
    } finally {
        Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
        Pop-Location
    }
}
