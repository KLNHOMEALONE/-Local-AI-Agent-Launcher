Clear-Host
$ErrorActionPreference = "Stop"

# --- [ SYSTEM PATHS CONFIGURATION ] ---
# TabbyAPI stores each model in its own subdirectory inside model-dir.
# One subdirectory per model. Download with: huggingface_hub (see download helper below).
#
# IMPORTANT: forward slashes only. Backslash paths get the drive letter eaten
# by TabbyAPI's argparser on Windows.
$MODELS_DIR   = "C:/ModelsExl3"
$PROJECTS_DIR = "D:/Projects"
$TABBY_DIR    = "C:/LocalAI/TabbyAPIServer"
$VENV_PYTHON  = "$TABBY_DIR/venv/Scripts/python.exe"
$CONFIG_FILE  = "$TABBY_DIR/config.yml"

# TabbyAPI defaults: 5000. We pin it explicitly so the health-poll URL is unambiguous.
$Port = 5000
# 128K is a SAFE pre-selection default: every model in $MODELS_DIR can run at this size.
# After model selection we may bump to 256K via $ModelContextMap (section 2.5) based on
# each model's actual KV footprint -- hybrid Qwen3.5 (3x linear + 1x full attention) is
# dramatically cheaper than dense attention. Q4 cache mode halves VRAM vs FP16 with
# negligible quality loss -- important on 2x 16 GB when running 30B+ class models.
$ContextSize = 131072
$CacheMode   = "Q4"
# gpu_split_auto: Exllamav3 balances layers across both 5060 Ti 16 GB. Manual split
# (e.g. --gpu-split 16,16) is supported but not recommended unless you know the model
# size and want to pin a specific card.

# --- 1. CLEAN EXISTING INSTANCES & PROCESSES ---
Write-Host ">>> Flushing TabbyAPI background processes and resetting VRAM..." -ForegroundColor Red

