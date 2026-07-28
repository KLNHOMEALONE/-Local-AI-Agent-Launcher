Clear-Host
$ErrorActionPreference = "Stop"

# --- [ SYSTEM PATHS CONFIGURATION ] ---
$MODELS_DIR   = "C:\Models"
$PROJECTS_DIR = "D:\Projects"
$LLAMA_DIR    = "C:\LocalAI\llama.cpp"

# --- 1. CLEAN EXISTING INSTANCES & PROCESSES ---
Write-Host ">>> Flushing background architecture and resetting VRAM..." -ForegroundColor Red

Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\opencode"    -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\claude-code" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:USERPROFILE\.cache\pi-code"     -ErrorAction SilentlyContinue

$SlotCacheDir = "C:\LocalAI\slot_cache"
if (!(Test-Path $SlotCacheDir)) { New-Item -ItemType Directory -Path $SlotCacheDir -Force | Out-Null }

# --- 2. INTERACTIVE MODEL SELECTION ---
$ModelFiles = Get-ChildItem -Path $MODELS_DIR -Filter "*.gguf" -ErrorAction SilentlyContinue
if ($ModelFiles.Count -eq 0) { Write-Error "Error: No .gguf models discovered inside $MODELS_DIR" }

Write-Host ""
Write-Host "=== AVAILABLE MODELS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ModelFiles.Count; $i++) {
    if ($ModelFiles[$i].Name -notlike "*mmproj*") {
        Write-Host "  [$($i + 1)] $($ModelFiles[$i].Name)" -ForegroundColor Yellow
    }
}

$ModelSelection = Read-Host "`nSelect model index number"
$SelectedModelFile = $ModelFiles[[int]$ModelSelection - 1]

# Guard: don't let a projector be picked as the main model
if ($null -eq $SelectedModelFile -or $SelectedModelFile.Name -like "*mmproj*") {
    Write-Error "Invalid selection: index out of range or points to an mmproj projector file."
}
$ModelPath = $SelectedModelFile.FullName

# Full 128K context (required). KV cache at this size is large; auto-fit (-ngl empty
# below) will spill some layers to CPU to make room — slower but no OOM, 128K preserved.
$ContextSize = 131072

# GPU layer offload. Empty = LET LLAMA AUTO-FIT to free VRAM (recommended on this build).
# Forcing "99" makes llama abort its auto-fit and try to cram everything on the GPUs,
# which OOMs the second card. Set a specific number only to manually cap offload.
$GpuLayers = ""

# --- 2.5 SMART ARCHITECTURE DETECTOR & PARAMETER BINDING ---
$Temperature = "0.0"
$TopP = "0.85"
$TopK = "20"
$StopTokens = @()
$PreserveThinking = $false
$MMProjPath = $null
$IsGemma = $false
# Pi --thinking level. Empty = don't pass the flag (non-reasoning models). Only
# reasoning models get a level set; "low" keeps thinking short to avoid runaway
# chains of thought on this small MoE.
$ThinkingLevel = ""

# Token-level penalties. KEEP THESE OFF (neutral) by default. Stacking repeat +
# frequency + presence penalties over-penalizes ordinary tokens and pushes the model
# into incoherent rare-word "salad". Use DRY (below) as the ONLY anti-loop instead.
$RepeatPenalty    = "1.0"   # 1.0 = disabled
$FrequencyPenalty = "0.0"   # 0.0 = disabled
$PresencePenalty  = "0.0"   # 0.0 = disabled
$RepeatLastN      = "256"   # window for the above (irrelevant while they're neutral)

# DRY sampler — the ONE reliable anti-loop. Penalizes repetition of whole token
# SEQUENCES (n-grams), so it breaks "same paragraph over and over" loops WITHOUT the
# word-salad side effect of token-level penalties. $DryMultiplier = "0.0" disables it.
# AllowedLength 4 spares short legit code repeats (brackets, indentation).
$DryMultiplier   = "0.0"
$DryBase         = "1.75"
$DryAllowedLen   = "8"     # higher = DRY ignores short legit repeats (filenames, code,
                            # paths). Low values corrupt strings the model must reproduce
                            # verbatim (e.g. re-typing a filename from `ls` output).
$DryPenaltyLastN = "512"

$ModelNameLower = $SelectedModelFile.Name.ToLower()
$GemmaMMProj = Join-Path $MODELS_DIR "mmproj-F16.gguf"

