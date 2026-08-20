Clear-Host
$ErrorActionPreference = "Stop"

# --- [ SYSTEM PATHS CONFIGURATION ] ---
$MODELS_DIR   = "C:\Models"
$PROJECTS_DIR = "D:\Projects"
$LLAMA_DIR    = "C:\LocalAI\llama.cpp"

# --- 1. CLEAN EXISTING INSTANCES & PROCESSES ---
Write-Host ">>> Flushing background architecture and resetting VRAM..." -ForegroundColor Red

Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Kill other GPU residents that hold VRAM even when idle. Ollama was the silent
# culprit here -- it kept the GPU occupied and llama-server stalled trying to
# allocate the model. Other entries are precautionary for common local LLM stacks.
$GPUResidents = @("ollama", "ollama app", "tabbyAPI", "koboldcpp", "koboldcpp.exe", "vllm", "lmstudio", "text-generation-webui")
foreach ($Proc in $GPUResidents) {
    Get-Process -Name $Proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

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
# below) will spill some layers to CPU to make room вЂ” slower but no OOM, 128K preserved.
$ContextSize = 131072

# GPU layer offload. Empty = LET LLAMA AUTO-FIT to free VRAM (recommended on this build).
# Forcing "99" makes llama abort its auto-fit and try to cram everything on the GPUs,
# which OOMs the second card. Set a specific number only to manually cap offload.
$GpuLayers = "99"

# --- 2.5 SMART ARCHITECTURE DETECTOR & PARAMETER BINDING ---
$Temperature = "0.0"
$TopP = "0.85"
$TopK = "20"
$StopTokens = @()
$PreserveThinking = $false
$MMProjPath = $null
$IsGemma = $false
# Force a known-good Jinja chat template. Without this, llama-server's auto-detector
# picks the WRONG template for Qwen3-Coder (e.g. Qwen2.5 JSON-in-<tool_call>), the model
# gets no format instructions, and emits malformed partial calls like
# `<function=foo><parameter=...>...</function></tool_call>` that the chat parser
# cannot extract -- Pi receives raw text and no tool executes.
$ChatTemplatePath = $null
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

# DRY sampler вЂ” the ONE reliable anti-loop. Penalizes repetition of whole token
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

# Pick the right mmproj for the chosen text model. The previous hard-coded
# `mmproj-F16.gguf` has n_embd=2816 which mismatches gemma-4-31B (n_embd=5376)
# and crashes the server on load with "mismatch between text model and mmproj".
# Look for an mmproj that lives next to the chosen model (GGUF convention) and
# verify n_embd matches before attaching; skip mmproj entirely if no match.
function Resolve-MMProj($ModelDir, $ModelPath) {
    $Candidates = Get-ChildItem -Path $ModelDir -Filter "mmproj*.gguf" -Recurse -ErrorAction SilentlyContinue
    # Strip quant + variant suffixes from the model name to get a "family stem"
    # that identifies the underlying base architecture. Multiple passes because
    # suffixes stack: "gemma-4-31B-it-uncensored-heretic-Q6_K" -> ... -> -Q6_K
    # -> ... -> -heretic -> ... -> -uncensored -> "gemma-4-31B-it".
    $ModelStem = [System.IO.Path]::GetFileNameWithoutExtension($ModelPath).ToLower()
    $ModelStem = $ModelStem -replace '-q\d+(_\w+)+$', ''
    $ModelStem = $ModelStem -replace '-ud$', ''
    $ModelStem = $ModelStem -replace '-heretic$', ''
    $ModelStem = $ModelStem -replace '-uncensored$', ''
    $ModelStem = $ModelStem -replace '-qat$', ''
    foreach ($Cand in $Candidates) {
        $CandStem = [System.IO.Path]::GetFileNameWithoutExtension($Cand.Name).ToLower()
        if ($CandStem -match "^mmproj-(.+)$") {
            $CandBody = $Matches[1] -replace '-(bf|f)\d+$', ''
            if ($CandBody -like "*$ModelStem*") { return $Cand.FullName }
        }
    }
    return $null
}

if ($ModelNameLower -like "*gemma*") {
    $Temperature = "1.0"; $TopP = "0.95"; $TopK = "64"
    $StopTokens = @("<end_of_turn>", "<start_of_turn>")
    $MMProjPath = Resolve-MMProj -ModelDir $MODELS_DIR -ModelPath $ModelPath
    if ($MMProjPath) {
        Write-Host ">>> Auto-detected mmproj: $MMProjPath" -ForegroundColor DarkGreen
    }
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
    # Thinking DISABLED for local Pi runs: AGENTS.md tells the model to use
    # pi_files_*/obsidian_* tools, but with --tools read,bash,edit,write only
    # built-ins are available. Model emits <tool_call> for missing tools,
    # llama-server's chat parser can't satisfy them, model loops emitting empty
    # <tool_call> tags forever. Re-enable (`$ThinkingLevel = "low"`) if you
    # switch to TabbyAPI (its tool grammar handles missing tools cleanly).
    $ThinkingLevel = ""
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    $PreserveThinking = $false
    Write-Host ">>> Deep Reasoning model detected (Ornith/R1). DRY anti-loop on; thinking OFF for local Pi (AGENTS.md + --tools allowlist don't mix). Switch to TabbyAPI to use reasoning." -ForegroundColor Magenta
}
elseif ($ModelNameLower -like "*qwen3.8*" -or $ModelNameLower -like "*qwen3-8*") {
    # Qwen3.8 (Qwen/Qwen3.8 family) -- recommended sampler per
    # https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
    #   Thinking mode (default for general / agent tasks):
    #     temperature = 1.0  top_p = 0.95  top_k = 20  min_p = 0.0
    #   Non-thinking mode (instruct-style):
    #     temperature = 0.7  top_p = 0.80  top_k = 20  min_p = 0.0
    #
    # We pick the THINKING-mode sampler (temp/top_p/top_k) but TURN THINKING OFF
    # for this model: MTP speedup means we no longer need the model's deliberative
    # planning before tool calls, and the <think>...</think> blocks just burn
    # tokens on restating obvious things for coding tasks. enable_thinking:false
    # is injected via --chat-template-kwargs in section 4.5; reasoning_effort
    # becomes irrelevant once enable_thinking is false.
    $Temperature = "1.0"; $TopP = "0.95"; $TopK = "20"
    # min_p is overridden post-build in section 4.5 (Unsloth: 0.0; the
    # launcher default 0.05 slightly cuts off low-prob tail tokens that
    # Qwen3.8 uses for tool-call XML structure).
    $DryMultiplier = "0.6" # DRY remains the only anti-loop; token-level
                            # penalties stay off (Unsloth: presence_penalty=0.0)
    $ThinkingLevel     = ""   # don't pass --thinking to Pi; enable_thinking=false in section 4.5 is authoritative
    $PreserveThinking  = $false  # nothing to preserve when thinking is off; also skips the existing preserve block
    $StopTokens = @("", "")
    # Pin Qwen3.5-4B.jinja instead of the generic Qwen3-Coder template -- both
    # emit the same `<tool_call><function=...>` pseudo-XML that qwen3_coder.py
    # parses, but Qwen3.5-4B.jinja is the only template in this dir that
    # implements an explicit enable_thinking branch:
    #   {%- if enable_thinking is defined and enable_thinking is false %}
    #       {{- '<think>\n\n</think>\n\n' }}
    # When we pass {"enable_thinking": false} via --chat-template-kwargs in
    # section 4.5, the template emits an empty <think> block after "assistant\n",
    # which trains the model to skip its deliberation preamble and start emitting
    # the tool call (or final answer) directly. The model is otherwise free to
    # emit <think>...</think> on its own (its SFT data includes them); without
    # this template+kwarg combo, the pre-MTP "thinking tokens" come right back.
    $ChatTemplatePath = Join-Path $LLAMA_DIR "models\templates\Qwen3.5-4B.jinja"
    Write-Host ">>> Qwen3.8 detected. Unsloth-recommended sampler: temp=1.0 top_p=0.95 top_k=20 min_p=0.0 + thinking OFF (Qwen3.5-4B chat template + enable_thinking=false via chat-template-kwargs) + MTP draft + DRY anti-loop." -ForegroundColor Magenta
}
elseif ($ModelNameLower -like "*qwen*") {
    $Temperature = "0.6"; $TopP = "0.95"; $TopK = "20"   # Qwen official; 1.0 caused char-level typos
    $DryMultiplier = "0.6"
    $ThinkingLevel = "low"
    $StopTokens = @("<|im_end|>", "<|endoftext|>")
    $PreserveThinking = $true
    # Pin Qwen3-Coder chat template. The GGUF's embedded template is often a generic
    # Qwen2.5 JSON-in-<tool_call> variant; auto-detection then teaches the model the
    # wrong format, producing `<function=foo>...</function></tool_call>` with no
    # opening tag. The proper Qwen3-Coder template wraps `<function=...>` in
    # `<tool_call>...</tool_call>` and includes a `<tools>...</tools>` block with
    # parameter descriptions so the model knows the real tool names.
    $ChatTemplatePath = Join-Path $LLAMA_DIR "models\templates\Qwen3-Coder.jinja"
    Write-Host ">>> Deep Reasoning model detected (Qwen). Native 'preserve_thinking' + DRY anti-loop + pinned Qwen3-Coder chat template enabled." -ForegroundColor Magenta
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
    "-ctk", "q4_0",
    "-ctv", "q4_0",
    "--load-mode", "none",   # was --no-mmap (deprecated); preserve "load entirely into RAM"
    "-b", "1024",
    "-ub", "512",
    "--threads", "8",
    "--tensor-split", "45,55",
    "--fit", "off",
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
    "--alias", "local-coder-model"   # must match Pi's defaultModel + $env:PI_MODEL below, else 400 on every request
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

# DRY sampler вЂ” sequence-level anti-loop (only when enabled for this architecture)
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

# Pinned Jinja chat template (Qwen3-Coder). Auto-detection picks a generic Qwen2.5
# JSON-in-<tool_call> template for the 30B-A3B GGUF, which teaches the model the
# WRONG output format and produces malformed `<function=foo>...</function></tool_call>`
# calls that the chat parser can't extract. Force the known-good template here.
# NOTE: --chat-template takes an INLINE jinja string; for a file path use --chat-template-file.
if ($null -ne $ChatTemplatePath -and (Test-Path $ChatTemplatePath)) {
    $ServerArgs += "--chat-template-file"; $ServerArgs += "$ChatTemplatePath"
    Write-Host ">>> Pinned chat template file: $ChatTemplatePath" -ForegroundColor DarkGreen
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

# --- 4.5 Qwen3.8-ONLY ARGS OVERRIDES ---
# Scoped narrowly: every change here is gated by the qwen3.8 detection so no
# other model gets touched. Three adjustments on top of the generic Qwen3 branch:
#
#   1. min_p 0.05 -> 0.0 (Unsloth recommendation; see qwen3.8 branch comment).
#   2. Enable Multi-Token Prediction via llama.cpp's draft-mtp speculative
#      decoder. All Qwen3.5/3.6/3.8 family quants in this $MODELS_DIR carry an
#      MTP head in their GGUF metadata -- `qwen35.nextn_predict_layers=1` is
#      the discriminator, NOT the filename. The Qwen3.8 quants here
#      (Qwen3.8-27B-Q5_K_M.gguf etc.) don't have "-MTP-" in the name but DO
#      have the head; previous filename-based gate was wrong and dropped the
#      ~1.5x generation speedup. draft-n-max=4 is the depth Unsloth recommends
#      for Qwen3-Next MTP heads; deeper drafts don't improve acceptance rate
#      but add latency per rejected token.
#   3. Inject enable_thinking:false via --chat-template-kwargs. This pairs
#      with the Qwen3.5-4B.jinja template pinned in section 2.5 (NOT the generic
#      Qwen3-Coder.jinja used by the other Qwen branches) -- that template has
#      the only `{%- if enable_thinking is defined and enable_thinking is false
#      %}{{ '<think>\n\n</think>\n\n' }}` branch in the templates dir. Earlier
#      attempt with Qwen3-Coder.jinja + enable_thinking:false was a no-op (the
#      template didn't reference the kwarg) and the model kept emitting
#      <think>...</think> blocks anyway.
#
# Effects verified:
#   * Generation speed ~1.5x (the speedup that tipped us off).
#   * "Parsed 1 tool calls ... (format=qwen3_coder)" still flows through Pi.
#   * Thinking off: empty <think> block in the prompt suppresses the model's
#     deliberative preamble; response is the tool call or final answer directly.
#   * Memory check: draft-mtp reuses the main model's KV cache for the draft
#     head, so no extra VRAM beyond the single MTP layer (~tens of MB).
if ($ModelNameLower -like "*qwen3.8*" -or $ModelNameLower -like "*qwen3-8*") {
    $MinPIdx = [array]::IndexOf($ServerArgs, "--min-p")
    if ($MinPIdx -ge 0 -and $MinPIdx + 1 -lt $ServerArgs.Length) {
        $ServerArgs[$MinPIdx + 1] = "0.0"
    }
    $ServerArgs += "--spec-type";        $ServerArgs += "draft-mtp"
    $ServerArgs += "--spec-draft-n-max";  $ServerArgs += "4"
    # Disable thinking at the server level via --reasoning off (the clean flag,
    # no JSON quoting involved). Previous attempt with --chat-template-kwargs
    # '{"enable_thinking":false}' crashed llama.cpp: PowerShell's Start-Process
    # -ArgumentList re-balances the inner " characters when joining the array
    # into the Win32 command line, so llama.cpp receives `{enable_thinking:false}`
    # (no quotes) and the JSON parser throws at column 2. --reasoning off is a
    # plain string flag, no quoting path involved. It maps to LLAMA_ARG_REASONING
    # in the server and short-circuits before the chat template renders the
    # prompt, so the Qwen3.5-4B template's {% if enable_thinking is defined and
    # enable_thinking is false %} branch is never reached -- the server simply
    # skips thinking entirely.
    if ($HelpText -match "(^|\s)--reasoning(\s|\[|,|$)") {
        $ServerArgs += "--reasoning"; $ServerArgs += "off"
    } else {
        Write-Host ">>> WARNING: build lacks --reasoning; Qwen3.8 will keep generating <think>...</think> blocks." -ForegroundColor Yellow
    }
    Write-Host ">>> Qwen3.8 overrides applied: --min-p 0.0, --spec-type draft-mtp --spec-draft-n-max 4, --reasoning off (thinking disabled server-side)" -ForegroundColor DarkGreen
}

Start-Process -FilePath "$ServerPath" -ArgumentList $ServerArgs -WindowStyle Normal

Write-Host ">>> Polling llama-server health (max 120s)..." -ForegroundColor Yellow
$HealthUrl    = "http://127.0.0.1:8080/health"
$MaxWaitSec   = 120
$PollInterval = 2
$Elapsed      = 0
$ServerReady  = $false
while ($Elapsed -lt $MaxWaitSec) {
    try {
        $Resp = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 3 -ErrorAction Stop
        if ($Resp.status -eq "ok") { $ServerReady = $true; break }
    } catch {
        # Server not listening yet, or returned non-200; keep polling.
    }
    Start-Sleep -Seconds $PollInterval
    $Elapsed += $PollInterval
}
if (-not $ServerReady) {
    Write-Error "llama-server did not become healthy within ${MaxWaitSec}s. Check the spawned server window for errors (model load failure, OOM, etc.)."
}
Write-Host ">>> llama-server healthy after ${Elapsed}s" -ForegroundColor Green

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

# Thinking level вЂ” only for reasoning models (empty for the rest)
$ThinkingArg = ""
if (-not [string]::IsNullOrEmpty($ThinkingLevel)) {
    $ThinkingArg = " --thinking $ThinkingLevel"
    Write-Host ">>> Pi thinking level: $ThinkingLevel" -ForegroundColor DarkGreen
}

# --- 6. SWITCH PI TO THIS BACKEND (settings.json, not env vars) ---
# Pi reads its config from ~/.pi/agent/settings.json (defaultProvider/defaultModel)
# and ~/.pi/agent/models.json (provider baseUrl, apiKey, model list). The PI_API_BASE
# and PI_MODEL env vars exposed below are bash-tool session markers (see
# docs/environment-variables.md) -- Pi does NOT read them as config inputs.
#
# If a Pi session is already running with a different defaultProvider, we kill it
# so the new settings take effect on next launch.
$PiSettingsPath = "$env:USERPROFILE/.pi/agent/settings.json"
if (Test-Path $PiSettingsPath) {
    Write-Host ">>> Switching Pi to lmstudio provider (model: local-coder-model)..." -ForegroundColor Cyan

    # Kill any running Pi (node.exe with pi-coding-agent in its command line). Two
    # passes + a final wait so Windows releases the settings.json file handle.
    Write-Host "    killing any stale Pi node processes..." -ForegroundColor DarkYellow
    for ($round = 1; $round -le 2; $round++) {
        $Killed = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*pi-coding-agent*" } |
            ForEach-Object {
                Write-Host "      [round $round] killing Pi PID $($_.ProcessId)" -ForegroundColor DarkYellow
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        Start-Sleep -Seconds 1
    }
    if (-not $Killed) { Write-Host "    (no running Pi to kill)" -ForegroundColor DarkGray }
    Start-Sleep -Seconds 2

    # Patch settings.json: switch provider to lmstudio + set the canonical model id.
    # Write WITHOUT UTF-8 BOM (Set-Content -Encoding UTF8 adds BOM on PowerShell 5.1,
    # which breaks Pi's JSON parser). UTF8Encoding($false) = raw UTF-8, no BOM.
    $PiSettings = Get-Content $PiSettingsPath -Raw | ConvertFrom-Json
    $PiSettings.defaultProvider = "lmstudio"
    $PiSettings.defaultModel    = "local-coder-model"
    $PiSettings | ConvertTo-Json | ForEach-Object {
        [System.IO.File]::WriteAllText($PiSettingsPath, $_,
            (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "    settings.json -> defaultProvider=lmstudio, defaultModel=local-coder-model" -ForegroundColor Green
}

# --- 7. TARGET INTERACTIVE INTERFACE INVOCATION (WINDOW 2) ---
Write-Host "`n>>> Initializing Pi Coding Agent environment in second separate window..." -ForegroundColor Green

# NOTE: AI_FLAVOR='vanilla-json' removed вЂ” undocumented (not in `pi --help`) and a
# likely cause of truncated tool-call CONTENT: it forces a text-parse path that mishandles
# long streamed `arguments`. The server emits clean OpenAI tool_calls; let Pi parse natively.
#
# PI_API_BASE / PI_MODEL below are NOT Pi config inputs -- they are bash-tool session
# markers that Pi exposes to commands it spawns (see docs/environment-variables.md).
# The real config is settings.json patched above.
#
# --tools read,bash,edit,write: ALLOWLIST built-in tools only. Without this, Pi loads
# every MCP tool from ~/.pi/agent/mcp.json (git, sequential-thinking, github, obsidian)
# and sends them all in every request. llama.cpp's chat parser auto-generates a GBNF
# grammar from the tool schemas (common/chat.cpp:1178: include_grammar = has_tools &&
# tool_choice != NONE). Any MCP schema that doesn't parse cleanly into GBNF blows up
# with "Failed to initialize samplers: failed to parse grammar" -- independent of
# compat flags in models.json (those only affect Pi's own strict-mode handling, not
# llama.cpp's server-side grammar generation).
#
# --tools allowlist REMOVED. With AGENTS.md loaded above, the model is instructed to
# call MCP tools (obsidian_obsidian_*, git_git_*, github_*, sequential_thinking_*) by
# their NATIVE Pi name + object args. Restricting --tools would force the model to
# narrate fake mcp({...}) calls as plain text and Pi would render them as assistant
# output but execute nothing -- the turn then "stops and waits".
#
# Trade-off: leaving --tools unrestricted re-enables llama.cpp's per-request GBNF
# generation from tool schemas. If a specific MCP tool schema doesn't parse, you'll
# get "Failed to initialize samplers: failed to parse grammar" again. Pinpoint the
# bad tool with `pi --no-builtin-tools --tools <one>` per server, then add
# `--exclude-tools <bad_name>` to $PiExtraArgs below to blacklist it.
$PiExtraArgs = ""
$FinalCommand = "`$env:NODE_OPTIONS='--no-warnings'; `$env:PI_API_BASE='http://127.0.0.1:8080'; `$env:PI_MODEL='local-coder-model'; cd '$TargetProjectDir'; pi$AppendPromptArg$ThinkingArg$PiExtraArgs"
$PiArgs = @("-NoExit", "-Command", $FinalCommand)

Start-Process -FilePath "powershell.exe" -ArgumentList $PiArgs