# TabbyAPI runs as `python.exe main.py`. Find any process whose command line points
# at our install dir and kill it. Doing this via CIM is robust against multiple
# instances (Stop-Process -Name python would also kill unrelated python scripts).
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$TABBY_DIR*main.py*" } |
    ForEach-Object {
        Write-Host "    killing PID $($_.ProcessId) ($($_.CommandLine.Substring(0, [Math]::Min(80, $_.CommandLine.Length)))...)" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1   # let port 5000 release

# --- 2. INTERACTIVE MODEL SELECTION ---
# TabbyAPI's model_dir is a *directory of model directories*. Each model lives in
# its own subfolder (the one that contains config.json + safetensors / exl3 files).
if (!(Test-Path $MODELS_DIR)) {
    Write-Host ">>> Creating $MODELS_DIR (no models yet -- populate it later with downloaded Exl3 models)" -ForegroundColor DarkYellow
    New-Item -ItemType Directory -Path $MODELS_DIR -Force | Out-Null
}

$ModelDirs = Get-ChildItem -Path $MODELS_DIR -Directory -ErrorAction SilentlyContinue
if ($ModelDirs.Count -eq 0) {
    Write-Host "" -ForegroundColor Red
    Write-Host ">>> No model subdirectories found in $MODELS_DIR" -ForegroundColor Red
    Write-Host ">>> Each Exl3 / FP16 / BF16 model must be in its own subfolder." -ForegroundColor Red
    Write-Host ">>> To download a model, use the venv python directly:" -ForegroundColor Red
    Write-Host ">>>     python -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id=<hf-id>, local_dir=<target>, max_workers=4)'" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "=== AVAILABLE MODELS (subdirectories of $MODELS_DIR) ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ModelDirs.Count; $i++) {
    $Marker = if ($ModelDirs[$i].Name -like "*mmproj*") { " [vision projector -- pick main model, not this]" } else { "" }
    Write-Host "  [$($i + 1)] $($ModelDirs[$i].Name)$Marker" -ForegroundColor Yellow
}

$ModelSelection = Read-Host "`nSelect model index number"
$SelectedModelIdx = [int]$ModelSelection - 1
$SelectedModel = $ModelDirs[$SelectedModelIdx]
$ModelName = $SelectedModel.Name

# Guard: don't let a vision projector be picked as the main model.
if ($ModelName -like "*mmproj*") {
    Write-Host ">>> Invalid selection: '$ModelName' is a vision projector, not a chat model." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Sanity check: model subdir must contain a config.json or weight files
$HasConfig = Test-Path (Join-Path $SelectedModel.FullName "config.json")
$HasWeights = (Get-ChildItem -Path $SelectedModel.FullName -Include "*.safetensors", "*.exl3", "*.gguf" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
if (-not $HasConfig -and -not $HasWeights) {
    Write-Host ">>> WARNING: '$ModelName' contains no config.json or weight files -- TabbyAPI will likely fail to load it." -ForegroundColor Yellow
}

# --- 2.5 ADAPTIVE CONTEXT SIZE PER MODEL ---
# Hybrid Qwen3.5 (3x linear + 1x full attention, repeating) only needs KV cache for the
# full-attention layers. At Q4, the Qwen3.5 MoE models (40 layers, 10 full, kv_h=2) use
# just ~1.25 GB at 256K -- leaving plenty of room on 2x 5060 Ti 16 GB for the model
# itself (17-20 GB EXL3). Qwopus3.6-27B (64 layers, 16 full, kv_h=4) needs ~4 GB at 256K,
# still comfortable. Gemma-4 (5 full + 25 sliding(1024)) stays at ~2.5 GB Q4 at 256K.
#
# Add new models here as you install them. The safe default (no entry) is 128K, which
# always fits but wastes the long-context capability on most hybrid models.
$ModelContextMap = @{
    "Kwaipilot_KAT-Coder-V2.5-Dev-EXL3-4bpw"        = 262144   # 256K -- 1.25 GB Q4 cache
    "Huihui-Qwen3.6-35B-A3B-abliterated-exl3-4.5bpw" = 262144   # 256K -- 1.25 GB Q4 cache
    "Ornith-1.5-35B-A3B-EXL3-4bpw"                   = 262144   # 256K -- 1.25 GB Q4 cache; 3113 mtp.* tensors verified (real MTP head)
    "Ornith-1.0-35B-EXL3-4.0bpw"                     = 262144   # 256K -- 1.25 GB Q4 cache
    "Qwopus3.6-27B-v2-exl3-6.00bpw"                  = 196608   # 192K -- 4 GB Q4 cache, headroom for 6bpw weights
    "Gemma-4-26B-A4B-it-exl3-5.10bpw"                = 262144   # 256K -- 2.5 GB Q4 cache (sliding window 1024)
    # Qwen3.8-27B measured on 2x RTX 5060 Ti 16 GB:
    #   quant    MTP=ON  MTP=OFF
    #   6.00bpw   96K    128K      MTP costs ~3-4 GB at 6bpw
    #   4.00bpw  128K    128K      192K loaded but OOMs at runtime
    #                               (exllamav3/reconstruct_hgemm temp buffer
    #                               needs ~1 GB headroom; only 1.2 GB free at
    #                               192K+MTP=ON). 128K + chunk_size=1024
    #                               leaves ~1.8 GB free -- safe.
    # 6bpw OFF bumps 98304 -> 131072 via the MTP toggle.
    # 4bpw MTP toggle is context-neutral (same ceiling both ways).
    "Qwen3.8-27B-exl3-6.00bpw"                       = 98304    # MTP=ON; OFF bumps to 131072
    "Qwen3.8-27B-exl3-4.00bpw"                       = 131072   # runtime-safe at MTP=ON with chunk_size=1024
}
$AdaptiveContextSize = $ModelContextMap[$ModelName]
if ($AdaptiveContextSize) {
    Write-Host ">>> Adaptive context: $ModelName -> $AdaptiveContextSize tokens ($([math]::Round($AdaptiveContextSize/1024))K)" -ForegroundColor DarkGreen
    $ContextSize = $AdaptiveContextSize
} else {
    Write-Host ">>> No context hint for '$ModelName' -- keeping safe default $ContextSize tokens" -ForegroundColor DarkYellow
}

# --- 2.6 OPTIONAL CPU/RAM OFFLOAD FOR KV CACHE ---
# Exllamav3's paged cache allocator auto-spills KV cache to system RAM the moment the
# chosen $ContextSize no longer fits alongside the model in VRAM. No flag is needed --
# the spill is transparent. Performance cost when offload kicks in:
#   * Prompt processing (prefill): 5-10x slower for the offloaded portion (PCIe-bound)
#   * Token generation (decode):    30-50% slower if most of the cache lives in RAM
#   * First-token latency (TTFT):  5-10x higher on long prompts
#
# To INTENTIONALLY force aggressive RAM offload (e.g., running a 70B model on 32 GB
# VRAM and spilling everything else), set before launching:
#
#     $env:TABBYAPI_FORCE_RAM_OFFLOAD = "1"
#
# Then also add `chunk_size: 1024` under the `model:` section of config.yml -- smaller
# chunks mean more frequent VRAM<->RAM transfers (slower) but lower peak VRAM (more
# headroom for weights). The default chunk_size (2048) is fine for the 256K Q4 configs
# above (KAT-Coder / Huihui / Ornith / Gemma-4) and for Qwopus3.6 6bpw. For Qwen3.8-
# 27B 4bpw/6bpw with MTP=ON it must be 1024 even WITHOUT RAM offload -- the EXL3
# reconstruct_hgemm temp buffer collides with the KV cache at default chunk size.
$ForceRamOffload = $env:TABBYAPI_FORCE_RAM_OFFLOAD -eq "1"
if ($ForceRamOffload) {
    Write-Host ">>> TABBYAPI_FORCE_RAM_OFFLOAD=1 -- KV cache will spill to RAM aggressively" -ForegroundColor DarkYellow
    Write-Host "    Add 'chunk_size: 1024' under model: in config.yml for tighter chunks" -ForegroundColor DarkYellow
    Write-Host "    Expect 5-10x slower prompt processing, 30-50% slower generation" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host ">>> Selected model: $ModelName (context=$ContextSize, cache=$CacheMode)" -ForegroundColor Green

# --- 2.7 ENSURE PER-MODEL tabby_config.yml EXISTS ---
# Without a per-model tabby_config.yml, TabbyAPI loads the model's bundled
# chat_template.jinja but leaves tool_format empty. The bundled Qwen3.x template
# renders pseudo-XML tool calls (`<tool_call><function=...><parameter=...>
# ...</parameter></function></tool_call>`) directly into the prompt, but with
# tool_format unset the server can't parse them -- they leak out as raw text in
# `content`, so the chat client (Pi) sees `<function=read>...</function>` instead
# of a proper tool_calls array. The model "thinks" it called the tool; nothing
# actually executes; the turn stalls. This is the same root cause the PI
# script's --chat-template-file fix addresses, just at a different layer
# (TabbyAPI uses Exllamav3, no chat-template CLI flag exists -- per-model
# YAML is the only override point).
#
# Setting tool_format: qwen3_coder routes every tool-related stream through
# endpoints/OAI/utils/toolcall_formats/qwen3_coder.py, which uses DOTALL
# non-greedy regex (`<tool_call>(.*?)</tool_call>`). Malformed closing triples
# without an opener (model hallucination at long context) don't match anything
# -> parser returns [] -> finish_reason="stop" -> Pi continues normally.
#
# Other models in $MODELS_DIR ship with hand-written tabby_config.yml files;
# we auto-generate one here for any model that doesn't have one so freshly-
# installed models work on first launch without manual editing.
#
# Self-heal path: if an existing tabby_config.yml was generated by an earlier
# buggy version of this section (vision: true with no mmproj projector in the
# model dir -- which crashes Exllamav3 during load), rewrite it. The script
# created that broken state; the script must clean it up.
$PerModelTabbyConfigPath = Join-Path $SelectedModel.FullName "tabby_config.yml"

# Detect mmproj projector. Exllamav3's vision support requires a matching
# mmproj*.safetensors (or .gguf / .exl3) file in the model directory. Setting
# vision: true without one crashes the server during model load -- it tries
# to allocate vision buffers / load vision weights that don't exist, exits
# with code 1 during "Loading with autosplit" (see logs/2026-08-17_13-29-21
# for the failure pattern). Vision is therefore disabled unless an mmproj
# file is actually present.
$HasMMProj = (Get-ChildItem -Path $SelectedModel.FullName -Filter "mmproj*" -ErrorAction SilentlyContinue).Count -gt 0

# Detect a quantized MTP (Multi-Token Prediction) head. Qwen3.5/3.6/3.8-family
# models can carry an MTP head inside the main weights; enabling it as a draft
# model gives ~1.5x generation speed at near-zero VRAM cost.
#
# The discriminator is MODEL METADATA, never the filename -- these quants have
# no "-MTP-" suffix but do have the head:
#   config.json -> text_config.mtp_num_hidden_layers = 1
#   config.json -> quantization_config.mtp_bits      = 4
#
# CRITICAL: unlike GGUF (where conversion always carries the head, so the
# llama.cpp launcher can enable draft-mtp for the whole Qwen3.x family), EXL3
# only retains the head if the quantizer ran with --mtp_bits. In C:/ModelsExl3
# ONLY Qwen3.8-27B-exl3-6.00bpw has it -- Qwopus3.6, Huihui-Qwen3.6, Ornith,
# KAT-Coder and Gemma-4 all have zero mtp.* tensors despite Qwen3.6 lineage.
# exllamav3 does `del self.model_classes["mtp"]` when mtp_num_hidden_layers==0,
# so a blanket family-based gate would CRASH model load on those. Read metadata.
$MtpLayers = 0
$ModelCfgJsonPath = Join-Path $SelectedModel.FullName "config.json"
if (Test-Path $ModelCfgJsonPath) {
    try {
        $ModelCfgJson = Get-Content $ModelCfgJsonPath -Raw | ConvertFrom-Json
        # Multimodal configs nest the text params under text_config; dense
        # text-only configs put them at the top level. Check both.
        $TextCfg = if ($ModelCfgJson.PSObject.Properties['text_config']) { $ModelCfgJson.text_config } else { $ModelCfgJson }
        if ($TextCfg -and $TextCfg.PSObject.Properties['mtp_num_hidden_layers']) {
            $MtpLayers = [int]$TextCfg.mtp_num_hidden_layers
        }
    } catch {
        Write-Host "    (config.json unparseable -- MTP detection skipped)" -ForegroundColor DarkYellow
    }
}

# SECOND GATE, AND THE AUTHORITATIVE ONE: config.json is NOT trustworthy here.
# It is copied verbatim from the upstream HF repo, so it keeps advertising
# mtp_num_hidden_layers=1 even when the EXL3 quantizer ran WITHOUT --mtp_bits
# and silently dropped the head. Measured in C:/ModelsExl3:
#
#   model                                    cfg_says  mtp_bits  real mtp.* tensors
#   Qwen3.8-27B-exl3-6.00bpw                    1         4            39   <- real
#   Huihui-Qwen3.6-35B-A3B-abliterated          1        none           0    <- LIES
#   Ornith-1.0-35B-EXL3-4.0bpw                  1        none           0    <- LIES
#   Qwopus3.6-27B-v2-exl3-6.00bpw               1        none           0    <- LIES
#   Kwaipilot_KAT-Coder-V2.5-Dev                0        none           0
#   Gemma-4-26B-A4B-it-exl3-5.10bpw            none      none           0
#
# Trusting config.json alone would enable MTP on three models whose weights
# can't support it. That case is WORSE than a silent no-op: because config.json
# claims the head exists, exllamav3 keeps model_classes["mtp"] alive and only
# fails later while loading the missing tensors -- i.e. a hard model-load crash
# on 3 of 6 models. So require the tensors to actually be present.
if ($MtpLayers -gt 0) {
    $SafetensorsIndex = Join-Path $SelectedModel.FullName "model.safetensors.index.json"
    $MtpTensorCount = 0
    if (Test-Path $SafetensorsIndex) {
        # Plain substring scan on the raw text -- far cheaper than ConvertFrom-Json
        # on a multi-thousand-key weight map, and we only need presence/absence.
        $MtpTensorCount = ([regex]::Matches((Get-Content $SafetensorsIndex -Raw), '"mtp\.')).Count
    }
    if ($MtpTensorCount -eq 0) {
        Write-Host ">>> '$ModelName' advertises an MTP head in config.json but its EXL3 quant contains NO mtp.* tensors" -ForegroundColor DarkYellow
        Write-Host "    (quantized without --mtp_bits) -- speculative decoding stays OFF to avoid a load crash." -ForegroundColor DarkYellow
        $MtpLayers = 0
    } else {
        Write-Host ">>> MTP head verified in '$ModelName': $MtpLayers layer, $MtpTensorCount mtp.* tensors -- speculative decoding available" -ForegroundColor Magenta
    }
}

# --- 2.5.1 INTERACTIVE MTP TOGGLE (only Qwen3.8-27B has a verifiable MTP head) ---
# Per-model measured ceilings on 2x RTX 5060 Ti 16 GB (verified by direct probe):
#   quant    MTP=ON  MTP=OFF  -> when MTP turns OFF we reclaim 3-4 GB headroom
#   6bpw      96K    128K     -> bump from 98304 to 131072 (128K)
#   4bpw     192K    192K     -> no change (toggle is context-neutral)
#
# Default is ON ([Y/n] -- empty Enter = Y) so existing behavior is preserved
# unless the user explicitly opts out.
if ($MtpLayers -gt 0) {
    Write-Host ""
    Write-Host ">>> MTP speculative decoding available on '$ModelName'." -ForegroundColor Magenta
    if ($ModelName -eq "Qwen3.8-27B-exl3-6.00bpw") {
        Write-Host "    ON  : ~1.5x generation speed; context capped at 96K (MTP costs ~3-4 GB VRAM headroom)" -ForegroundColor DarkCyan
        Write-Host "    OFF : context bumped to 128K -- MTP headroom reclaimed" -ForegroundColor DarkCyan
    }
    elseif ($ModelName -eq "Qwen3.8-27B-exl3-4.00bpw") {
        Write-Host "    ON  : ~1.5x generation speed; context capped at 128K (192K OOMs at runtime -- reconstruct_hgemm temp buffer)" -ForegroundColor DarkCyan
        Write-Host "    OFF : context stays at 128K -- 4bpw has plenty of VRAM at this size in both modes" -ForegroundColor DarkCyan
    }
    else {
        Write-Host "    ON/OFF: measured ceilings may differ -- this model is untested in both modes" -ForegroundColor DarkCyan
    }
    $MtpChoice = Read-Host "Enable MTP speculative decoding? [Y/n]"
    if ($MtpChoice -match '^(n|N|no|NO)$') {
        $MtpLayers = 0
        if ($ModelName -eq "Qwen3.8-27B-exl3-6.00bpw" -and $ContextSize -eq 98304) {
            $ContextSize = 131072
            Write-Host ">>> MTP disabled by user choice -- context bumped 96K -> 128K." -ForegroundColor Yellow
        }
        else {
            Write-Host ">>> MTP disabled by user choice -- context unchanged at $ContextSize." -ForegroundColor Yellow
        }
    } else {
        Write-Host ">>> MTP enabled by user choice -- context stays at $ContextSize." -ForegroundColor DarkGreen
    }
}

# The draft_model block emitted into tabby_config.yml when an MTP head exists.
# NOTE: this is a TOP-LEVEL key, not nested under `model:` -- the per-model
# loader reads inline_config.get("draft_model") directly (common/model.py:105).
# draft_model_name / draft_model_dir are deliberately omitted: in mtp mode
# exllamav3 loads the head from the model's own folder.
# draft_cache_mode Q4 because the MTP head gets its OWN KV cache which TabbyAPI
# defaults to FP16 regardless of the main --cache-mode (model.py:366): ~536 MB
# at 131072 ctx vs ~134 MB at Q4. Output is unaffected -- rejected drafts are
# re-rolled by the main model; only the acceptance rate changes.
$MtpYamlLines = @(
    ""
    "# MTP speculative decoding -- head lives inside this model's own weights"
    "# (text_config.mtp_num_hidden_layers=$MtpLayers). ~1.5x generation speed."
    "# Do NOT copy to models without mtp.* tensors: exllamav3 will fail to load."
    "draft_model:"
    "  draft_mode: mtp"
    "  draft_cache_mode: Q4"
    "  draft_num_tokens: 4"
)

# --- 2.5.2 INTERACTIVE REASONING TOGGLES (enable_thinking, reasoning_effort) ---
# These two keys live under model.template_vars_force in tabby_config.yml and
# override anything the client (Pi) sends -- resolve_template_vars in
# endpoints/OAI/utils/chat_completion.py:400-432 gives template_vars_force the
# highest priority of all sources.
#
# Defaults below match the hand-tuned config in the 6bpw model dir (and the
# copy I just seeded for 4bpw): enable_thinking=false + reasoning_effort=low.
# Both can be flipped per-launch without editing tabby_config.yml by hand;
# changes apply via the per-model YAML rewriter in section 2.9 below.
#
# Only meaningful for reasoning-capable models (Qwen3.5/3.6/3.8, Ornith,
# KAT-Coder, Qwopus, Gemma-4 with channel|thought). For non-reasoning models
# the parser would still strip the <think> block but no client ever sees it
# (Pi doesn't render reasoning_content unless the client asks for stream).
$EnableThinking = $false
$ReasoningEffort = "low"
$ModelNameLowerForCfg = $ModelName.ToLower()
if ($ModelNameLowerForCfg -like "*qwen*" -or $ModelNameLowerForCfg -like "*ornith*" -or $ModelNameLowerForCfg -like "*kat*" -or $ModelNameLowerForCfg -like "*qwopus*") {
    Write-Host ""
    Write-Host ">>> Reasoning settings for '$ModelName':" -ForegroundColor Magenta
    Write-Host "    Default in tabby_config.yml: enable_thinking=false, reasoning_effort=low" -ForegroundColor DarkCyan

    $ThinkingChoice = Read-Host "Enable thinking (show <think> blocks in client)? [y/N]"
    $EnableThinking = $ThinkingChoice -match '^(y|Y|yes|YES)$'

    $EffortChoice = Read-Host "Reasoning effort [low/medium/xhigh, default=low]"
    if ($EffortChoice -match '^(medium|xhigh|low)$') {
        $ReasoningEffort = $EffortChoice
    } elseif ($EffortChoice) {
        Write-Host "    invalid '$EffortChoice' -- keeping default '$ReasoningEffort'" -ForegroundColor DarkYellow
    }

    Write-Host ">>> -> enable_thinking=$EnableThinking, reasoning_effort=$ReasoningEffort" -ForegroundColor DarkGreen
}

# Detect an existing tabby_config.yml that's in the broken state the buggy
# first version of this section produced (vision: true with no mmproj). The
# script created that state; the script must clean it up. Without the fixup
# the file would persist forever and crash TabbyAPI on every launch.
$NeedsVisionFixup = $false
if (Test-Path $PerModelTabbyConfigPath) {
    $ExistingCfgRaw = Get-Content $PerModelTabbyConfigPath -Raw
    if ($ExistingCfgRaw -match '(?m)^\s*vision:\s*true\s*$' -and -not $HasMMProj) {
        $NeedsVisionFixup = $true
        Write-Host ">>> tabby_config.yml has vision: true but no mmproj file -- fixing in place..." -ForegroundColor DarkYellow
    }
}

if (-not (Test-Path $PerModelTabbyConfigPath) -or $NeedsVisionFixup) {
    if (-not (Test-Path $PerModelTabbyConfigPath)) {
        Write-Host ">>> No tabby_config.yml in '$ModelName' -- auto-creating one..." -ForegroundColor DarkYellow
    }

    $ToolFormat   = $null
    $ReasonStart  = "<think>"
    $ReasonEnd    = "</think>"
    $Vision       = if ($HasMMProj) { "true" } else { "false" }

    if ($ModelNameLowerForCfg -like "*gemma*") {
        $ToolFormat  = "gemma4"
        $ReasonStart = "<|channel>thought"
        $ReasonEnd   = "<channel|>"
    }
    elseif ($ModelNameLowerForCfg -like "*qwen*" -or $ModelNameLowerForCfg -like "*ornith*" -or $ModelNameLowerForCfg -like "*kat*" -or $ModelNameLowerForCfg -like "*qwopus*") {
        # qwen3_coder alias covers Qwen3.5 / Qwen3.6 / Qwen3-Coder / Qwen3.8
        # and any Qwen-derivative (Ornith, KAT-Coder, Qwopus). Pseudo-XML format
        # is identical across these -- only the underlying template's reasoning
        # effort defaults differ.
        $ToolFormat = "qwen3_coder"
    }
    else {
        Write-Host "    WARNING: unknown architecture -- tool_format left blank." -ForegroundColor Yellow
        Write-Host "    You'll need to write tabby_config.yml by hand if this model uses tool calls." -ForegroundColor Yellow
    }

    # Build YAML body. Field order matches the hand-written files in the other
    # model dirs (prompt_template -> parser -> reasoning -> vision -> logging).
    $Provenance = if ($NeedsVisionFixup) {
        "Auto-fixed (vision flipped true->false, no mmproj in model dir) on $((Get-Date).ToString('u'))"
    } else {
        "Auto-generated on $((Get-Date).ToString('u'))"
    }
    $YamlLines = @(
        "# $Provenance by run_local_ai_TabbyAPI.ps1"
        "# Per-model overrides for $ModelName. Picked up automatically when this"
        "# model loads (priority: tabby_config.yml > config.yml > startup args)."
        "# Edit by hand to override any of these values."
        "model:"
        "  prompt_template:"
    )
    if ($ToolFormat) {
        $YamlLines += "  tool_format: $ToolFormat"
    }
    $YamlLines += @(
        "  reasoning: true"
        "  reasoning_start_token: `"$ReasonStart`""
        "  reasoning_end_token: `"$ReasonEnd`""
        "  vision: $Vision"
        "  log_prompt: false"
        "  log_generation_params: false"
        "  log_requests: false"
        "  log_chat_completion_requests: false"
        "  template_vars_force:"
        "    enable_thinking: $(if ($EnableThinking) { 'true' } else { 'false' })"
        "    reasoning_effort: $ReasoningEffort"
    )
    if ($MtpLayers -gt 0) { $YamlLines += $MtpYamlLines }
    $YamlBody = ($YamlLines -join "`r`n") + "`r`n"

    # Write WITHOUT UTF-8 BOM (Set-Content -Encoding UTF8 adds BOM on PowerShell
    # 5.1, which breaks PyYAML's loader and the launcher script itself).
    [System.IO.File]::WriteAllText($PerModelTabbyConfigPath, $YamlBody, (New-Object System.Text.UTF8Encoding $false))
    $Verb = if ($NeedsVisionFixup) { "fixed" } else { "wrote" }
    Write-Host "    $Verb $PerModelTabbyConfigPath (tool_format=$ToolFormat, vision=$Vision)" -ForegroundColor DarkGreen
}

# --- 2.8 BACKFILL OR STRIP MTP DRAFT BLOCK IN AN EXISTING tabby_config.yml ---
# Section 2.7 only writes a whole file when none exists (or when the vision
# fixup fires). Models installed before MTP support was added -- and the
# hand-written tabby_config.yml files in the other model dirs -- already have a
# file, so they'd never gain the draft_model block.
#
# Two paths here:
#   * $MtpLayers > 0  AND  no draft_mode: line  -> APPEND the block (idempotent
#                                                  non-destructive backfill).
#   * $MtpLayers == 0 AND  draft_mode: line present -> STRIP the block. The
#                                                  toggle in 2.5.1 can flip a
#                                                  model from MTP=ON to MTP=OFF
#                                                  mid-session; the per-model
#                                                  config must reflect that or
#                                                  TabbyAPI keeps loading the
#                                                  MTP head and crashes at
#                                                  autosplit with the same OOM
#                                                  regardless of what the
#                                                  launcher was told.
#
# Only fires when the model actually has/had an MTP head, so the hand-written
# non-MTP configs in the other model dirs are never touched.
if (Test-Path $PerModelTabbyConfigPath) {
    $ExistingCfgForMtp = Get-Content $PerModelTabbyConfigPath -Raw
    $HasDraftBlock = $ExistingCfgForMtp -match '(?m)^\s*draft_mode:'

    if ($MtpLayers -gt 0 -and -not $HasDraftBlock) {
        Write-Host ">>> '$ModelName' has an MTP head but no draft_model block -- appending..." -ForegroundColor DarkYellow
        if ($ExistingCfgForMtp -notmatch '\r?\n$') { $ExistingCfgForMtp += "`r`n" }
        $ExistingCfgForMtp += ($MtpYamlLines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($PerModelTabbyConfigPath, $ExistingCfgForMtp, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "    appended draft_model block (mtp, Q4 draft cache, 4 draft tokens)" -ForegroundColor DarkGreen
    }
    elseif ($MtpLayers -eq 0 -and $HasDraftBlock) {
        Write-Host ">>> '$ModelName' MTP=OFF but tabby_config.yml still has draft_model block -- stripping..." -ForegroundColor DarkYellow
        # Match the MtpYamlLines block: blank separator line, 2 comment lines,
        # then `draft_model:` and its 3 indented children. Multiline + non-greedy
        # so the regex stops at the first non-matching line (any future top-level
        # key after draft_model isn't eaten).
        $ExistingCfgForMtp = [regex]::Replace(
            $ExistingCfgForMtp,
            '(?ms)^\r?\n?# MTP speculative decoding.*?^\s*draft_num_tokens:\s*\d+\s*\r?\n',
            '',
            [System.Text.RegularExpressions.RegexOptions]::Multiline
        )
        # Trim any trailing blank lines the strip may have left behind so the
        # file ends cleanly with a single trailing newline.
        $ExistingCfgForMtp = [regex]::Replace($ExistingCfgForMtp, '(?ms)(\r?\n){3,}', "`r`n`r`n")
        [System.IO.File]::WriteAllText($PerModelTabbyConfigPath, $ExistingCfgForMtp, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "    removed draft_model block (reclaiming ~3-4 GB VRAM headroom)" -ForegroundColor DarkGreen
    }
    elseif ($MtpLayers -gt 0 -and $HasDraftBlock) {
        Write-Host ">>> MTP speculative decoding already configured in tabby_config.yml" -ForegroundColor DarkGreen
    }
}

# --- 2.9 UPDATE template_vars_force IN EXISTING tabby_config.yml ---
# The reasoning toggles in 2.5.2 produce $EnableThinking and $ReasoningEffort.
# When the file already exists, section 2.7 only writes if the file is missing
# or the vision fixup fires -- so existing per-model configs would never pick
# up the user's current session choices.
#
# Update the two keys in place; if template_vars_force doesn't exist at all
# (older hand-written configs), append a fresh block. Idempotent and
# non-destructive (the MTP block, tool_format, etc. are untouched).
if (Test-Path $PerModelTabbyConfigPath) {
    $ExistingCfg = Get-Content $PerModelTabbyConfigPath -Raw
    $HasTvForce = $ExistingCfg -match '(?m)^\s*template_vars_force:'
    $ThinkingStr = if ($EnableThinking) { 'true' } else { 'false' }

    if ($HasTvForce) {
        # Replace the existing enable_thinking / reasoning_effort values in place.
        # Whitespace-tolerant: matches 2-space or 4-space indent.
        $newCfg = [regex]::Replace($ExistingCfg, '(?m)^(\s*)enable_thinking:\s*\S+\s*$', "`$1enable_thinking: $ThinkingStr", 'Multiline')
        $newCfg = [regex]::Replace($newCfg,            '(?m)^(\s*)reasoning_effort:\s*\S+\s*$',  "`$1reasoning_effort: $ReasoningEffort", 'Multiline')
        if ($newCfg -ne $ExistingCfg) {
            [System.IO.File]::WriteAllText($PerModelTabbyConfigPath, $newCfg, (New-Object System.Text.UTF8Encoding $false))
            Write-Host ">>> updated template_vars_force: enable_thinking=$ThinkingStr, reasoning_effort=$ReasoningEffort" -ForegroundColor DarkGreen
        }
    }
    else {
        # No template_vars_force block at all -- append one. Place it BEFORE
        # any draft_model block so the structure stays grouped (model: first,
        # then top-level).
        $tvBlock = @(
            "",
            "# Per-session reasoning settings (added by 2.9 because the model",
            "# dir shipped without template_vars_force). Edit by hand to override.",
            "model:",
            "  template_vars_force:",
            "    enable_thinking: $ThinkingStr",
            "    reasoning_effort: $ReasoningEffort"
        )
        if ($ExistingCfg -notmatch '\r?\n$') { $ExistingCfg += "`r`n" }
        $ExistingCfg += ($tvBlock -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($PerModelTabbyConfigPath, $ExistingCfg, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ">>> appended template_vars_force block (enable_thinking=$ThinkingStr, reasoning_effort=$ReasoningEffort)" -ForegroundColor DarkGreen
    }
}

# --- 3. INTERACTIVE PROJECT WORKING DIRECTORY SELECTION ---
$ProjectDirs = Get-ChildItem -Path $PROJECTS_DIR -Directory -ErrorAction SilentlyContinue
if ($ProjectDirs.Count -eq 0) { Write-Error "Error: No project environments discovered inside $PROJECTS_DIR" }

Write-Host ""
Write-Host "=== TARGET WORKSPACE PROJECTS ===" -ForegroundColor Cyan
for ($i = 0; $i -lt $ProjectDirs.Count; $i++) {
    Write-Host "  [$($i + 1)] $($ProjectDirs[$i].Name)" -ForegroundColor Yellow
}

$ProjectSelection = Read-Host "`nSelect project index number"
$TargetProjectDir = $ProjectDirs[[int]$ProjectSelection - 1].FullName

# --- 4. INJECT SELECTED MODEL INTO config.yml ---
# We use config.yml for static settings (disable_auth, model_dir) and override
# model_name AND cache_size via in-place edits. The CLI args alone are unreliable
# when config.yml is loaded (the merger keeps the config's values), so we update
# config.yml in-place.
#
# cache_size MUST match the adaptive $ContextSize (262144 for KAT-Coder / Huihui /
# Ornith / Gemma-4, 196608 for Qwopus) -- otherwise TabbyAPI silently caps the
# actual KV cache at the stale 131072 from config.yml and rejects prompts with
# "Initial job allocation requires N cache tokens, which exceeds the available
# context size of 131072 tokens" even when --max-seq-len 262144 is passed.
#
# Three-step write so the launcher is robust to linters / manual edits that move
# the model_name / cache_size lines out of the `model:` block (which makes TabbyAPI
# silently skip model loading on startup, breaking chat with 500 / "Connection error"):
#   1. Strip ANY existing `model_name:` line, no matter how indented or where
#   2. Strip ANY existing `cache_size:` line (so the adaptive value wins)
#   3. Insert a fresh `  model_name: ...` and `  cache_size: $ContextSize` (2-space
#      indent) right after `model_dir:`
# Step 3 always lands inside the `model:` block, restoring correct YAML structure.
if (!(Test-Path $CONFIG_FILE)) {
    Write-Host ">>> ERROR: $CONFIG_FILE not found. Aborting." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
$ConfigText = Get-Content -Path $CONFIG_FILE -Raw
# 1. Remove every existing model_name: line (handles linter-moved or duplicate)
$ConfigText = [regex]::Replace(
    $ConfigText,
    '^[ \t]*model_name:.*\r?\n?',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
# 2. Remove every existing cache_size: line -- so the adaptive $ContextSize below
# wins over the stale 131072 that ships in config.yml. Without this, TabbyAPI
# caps the KV cache at 131072 and rejects prompts over 128K with
# "context_length_exceeded" / "Initial job allocation requires N cache tokens".
$ConfigText = [regex]::Replace(
    $ConfigText,
    '^[ \t]*cache_size:.*\r?\n?',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
# 3. Insert model_name and cache_size immediately after model_dir:
$ConfigText = [regex]::Replace(
    $ConfigText,
    '(^[ \t]*model_dir:[^\r\n]*\r?\n)',
    "`$1  model_name: $ModelName`r`n  cache_size: $ContextSize`r`n",
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)
# Write WITHOUT UTF-8 BOM. Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
# adds a BOM by default, which breaks JSON parsers and the launcher script itself.
# UTF8Encoding($false) writes raw UTF-8 bytes with no BOM.
[System.IO.File]::WriteAllText($CONFIG_FILE, $ConfigText, (New-Object System.Text.UTF8Encoding $false))

# --- 5. TABBYAPI SERVER ARGUMENT BUILDER ---
# config.yml supplies: host=0.0.0.0, port=5000, disable_auth=true, model_dir,
# model_name (just rewritten above), cache_size (just rewritten above). CLI
# overrides below are for runtime tuning.
$TabbyArgs = @(
    "--config", "$CONFIG_FILE",
    "--max-seq-len", "$ContextSize",
    "--cache-mode", "$CacheMode",
    "--gpu-split-auto", "true"
)

Write-Host ""
Write-Host ">>> Launching TabbyAPI (Exllamav3 backend) on port $Port..." -ForegroundColor Green
Write-Host "    python main.py $($TabbyArgs -join ' ')" -ForegroundColor DarkCyan
Write-Host "    context=$ContextSize  kv_cache=$CacheMode  gpu_split=auto (2x RTX 5060 Ti)" -ForegroundColor DarkCyan

# --- 6. DETACHED SERVER INITIALIZATION ---
Write-Host ">>> Launching TabbyAPI (server console stays visible for live metrics)..." -ForegroundColor Green
# Start-Process -ArgumentList wants a single string array. The first element is
# the script path, the rest are CLI args. Combining into one @() avoids the
# "Cannot convert System.Object[] to System.String" error you'd get from
# passing ("main.py", $TabbyArgs) directly.
#
# WindowStyle Normal (default) so loguru's RICH_CONSOLE.print sink writes
# colored output -- including the Metrics line with prompt/generate T/s and
# context -- straight into the python.exe window. The user sees live metrics
# the same way llama.cpp's window did. Closing this launcher does not stop
# the python process; closing the python window does stop it.
$ProcessArgs = @("main.py") + $TabbyArgs
$ServerProc = Start-Process -FilePath "$VENV_PYTHON" `
                             -ArgumentList $ProcessArgs `
                             -WorkingDirectory "$TABBY_DIR" `
                             -WindowStyle Normal -PassThru

# --- 7. STARTUP READINESS POLL ---
# First load of a new model builds the EXL3 cache (~30-60s on RTX 5060 Ti for 19GB).
# Subsequent loads read the prebuilt cache from disk in 5-10s. Generous timeout.
$TimeoutSec = 240
$HealthUrl  = "http://127.0.0.1:$Port/health"
$Ready  = $false
$Waited = 0
Write-Host ">>> Waiting for $HealthUrl endpoint (up to $TimeoutSec s; first load builds EXL3 cache)..." -ForegroundColor Yellow

while ($Waited -lt $TimeoutSec) {
    Start-Sleep -Seconds 2
    $Waited += 2
    $ServerProc.Refresh()

    if ($ServerProc.HasExited) {
        Write-Host "`n>>> TABBYAPI CRASHED on startup. Exit code: $($ServerProc.ExitCode)" -ForegroundColor Red
        Write-Host ">>> Check the launched console window for the actual error (torch / CUDA / model)." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    try {
        $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            $Ready = $true
            break
        }
    } catch { }
}

if (-not $Ready) {
    Write-Host "`n>>> TabbyAPI did not become ready in $TimeoutSec seconds." -ForegroundColor Red
    if (-not $ServerProc.HasExited) {
        try { $ServerProc.Kill() } catch {}
    }
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ">>> TabbyAPI is ready after $Waited s on port $Port." -ForegroundColor Green

# --- 7.5 PRINT API INFO ---
Write-Host ""
Write-Host ">>> API endpoints (use these from your client):" -ForegroundColor Cyan
Write-Host "    Base URL  : http://127.0.0.1:$Port/v1" -ForegroundColor White
Write-Host "    Model     : $ModelName" -ForegroundColor White
Write-Host "    Health    : $HealthUrl" -ForegroundColor White
Write-Host "    Models    : http://127.0.0.1:$Port/v1/models" -ForegroundColor White

# --- 7.6 VRAM SANITY CHECK ---
Write-Host ""
Write-Host ">>> GPU telemetry after model load:" -ForegroundColor DarkCyan
try {
    & nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv 2>$null
} catch {
    Write-Host ">>> (nvidia-smi unavailable; skip)" -ForegroundColor DarkYellow
}

# --- 7.7 GLOBAL SYSTEM-PROMPT (central, no per-project copy) ---
# Pi natively supports: --append-system-prompt <text|file>
# (appends file CONTENTS to Pi's base system prompt). We reuse the same global file
# the llama.cpp launcher references so behavior is identical regardless of backend.
$GlobalAgentsFile = "$env:USERPROFILE/.pi/agent/AGENTS.md"

$AppendPromptArg = ""
if (Test-Path $GlobalAgentsFile) {
    $AppendPromptArg = " --append-system-prompt '$GlobalAgentsFile'"
    Write-Host ">>> Global system prompt guaranteed via --append-system-prompt: $GlobalAgentsFile" -ForegroundColor Green
} else {
    Write-Host ">>> WARNING: global instructions file not found: $GlobalAgentsFile" -ForegroundColor Red
}

# --- 8. SWITCH PI TO THIS BACKEND ---
# Pi reads its config from ~/.pi/agent/settings.json (defaultProvider/defaultModel)
# and ~/.pi/agent/models.json (provider baseUrl, api key, model list). It does NOT
# read PI_API_BASE / PI_MODEL env vars -- those are session markers Pi sets for
# child processes, not config inputs.
#
# If a Pi session is already running with a different defaultProvider, we kill it
# so the new settings take effect on next launch.
$PiSettingsPath = "$env:USERPROFILE/.pi/agent/settings.json"
if (Test-Path $PiSettingsPath) {
    Write-Host ">>> Switching Pi to TabbyAPI provider (model: $ModelName)..." -ForegroundColor Cyan

    # Kill any running Pi (node.exe with pi-coding-agent in its command line).
    # Multiple passes: a single Get-CimInstance can race with a node that's
    # still starting up and miss it. Two rounds + a final wait for the
    # Windows kernel to release the settings file handle.
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
    Start-Sleep -Seconds 2   # let kernel release the settings.json file handle

    # Patch settings.json: switch provider to tabbyapi + set the selected model
    $PiSettings = Get-Content $PiSettingsPath -Raw | ConvertFrom-Json
    $PiSettings.defaultProvider = "tabbyapi"
    $PiSettings.defaultModel    = $ModelName
    # Write settings.json WITHOUT UTF-8 BOM (Set-Content -Encoding UTF8 adds BOM
    # on PowerShell 5.1, which breaks Pi's JSON parser). UTF8Encoding($false) =
    # raw UTF-8, no BOM.
    $PiSettings | ConvertTo-Json | ForEach-Object {
        [System.IO.File]::WriteAllText($PiSettingsPath, $_, (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "    settings.json -> defaultProvider=tabbyapi, defaultModel=$ModelName" -ForegroundColor Green

    # Auto-register the selected model in models.json (tabbyapi provider).
    # Without this entry, Pi's model-resolver can't find $ModelName in the
    # provider's model list and silently falls back to the first available
    # model of the first provider with valid auth (usually lmstudio). So
    # any new model that lands in $MODELS_DIR is automatically exposed to
    # Pi on the next launcher run without a separate manual edit.
    $ModelsPath = "$env:USERPROFILE/.pi/agent/models.json"
    $ModelsData = @{ providers = @{ } }
    if (Test-Path $ModelsPath) {
        try {
            $existingModels = Get-Content $ModelsPath -Raw | ConvertFrom-Json
            if ($existingModels -and $existingModels.providers) {
                $ModelsData.providers = @{ }
                foreach ($pName in $existingModels.providers.PSObject.Properties.Name) {
                    $ModelsData.providers[$pName] = $existingModels.providers.$pName
                }
            }
        } catch {
            Write-Host "    (models.json unreadable, rewriting from scratch)" -ForegroundColor DarkYellow
        }
    }
    # Preserve existing tabbyapi config if present, otherwise seed defaults.
    $tabbyapiEntry = $ModelsData.providers["tabbyapi"]
    if (-not $tabbyapiEntry) {
        $tabbyapiEntry = [PSCustomObject]@{
            baseUrl  = "http://127.0.0.1:5000/v1"
            api      = "openai-completions"
            apiKey   = "no-auth-needed"
            compat   = [PSCustomObject]@{
                supportsDeveloperRole   = $false
                supportsReasoningEffort = $false
            }
            models   = @()
        }
    }
    # Ensure the models array contains the picked model; add it if missing.
    $hasModel = $false
    if ($tabbyapiEntry.models) {
        foreach ($m in $tabbyapiEntry.models) {
            if ($m.id -eq $ModelName) { $hasModel = $true; break }
        }
    }
    if (-not $hasModel) {
        # New entries default to text + image (multimodal Qwen3.5/3.6 models
        # support both). reasoning: true because all our installed models
        # are thinking models; user can override per-model by editing
        # models.json after the fact.
        #
        # contextWindow: TabbyAPI's /v1/models does NOT expose context length
        # (only id/object/created/owned_by/logging/parameters -- no max_context).
        # Without this field, Pi falls back to 128000 hardcoded in
        # extensions/llama/provider.js:15. We pass the (possibly adapted)
        # $ContextSize from section 2.5 so the status bar / compaction logic
        # see the real number.
        #
        # thinkingLevelMap: Pi reads its INTERNAL thinking level (displayed
        # as "think:<level>" in the footer) independently of what gets sent to
        # the provider. Without this map, whatever the user picks in Pi
        # (default "medium") goes straight to TabbyAPI and overrides our
        # $ReasoningEffort unless template_vars_force is set -- which IS set,
        # but having the map makes Pi's send consistent and visible in its
        # own UI for debugging. All Pi levels funnel into the chosen level;
        # "off" -> null so a user who explicitly disables thinking doesn't
        # get the model reasoning anyway (template_vars_force is the real
        # override; this map just keeps Pi's wire consistent).
        $newEntry = [PSCustomObject]@{
            id            = $ModelName
            name          = "$ModelName (TabbyAPI/EXL3)"
            input         = @("text", "image")
            reasoning     = $true
            contextWindow = $ContextSize
        }
        # Only attach the map for reasoning-capable model families (Qwen3.x,
        # Ornith, KAT-Coder, Qwopus, Gemma-4). Gemma-4 isn't matched here --
        # the qwen3_coder alias covers the others -- but Gemma's reasoning
        # tokens are <|channel>thought/<channel|> not <think> so the template
        # vars behave differently. Skipping for now: Gemma falls back to
        # provider defaults, which still works.
        if ($ModelNameLowerForCfg -like "*qwen*" -or $ModelNameLowerForCfg -like "*ornith*" -or $ModelNameLowerForCfg -like "*kat*" -or $ModelNameLowerForCfg -like "*qwopus*") {
            $tlm = [ordered]@{
                off     = $null
                minimal = $ReasoningEffort
                low     = $ReasoningEffort
                medium  = $ReasoningEffort
                high    = $ReasoningEffort
                xhigh   = $ReasoningEffort
            }
            $newEntry | Add-Member -NotePropertyName thinkingLevelMap -NotePropertyValue $tlm -Force
        }
        if ($tabbyapiEntry.models) {
            $tabbyapiEntry.models = @($tabbyapiEntry.models) + @($newEntry)
        } else {
            $tabbyapiEntry.models = @($newEntry)
        }
        $ModelsData.providers["tabbyapi"] = $tabbyapiEntry
        $ModelsData | ConvertTo-Json -Depth 10 | ForEach-Object {
            [System.IO.File]::WriteAllText($ModelsPath, $_, (New-Object System.Text.UTF8Encoding $false))
        }
        Write-Host "    models.json -> tabbyapi.models appended '$ModelName' (contextWindow=$ContextSize, thinkingLevelMap=$ReasoningEffort)" -ForegroundColor Green
    } else {
        # Backfill: existing entries (added by previous runs of this script
        # before the contextWindow field existed) lack contextWindow, so Pi
        # silently uses its 128000 hardcoded fallback. Update in-place if
        # the value differs from the adaptive $ContextSize. Also backfill
        # thinkingLevelMap on Qwen/Ornith/KAT/Qwopus entries.
        $updated = $false
        foreach ($m in @($tabbyapiEntry.models)) {
            if ($m.id -eq $ModelName) {
                if ($m.PSObject.Properties['contextWindow'] -eq $null -or $m.contextWindow -ne $ContextSize) {
                    $m | Add-Member -NotePropertyName contextWindow -NotePropertyValue $ContextSize -Force
                    Write-Host "    models.json -> backfilled contextWindow=$ContextSize on '$ModelName'" -ForegroundColor DarkGreen
                    $updated = $true
                }
                if ($ModelNameLowerForCfg -like "*qwen*" -or $ModelNameLowerForCfg -like "*ornith*" -or $ModelNameLowerForCfg -like "*kat*" -or $ModelNameLowerForCfg -like "*qwopus*") {
                    $existingTlm = if ($m.PSObject.Properties['thinkingLevelMap']) { $m.thinkingLevelMap } else { $null }
                    $existingMedium = if ($existingTlm -and $existingTlm.PSObject.Properties['medium']) { $existingTlm.medium } else { $null }
                    if ($existingMedium -ne $ReasoningEffort) {
                        $tlm = [ordered]@{
                            off     = $null
                            minimal = $ReasoningEffort
                            low     = $ReasoningEffort
                            medium  = $ReasoningEffort
                            high    = $ReasoningEffort
                            xhigh   = $ReasoningEffort
                        }
                        $m | Add-Member -NotePropertyName thinkingLevelMap -NotePropertyValue $tlm -Force
                        Write-Host "    models.json -> set thinkingLevelMap=$ReasoningEffort on '$ModelName'" -ForegroundColor DarkGreen
                        $updated = $true
                    }
                }
                if ($updated) { break }
            }
        }
        if ($updated) {
            $ModelsData.providers["tabbyapi"] = $tabbyapiEntry
            $ModelsData | ConvertTo-Json -Depth 10 | ForEach-Object {
                [System.IO.File]::WriteAllText($ModelsPath, $_, (New-Object System.Text.UTF8Encoding $false))
            }
        }
    }

    # Patch auth.json: register tabbyapi as a configured provider. Pi's
    # model-resolver requires hasConfiguredAuth(provider) to return true
    # before honoring settings.json's defaultProvider. Without a stored
    # credential, resolveProviderAuth falls through to env-var lookup which
    # fails for the static "no-auth-needed" key in models.json -- so Pi
    # silently drops back to lmstudio/local-coder-model (the first provider
    # in models.json). Writing a stored api_key credential here makes the
    # auth check pass and keeps tabbyapi as the active provider.
    $AuthPath = "$env:USERPROFILE/.pi/agent/auth.json"
    $AuthData = @{}
    if (Test-Path $AuthPath) {
        try {
            $existing = Get-Content $AuthPath -Raw | ConvertFrom-Json
            if ($existing) {
                foreach ($prop in $existing.PSObject.Properties) {
                    $AuthData[$prop.Name] = $prop.Value
                }
            }
        } catch {
            Write-Host "    (auth.json unreadable, rewriting from scratch)" -ForegroundColor DarkYellow
        }
    }
    $AuthData["tabbyapi"] = @{
        type = "api_key"
        key  = "no-auth-needed"
    }
    $AuthData | ConvertTo-Json | ForEach-Object {
        [System.IO.File]::WriteAllText($AuthPath, $_, (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "    auth.json -> tabbyapi registered as configured provider" -ForegroundColor Green
} else {
    Write-Host ">>> WARNING: $PiSettingsPath not found; Pi will not auto-switch providers." -ForegroundColor Yellow
}

# --- 9. TARGET INTERACTIVE INTERFACE INVOCATION (WINDOW 2) ---
Write-Host "`n>>> Initializing Pi Coding Agent environment in second separate window..." -ForegroundColor Green

# pi-hypa spawns the "hypa" native binary by default, but on Windows the binary
# lives at a local-to-pi path (C:\Users\KLN\.pi\agent\npm\node_modules\@hypabolic\
# hypa-win32-x64\bin\hypa.exe) that isn't on PATH. pi-hypa reads HYPA_BIN to
# resolve an absolute path; without it, child_process.spawn('hypa', ...) fails
# with EFTYPE ("inappropriate file type or format") and every hypa_find /
# hypa_ls / hypa_read / hypa_grep / hypa_shell call errors out. The npm wrapper
# bin.js resolves the right platform binary at runtime, so pointing HYPA_BIN at
# it is the safest option (handles linux/darwin/win32-arm64 automatically).
$HypaBin = "$env:USERPROFILE/.pi/agent/npm/node_modules/@hypabolic/hypa/bin.js"
if (Test-Path $HypaBin) {
    $HypaBinEnv = " `$env:HYPA_BIN='$HypaBin'"
    Write-Host ">>> HYPA_BIN pinned to: $HypaBin" -ForegroundColor Green
} else {
    $HypaBinEnv = ""
    Write-Host ">>> WARNING: hypa bin.js not found at $HypaBin -- hypa tools will fail with EFTYPE" -ForegroundColor Yellow
}

# Forward GITHUB_TOKEN from user-level env to the Pi process. Token is read at
# launcher run-time only -- never stored on disk by the launcher or in mcp.json.
# Set once via: [Environment]::SetEnvironmentVariable("GITHUB_TOKEN","ghp_xxx","User")
# Empty / unset -> github MCP server starts but auth fails; fetch/git/sequential-thinking
# still work.
$GitHubTokenEnv = ""
if ($env:GITHUB_TOKEN) {
    $GitHubTokenEnv = " `$env:GITHUB_TOKEN='$env:GITHUB_TOKEN'"
    Write-Host ">>> GITHUB_TOKEN forwarded from user env (length: $($env:GITHUB_TOKEN.Length))" -ForegroundColor Green
} else {
    Write-Host ">>> GITHUB_TOKEN not set in user env -- github MCP will fail to authenticate" -ForegroundColor Yellow
}

# Forward OBSIDIAN_API_KEY and OBSIDIAN_VAULT_PATH the same way. Both are
# required for the obsidian-mcp-server to reach the Local REST API plugin.
# Set once via: [Environment]::SetEnvironmentVariable("OBSIDIAN_API_KEY","...","User")
#              [Environment]::SetEnvironmentVariable("OBSIDIAN_VAULT_PATH","C:\path\to\vault","User")
$ObsidianEnv = ""
if ($env:OBSIDIAN_API_KEY -and $env:OBSIDIAN_VAULT_PATH) {
    # Note the trailing ';' on each -- PowerShell needs explicit statement
    # separators when multiple `$env:VAR=...` assignments are concatenated
    # into one -Command string. Without ';' PowerShell sees the two
    # assignments as a single malformed expression and throws
    # "Unexpected token '$env:OBSIDIAN_VAULT_PATH=...'".
    $ObsidianEnv = " `$env:OBSIDIAN_API_KEY='$env:OBSIDIAN_API_KEY';"
    $ObsidianEnv += " `$env:OBSIDIAN_VAULT_PATH='$env:OBSIDIAN_VAULT_PATH';"
    Write-Host ">>> OBSIDIAN_API_KEY + OBSIDIAN_VAULT_PATH forwarded (vault: $env:OBSIDIAN_VAULT_PATH)" -ForegroundColor Green
} else {
    Write-Host ">>> OBSIDIAN_API_KEY and/or OBSIDIAN_VAULT_PATH not set in user env -- obsidian MCP will not connect" -ForegroundColor Yellow
}

# Map our launcher-side reasoning choices to Pi's --thinking flag so Pi's
# status bar shows the SAME level the model is actually running at. Pi accepts:
#   off, minimal, low, medium, high, xhigh, max
# Our choices are enable_thinking + reasoning_effort (low|medium|xhigh). When
# enable_thinking is false we pass "off" -- Pi display + model behavior agree.
# When enable_thinking is true we forward the effort level verbatim.
# For non-reasoning models we pass nothing and let Pi default to "medium".
$PiThinkingArg = ""
if ($ModelNameLowerForCfg -like "*qwen*" -or $ModelNameLowerForCfg -like "*ornith*" -or $ModelNameLowerForCfg -like "*kat*" -or $ModelNameLowerForCfg -like "*qwopus*") {
    if (-not $EnableThinking) {
        $PiThinkingArg = " --thinking off"
    } else {
        $PiThinkingArg = " --thinking $ReasoningEffort"
    }
    Write-Host ">>> Pi will start with --thinking $(if (-not $EnableThinking) { 'off' } else { $ReasoningEffort }) (status bar matches actual level)" -ForegroundColor DarkGreen
}

$FinalCommand = "`$env:NODE_OPTIONS='--no-warnings';$HypaBinEnv;$GitHubTokenEnv;$ObsidianEnv; cd '$TargetProjectDir'; pi$AppendPromptArg$PiThinkingArg"
$PiArgs = @("-NoExit", "-Command", $FinalCommand)

Start-Process -FilePath "powershell.exe" -ArgumentList $PiArgs

# --- 10. LIVE METRICS TAIL (one window -- matches run_local_ai_PI.ps1 UX) ---
# TabbyAPI's loguru handler writes to $TABBY_DIR/logs/. We tail it here in the
# LAUNCHER CONSOLE itself (one window, like the old llama.cpp launcher) AFTER
# Pi is launched so the tail is the final blocking stage. For each new line
# we classify: Metrics lines are parsed into a colored one-liner with prompt/
# generate T/s + context; Received/Finished are flagged; errors and warnings
# surface in red/yellow; INFO noise is dropped. A 30s background timer polls
# nvidia-smi and prints current VRAM/util so you can see the model's working
# state without opening another window.
$LogDir = "$TABBY_DIR/logs"
$LogFile = Get-ChildItem -Path $LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName

function Format-TabbyMetrics {
    param([string]$Line)
    $m = [regex]::Match($Line,
        'Metrics \(ID: ([0-9a-f]+)\): (\d+) tokens generated in ([\d.]+) seconds \(Queue: ([\d.]+) s, Process: (\d+) cached tokens and (\d+) new tokens at ([\d.]+) T/s, Generate: ([\d.]+) T/s, Context: (\d+) tokens\)')
    if (-not $m.Success) { return }
    $id     = $m.Groups[1].Value.Substring(0, 8)
    $tok    = [int]$m.Groups[2].Value
    $total  = [double]$m.Groups[3].Value
    $cached = [int]$m.Groups[5].Value
    $newTok = [int]$m.Groups[6].Value
    $procTs = [math]::Round([double]$m.Groups[7].Value, 1)
    $genTs  = [math]::Round([double]$m.Groups[8].Value, 1)
    $ctx    = [int]$m.Groups[9].Value

    $genColor  = if ($genTs -lt 5) { 'Red' } elseif ($genTs -lt 15) { 'Yellow' } else { 'Green' }
    $procColor = if ($procTs -lt 100) { 'Yellow' } else { 'Green' }
    # Context thresholds from config.yml: <12k OK, 12-20k warning, >20k red.
    $ctxColor  = if ($ctx -lt 12000) { 'Green' } elseif ($ctx -lt 20000) { 'Yellow' } else { 'Red' }

    Write-Host ("  -- [{0}] " -f $id) -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,4} tok" -f $tok) -NoNewline -ForegroundColor White
    Write-Host (" in {0,5:N2}s " -f $total) -NoNewline -ForegroundColor DarkGray
    Write-Host "| ctx " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,5:N1}k" -f ($ctx/1000)) -NoNewline -ForegroundColor $ctxColor
    Write-Host (" ({0} cached, {1} new)" -f $cached, $newTok) -NoNewline -ForegroundColor DarkGray
    Write-Host " | prompt " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,7:N1}" -f $procTs) -NoNewline -ForegroundColor $procColor
    Write-Host " T/s | gen " -NoNewline -ForegroundColor DarkGray
    Write-Host ("{0,5:N1}" -f $genTs) -NoNewline -ForegroundColor $genColor
    Write-Host " T/s" -NoNewline -ForegroundColor DarkGray

    # MTP draft acceptance. TabbyAPI appends "Draft: N / M tokens accepted (X%)"
    # to the metrics line whenever a draft model is active (common/gen_logging.py:93),
    # so its ABSENCE means speculative decoding is off -- the fastest way to tell
    # whether the draft_model block in tabby_config.yml actually took effect.
    # Acceptance below ~40% means MTP is costing more than it saves.
    $d = [regex]::Match($Line, 'Draft: (\d+) / (\d+) tokens accepted \(([\d.]+)%\)')
    if ($d.Success) {
        $acceptPct = [double]$d.Groups[3].Value
        $acceptColor = if ($acceptPct -lt 40) { 'Red' } elseif ($acceptPct -lt 60) { 'Yellow' } else { 'Green' }
        Write-Host " | mtp " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,5:N1}%" -f $acceptPct) -NoNewline -ForegroundColor $acceptColor
    }
    Write-Host ""
}

function Show-TabbyVram {
    $line = & nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>$null
    if ($line) {
        foreach ($row in $line) {
            $parts = $row -split ',\s*'
            if ($parts.Count -ge 4) {
                $pct = if ([int]$parts[2] -gt 0) { ($parts[1] / $parts[2] * 100) } else { 0 }
                Write-Host ("  [VRAM GPU{0}: {1}/{2} MB ({3:N1}%)  util {4}%]" -f $parts[0], $parts[1], $parts[2], $pct, $parts[3]) -ForegroundColor DarkCyan
            }
        }
    }
}

if ($LogFile) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host " LIVE METRICS TAIL: $LogFile" -ForegroundColor Cyan
    Write-Host " (Pi is in another window -- this console shows the server's view)" -ForegroundColor DarkCyan
    Write-Host " (Ctrl+C to stop tailing; the server keeps running)" -ForegroundColor DarkCyan
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host ""

    # Replay past Metrics lines from this log so you see recent activity on launch
    foreach ($line in (Get-Content $LogFile)) {
        if ($line -match 'Metrics \(ID:') { Format-TabbyMetrics $line }
    }
    Write-Host ""
    Write-Host "--- LIVE ---" -ForegroundColor Magenta
    Show-TabbyVram

    # 30s VRAM refresh
    $vramTimer = New-Object System.Timers.Timer
    $vramTimer.Interval = 30000
    $vramTimer.AutoReset = $true
    $vramTimer.add_Elapsed({ Show-TabbyVram })
    $vramTimer.Start()

    # Tail via FileStream -- reads new lines as they appear without polling.
    # If file was rotated/truncated, reopen from the new end.
    try {
        $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $fs.Position = $fs.Length
        $sr = New-Object System.IO.StreamReader($fs)

        while ($true) {
            $line = $sr.ReadLine()
            if ($line -eq $null) {
                Start-Sleep -Milliseconds 200
                if ($fs.Length -lt $fs.Position) { $fs.Position = $fs.Length }
                continue
            }
            if ($line -match 'Metrics \(ID:') {
                Format-TabbyMetrics $line
            }
            elseif ($line -match 'Received chat completion') {
                Write-Host ("  > request start: {0}" -f ($line.Split()[-1])) -ForegroundColor DarkYellow
            }
            elseif ($line -match 'Finished chat completion') {
                Write-Host ("  < request end:   {0}" -f ($line.Split()[-1])) -ForegroundColor DarkGreen
            }
            elseif ($line -match '\| ERROR    \|') {
                Write-Host $line -ForegroundColor Red
            }
            elseif ($line -match '\| WARNING  \|') {
                Write-Host $line -ForegroundColor Yellow
            }
        }
    }
    finally {
        $vramTimer.Stop(); $vramTimer.Dispose()
        if ($sr) { $sr.Close() }
        if ($fs) { $fs.Close() }
    }
} else {
    Write-Host ">>> WARNING: no log file found in $LogDir -- live viewer skipped" -ForegroundColor Yellow
}