if ($ModelNameLower -like "*gemma*") {
    $Temperature = "1.0"; $TopP = "0.95"; $TopK = "64"
    $StopTokens = @("<end_of_turn>", "<start_of_turn>")
    if (Test-Path $GemmaMMProj) { $MMProjPath = $GemmaMMProj }
    $IsGemma = $true
    Write-Host ">>> Gemma 4 architecture detected. Parameters calibrated." -ForegroundColor Green
}
elseif ($ModelNameLower -like "*qwopus*") {
    $Temperature = "0.6"; $TopP = "0.95"; $TopK = "64"
    $DryMultiplier = "0.8"   # DRY is the sole anti-loop; token penalties stay OFF
    $ThinkingLevel = "low"
    $StopTokens = @("<|im_end|>", "<|endoftext|>", "<|im_start|>")
    Write-Host ">>> Qwopus MoE Agent architecture detected. DRY anti-loop enabled (token penalties off)." -ForegroundColor Magenta
}
elseif ($ModelNameLower -like "*ornith*" -or $ModelNameLower -like "*r1*" -or $ModelNameLower -like "*reasoning*") {
    $Temperature = "0.6"; $TopP = "0.95"; $TopK = "20"   # 1.0 caused char-level typos in exact copies
    $DryMultiplier = "0.6"   # reasoning models loop on repeated thoughts; DRY breaks it
    $ThinkingLevel = "low"
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    $PreserveThinking = $true
    Write-Host ">>> Deep Reasoning model detected (Ornith/R1). Native 'preserve_thinking' + DRY anti-loop enabled." -ForegroundColor Magenta
}
elseif ($ModelNameLower -like "*qwen*") {
    $Temperature = "0.6"; $TopP = "0.95"; $TopK = "20"   # Qwen official; 1.0 caused char-level typos
    $DryMultiplier = "0.6"
    $ThinkingLevel = "low"
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    $PreserveThinking = $true
    Write-Host ">>> Deep Reasoning model detected (Qwen). Native 'preserve_thinking' + DRY anti-loop enabled." -ForegroundColor Magenta
}
else {
    $Temperature = "0.0"
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    Write-Host ">>> Standard Causal architecture detected. Temperature set to 0.0 with ChatML stop tokens." -ForegroundColor Cyan
}

# --- 3. INTERACTIVE PROJECT WORKING DIRECTORY SELECTION ---
$ProjectDirs = Get-ChildItem -Path $PROJECTS_DIR -Directory -ErrorAction SilentlyContinue
if ($ProjectDirs.Count -eq 0) { Write-Error "Error: No project environments discovered inside $PROJECTS_DIR" }
Write-Host ""
Write-Host "=== TARGET WORKSPACE PROJECTS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ProjectDirs.Count; $i++) { Write-Host "  [$($i + 1)] $($ProjectDirs[$i].Name)" -ForegroundColor Yellow }
$ProjectSelection = Read-Host "`nSelect project index number"
$TargetProjectDir = $ProjectDirs[[int]$ProjectSelection - 1].FullName

# --- 4. DETACHED SERVER INITIALIZATION ON PORT 8080 ---
Write-Host "`n>>> Launching native OpenAI/Anthropic-compatible llama-server on port 8080..." -ForegroundColor Green
$ServerPath = (Get-ChildItem -Path $LLAMA_DIR -Recurse -Filter "llama-server.exe" | Select-Object -First 1).FullName
if ([string]::IsNullOrEmpty($ServerPath)) { Write-Error "llama-server.exe not found under $LLAMA_DIR" }

# Probe which flash-attn syntax this build uses. Newer builds show 'on'/'off'/'auto'
# and REQUIRE a value; older builds are a valueless flag. Passing the wrong form
# crashes the server instantly, and quantized KV (-ctk/-ctv q8_0) needs FA enabled.
$HelpText = & "$ServerPath" --help 2>&1 | Out-String
$FlashAttnTakesValue = ($HelpText -match "flash.?attn.*(on|off|auto)")

$ServerArgs = @(
    "-m", "$ModelPath",
    "--host", "0.0.0.0",
    "--port", "8080",
    "-n", "-1",
    "-sm", "layer",
    "--ctx-size", "$ContextSize",
    "-ctk", "q8_0",
    "-ctv", "q8_0",
    "--no-mmap",
    "-b", "1024",
    "-ub", "512",
    "--threads", "8",
    "-tb", "8",
    "-np", "1",
    "--temp", "$Temperature",
    "--min-p", "0.05",
    "--top-p", "$TopP",
    "--top-k", "$TopK",
    "--repeat-penalty", "$RepeatPenalty",
    "--repeat-last-n", "$RepeatLastN",
    "--frequency-penalty", "$FrequencyPenalty",
    "--presence-penalty", "$PresencePenalty",
    "--jinja",
    "--cont-batching",
    "--slot-save-path", "$SlotCacheDir",
    "--alias", "local_model"
)

# GPU layers: only pass -ngl if manually set; otherwise let llama auto-fit VRAM.
if (-not [string]::IsNullOrEmpty($GpuLayers)) {
    $ServerArgs += "-ngl"; $ServerArgs += "$GpuLayers"
    Write-Host ">>> GPU layers forced to $GpuLayers" -ForegroundColor DarkYellow
} else {
    Write-Host ">>> GPU layers: auto-fit to available VRAM" -ForegroundColor DarkGreen
}

