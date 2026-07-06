# 🤖 Local AI Agent Runner Scripts

A set of PowerShell scripts designed to streamline the execution of local AI agents (`llama.cpp` with PI and Claude Code) on Windows 11 Pro environments.

---

## 💻 System Specifications

The following configuration was used for testing and optimization:

| Component | Specification |
| :--- | :--- |
| **Motherboard** | Gigabyte Z690 UD AX Rev 1.0 |
| **CPU** | Intel Core i7-14700KF |
| **RAM** | 96 GB (4 slots: 2x16GB + 2x32GB) |
| **GPU** | 2 x 5060Ti (16 GB VRAM each) |
| **Storage** | 3 x M.2 SSDs (2TB + 4TB + 512GB) |

---

## 🛠️ Setup & Configuration

### 🔹 Llama.cpp with PI
The `run_local_ai_PI.ps1` script utilizes `llama.cpp` compiled with **CUDA support** to leverage NVIDIA GPU acceleration.

### 🔹 Claude Code
To configure Claude Code for local LLM usage via `llama.cpp`:
1. Locate the file `claude_settings_for_llm_cpp.json`.
2. Rename it to `settings.json`.
3. Replace your existing `%USER%\.claude\settings.json` with this new file.

---

## 🧠 Recommended Models

For optimal performance and token output quality, the following models are recommended:

*   `gemma-4-26B-A4B-it-UD-Q6_K.gguf`
*   `Qwopus3.6-35B-A3B-Coder-MTP-Q5_K_S.gguf`
*   `ornith-1.0-9b-Q8_0.gguf`

---

## 📂 Environment Paths

Ensure your paths match your local setup:

*   **Models Directory:** `C:\Models\`
*   **Projects Directory:** `D:\Projects\`

---

## 📜 License

**Permissive "Good Deeds" License**

Please feel free to use these scripts for all good deeds only at your own risks and responsibilities.

**DISCLAIMER:**
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. THIS INCLUDES, BUT IS NOT LIMITED TO, ANY REAL, IMAGINARY, OR MANIFESTED LEGAL CONSEQUENCES RESULTING FROM THE USE OF THESE SCRIPTS.
