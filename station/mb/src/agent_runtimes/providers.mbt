// providers.ts: the API providers a profile can reach with a key, and where each speaks which protocol.

///|
/// How Claude Code is given the key (`ClaudeAuth`): "apiKey", "bearer" or "both".
pub(all) struct Source {
  id : String
  name : String
  chat : String?
  responses : String?
  anthropic : String?
  decision : String?
  endpoint_required : Bool
  protocols : Array[String]
  key_optional : Bool
  auth : String
  session_header : Bool
}

///|
fn source(
  id : String,
  name : String,
  chat? : String,
  responses? : String,
  anthropic? : String,
  decision? : String,
  endpoint_required? : Bool = false,
  protocols? : Array[String] = [],
  key_optional? : Bool = false,
  auth? : String = "bearer",
  session_header? : Bool = false,
) -> Source {
  { id, name, chat, responses, anthropic, decision, endpoint_required, protocols, key_optional, auth, session_header }
}

///|
let all_protocols : Array[String] = ["chat_completions", "responses", "anthropic"]

///|
/// `SOURCES`, in the order they are offered.
pub let sources : Array[Source] = [
  source("openai", "OpenAI", responses="https://api.openai.com/v1"),
  source("anthropic", "Anthropic", anthropic="https://api.anthropic.com", auth="apiKey"),
  source("google", "Google Gemini", chat="https://generativelanguage.googleapis.com/v1beta/openai"),
  source("google-vertex", "Google Vertex AI"),
  source("xai", "xAI", responses="https://api.x.ai/v1"),
  source("mistral", "Mistral", chat="https://api.mistral.ai/v1"),
  source("deepseek", "DeepSeek", chat="https://api.deepseek.com"),
  source("qwen", "Qwen", chat="https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
  source("moonshotai", "Kimi", chat="https://api.moonshot.ai/v1"),
  source("kimi-code", "Kimi Code", anthropic="https://api.kimi.com/coding", chat="https://api.kimi.com/coding/v1"),
  source("zai", "Z.ai", chat="https://api.z.ai/api/coding/paas/v4"),
  source("minimax", "MiniMax", anthropic="https://api.minimax.io/anthropic"),
  source("xiaomi", "Xiaomi MiMo", chat="https://api.xiaomimimo.com/v1"),
  source("ant-ling", "Ant Ling", chat="https://api.ant-ling.com/v1"),
  source("jev", "Jev", decision="https://api.typesafe.ai/v1"),
  source("qwen-cn", "Qwen (China)", chat="https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"),
  source("moonshotai-cn", "Kimi (China)", chat="https://api.moonshot.cn/v1"),
  source("zai-coding-cn", "Z.ai Coding (China)", chat="https://open.bigmodel.cn/api/coding/paas/v4"),
  source("minimax-cn", "MiniMax (China)", anthropic="https://api.minimaxi.com/anthropic"),
  source("openrouter", "OpenRouter", anthropic="https://openrouter.ai/api", chat="https://openrouter.ai/api/v1"),
  source("vercel-ai-gateway", "Vercel AI Gateway", anthropic="https://ai-gateway.vercel.sh"),
  source(
    "opencode",
    "OpenCode Zen",
    anthropic="https://opencode.ai/zen",
    chat="https://opencode.ai/zen/v1",
    responses="https://opencode.ai/zen/v1",
    auth="apiKey",
    session_header=true,
  ),
  source(
    "opencode-go",
    "OpenCode Go",
    anthropic="https://opencode.ai/zen/go",
    chat="https://opencode.ai/zen/go/v1",
    responses="https://opencode.ai/zen/go/v1",
    auth="apiKey",
    session_header=true,
  ),
  source("cloudflare-ai-gateway", "Cloudflare AI Gateway", endpoint_required=true, protocols=all_protocols, auth="both"),
  source("azure-openai", "Azure OpenAI", endpoint_required=true, protocols=["responses"]),
  source("groq", "Groq", chat="https://api.groq.com/openai/v1"),
  source("together", "Together AI", chat="https://api.together.ai/v1"),
  source("fireworks", "Fireworks", anthropic="https://api.fireworks.ai/inference", chat="https://api.fireworks.ai/inference/v1"),
  source("cerebras", "Cerebras", chat="https://api.cerebras.ai/v1"),
  source("huggingface", "Hugging Face", chat="https://router.huggingface.co/v1"),
  source("nvidia", "NVIDIA", chat="https://integrate.api.nvidia.com/v1"),
  source("baseten", "Baseten", chat="https://inference.baseten.co/v1"),
  source("cloudflare-workers-ai", "Cloudflare Workers AI", endpoint_required=true, protocols=["chat_completions"]),
  source("ollama", "Ollama", endpoint_required=true, protocols=["chat_completions"], key_optional=true),
  source("custom", "Custom", endpoint_required=true, protocols=all_protocols, key_optional=true, auth="both"),
]

///|
pub fn find(id : String) -> Source? {
  for s in sources {
    if s.id == id {
      return Some(s)
    }
  }
  None
}

///|
/// `LEGACY`: the two made before this list, as an access kind of their own.
pub fn legacy(id : String) -> String? {
  match id {
    "anthropic" => Some("anthropic-api")
    "opencode-go" => Some("opencode-go")
    _ => None
  }
}

///|
/// `groupOf`: labs, gateways, hosted, local.
pub fn group_of(id : String) -> String {
  if ["openrouter", "vercel-ai-gateway", "opencode", "opencode-go", "cloudflare-ai-gateway"].contains(id) {
    return "gateways"
  }
  if [
      "azure-openai", "groq", "together", "fireworks", "cerebras", "huggingface", "nvidia", "baseten", "cloudflare-workers-ai",
    ].contains(id) {
    return "hosted"
  }
  if id == "ollama" || id == "custom" {
    return "local"
  }
  "labs"
}

///|
/// `cleanEndpoint`: trimmed, without a trailing slash; none unless it is an http(s) address.
pub fn clean_endpoint(text : String) -> String? {
  let mut trimmed = trim(text)
  while trimmed.has_suffix("/") {
    trimmed = sub(trimmed, 0, to=trimmed.length() - 1)
  }
  let rest = if trimmed.has_prefix("https://") {
    Some(sub(trimmed, 8))
  } else if trimmed.has_prefix("http://") {
    Some(sub(trimmed, 7))
  } else {
    None
  }
  match rest {
    Some(r) if r != "" && !has_space(r) => Some(trimmed)
    _ => None
  }
}

///|
pub fn anthropic_root(base : String) -> String {
  if base.has_suffix("/v1") {
    sub(base, 0, to=base.length() - 3)
  } else {
    base
  }
}

///|
pub(all) struct Endpoints {
  mut chat : String?
  mut responses : String?
  mut anthropic : String?
  decision : String?
}

///|
pub fn Endpoints::json(self : Endpoints) -> J {
  let f = Fields::new()
  for e in [("chat", self.chat), ("responses", self.responses), ("anthropic", self.anthropic), ("decision", self.decision)] {
    if e.1 is Some(v) {
      f.set_str(e.0, v)
    }
  }
  f.json()
}

///|
/// `endpoints`: the endpoints of a source; for one at the person's own address, derived from it and the protocol chosen
/// for it. None when the address is needed and is not a usable one.
pub fn endpoints(source : Source, endpoint : String?, protocol : String?) -> Endpoints? {
  if !source.endpoint_required {
    return Some({ chat: source.chat, responses: source.responses, anthropic: source.anthropic, decision: source.decision })
  }
  let base = match endpoint {
    Some(e) => clean_endpoint(e)
    None => None
  }
  guard base is Some(base) else { return None }
  let chosen = match protocol {
    Some(p) if all_protocols.contains(p) => Some(p)
    _ => None
  }
  if chosen is Some(c) && !source.protocols.contains(c) {
    return None
  }
  let at : Endpoints = { chat: None, responses: None, anthropic: None, decision: None }
  if source.id == "cloudflare-ai-gateway" {
    let mut root = base
    for suffix in ["/compat", "/openai", "/anthropic"] {
      if base.has_suffix(suffix) {
        root = sub(base, 0, to=base.length() - suffix.length())
        break
      }
    }
    at.chat = Some(root + "/compat")
    at.responses = Some(root + "/openai")
    at.anthropic = Some(root + "/anthropic")
    if chosen is Some(c) {
      if c != "chat_completions" {
        at.chat = None
      }
      if c != "responses" {
        at.responses = None
      }
      if c != "anthropic" {
        at.anthropic = None
      }
    }
  } else if source.id == "azure-openai" {
    at.responses = Some(base)
  } else if source.id == "cloudflare-workers-ai" || source.id == "ollama" {
    at.chat = Some(base)
  } else if chosen is Some("chat_completions") {
    at.chat = Some(base)
  } else if chosen is Some("responses") {
    at.responses = Some(base)
  } else if chosen is Some("anthropic") {
    at.anthropic = Some(anthropic_root(base))
  } else {
    at.anthropic = if base.has_suffix("/v1") { Some(anthropic_root(base)) } else { None }
    at.chat = Some(base)
    at.responses = Some(base)
  }
  Some(at)
}

///|
/// `runtimesOf`: Anthropic's protocol is Claude Code's, Responses Codex's; DeepSeek Harness and Pi speak all three.
pub fn runtimes_of(at : Endpoints) -> Array[String] {
  let out = []
  if at.anthropic is Some(_) {
    out.push("claude")
  }
  if at.responses is Some(_) {
    out.push("codex")
  }
  if at.chat is Some(_) || at.anthropic is Some(_) || at.responses is Some(_) {
    out.push("dsh")
    out.push("pi")
  }
  out
}