# Flash attention: version-correct form
if ($FlashAttnTakesValue) {
    $ServerArgs += "--flash-attn"; $ServerArgs += "on"
} else {
    $ServerArgs += "--flash-attn"
}

# DRY sampler — sequence-level anti-loop (only when enabled for this architecture)
if ([double]$DryMultiplier -gt 0) {
    $ServerArgs += "--dry-multiplier";      $ServerArgs += "$DryMultiplier"
    $ServerArgs += "--dry-base";            $ServerArgs += "$DryBase"
    $ServerArgs += "--dry-allowed-length";  $ServerArgs += "$DryAllowedLen"
    $ServerArgs += "--dry-penalty-last-n";  $ServerArgs += "$DryPenaltyLastN"
    Write-Host ">>> DRY anti-loop active: mult=$DryMultiplier base=$DryBase allowed=$DryAllowedLen window=$DryPenaltyLastN" -ForegroundColor DarkGreen
}

# Hardware token ban applies ONLY to Gemma (sign delimiter: TOKEN-BIAS)
if ($IsGemma) {
    $ServerArgs += "--logit-bias"; $ServerArgs += "131070-100"
}

# Multimodal projector injection (Gemma only)
if ($null -ne $MMProjPath) {
    $ServerArgs += "--mmproj"; $ServerArgs += "$MMProjPath"
}

# Reasoning preservation. This build uses the dedicated --reasoning-preserve flag;
# the older --chat-template-kwargs '{"preserve_thinking":true}' form CRASHES it.
# Probe --help and use whichever the binary actually supports.
if ($PreserveThinking) {
    if ($HelpText -match "--reasoning-preserve") {
        $ServerArgs += "--reasoning-preserve"
        Write-Host ">>> Reasoning preservation enabled via --reasoning-preserve" -ForegroundColor DarkGreen
    } elseif ($HelpText -match "--chat-template-kwargs") {
        $ServerArgs += "--chat-template-kwargs"; $ServerArgs += '{"preserve_thinking":true}'
        Write-Host ">>> Reasoning preservation enabled via --chat-template-kwargs" -ForegroundColor DarkGreen
    } else {
        Write-Host ">>> WARNING: build supports neither reasoning-preserve flag; skipping." -ForegroundColor Yellow
    }
}

# NOTE: stop tokens are NOT server launch args. --reverse-prompt is llama-cli-only
# and makes llama-server exit. Pass stop tokens per-request in the API body:
#   "stop": [ ... ]
Write-Host ">>> Configure your client with these stop tokens: $($StopTokens -join ', ')" -ForegroundColor DarkCyan

Start-Process -FilePath "$ServerPath" -ArgumentList $ServerArgs -WindowStyle Normal

Write-Host ">>> Allocating architecture weights to VRAM. Waiting 12 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 12

# --- 5. GLOBAL SYSTEM-PROMPT (central, no per-project copy) ---
# ONE global instructions file, appended to Pi's system prompt on every launch.
# Pi natively supports:  --append-system-prompt <text|file>
# (appends file CONTENTS to the system prompt; keeps Pi's base coding prompt).
$GlobalAgentsFile = "$env:USERPROFILE\.pi\agent\AGENTS.md"   # Pi's global agent config

$AppendPromptArg = ""
if (Test-Path $GlobalAgentsFile) {
    $AppendPromptArg = " --append-system-prompt '$GlobalAgentsFile'"
    Write-Host ">>> Global system prompt guaranteed via --append-system-prompt: $GlobalAgentsFile" -ForegroundColor Green
} else {
    Write-Host ">>> WARNING: global instructions file not found: $GlobalAgentsFile" -ForegroundColor Red
}

# Thinking level — only for reasoning models (empty for the rest)
$ThinkingArg = ""
if (-not [string]::IsNullOrEmpty($ThinkingLevel)) {
    $ThinkingArg = " --thinking $ThinkingLevel"
    Write-Host ">>> Pi thinking level: $ThinkingLevel" -ForegroundColor DarkGreen
}

# --- 6. TARGET INTERACTIVE INTERFACE INVOCATION (WINDOW 2) ---
Write-Host "`n>>> Initializing Pi Coding Agent environment in second separate window..." -ForegroundColor Green

# NOTE: AI_FLAVOR='vanilla-json' removed — undocumented (not in `pi --help`) and a
# likely cause of truncated tool-call CONTENT: it forces a text-parse path that mishandles
# long streamed `arguments`. The server emits clean OpenAI tool_calls; let Pi parse natively.
$FinalCommand = "`$env:NODE_OPTIONS='--no-warnings'; `$env:PI_API_BASE='http://127.0.0.1:8080'; `$env:PI_MODEL='local_model'; cd '$TargetProjectDir'; pi$AppendPromptArg$ThinkingArg"
$PiArgs = @("-NoExit", "-Command", $FinalCommand)

Start-Process -FilePath "powershell.exe" -ArgumentList $PiArgs
