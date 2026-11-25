// The station's driver of a GitHub Copilot agent (agents/copilot.ts): GitHub's Copilot SDK (@microsoft/copilot-sdk) in
// this process, its runtime a child process of the SDK's own (spawned over stdio, COPILOT_HOME the shared sessions' home),
// on the profile's GitHub token alone. It speaks to the station as Cursor's driver does (cursor-bridge.mjs), its messages
// in Cursor's shapes, so the station's program reads both alike (mb/src/cursor). One line of JSON per message on stdin
// and stdout, for the one session of the process:
//   in:  {id, op: "open", cwd, resume?, model?, effort?, mcpUrl, instructions, skills?, sessions, silent}
//                                          → {id, session} | {id, error}
//        {id, op: "prompt", text, model?}  starts a turn: → {id} once the runtime took it, {id, error} when it did not
//        {id, op: "steer", text}           into the running turn (the SDK's `immediate` mode): → {id, delivered}
//        {id, op: "cancel"}                stops the running turn (it ends cancelled)
//        {id, op: "retune", model, effort?} the model and effort from the next model call on (the SDK's setModel)
//        {id, op: "compact"}               compacts the context now (the runtime's history.compact): a turn of its own
//   out: {id, ...} answers; {ev: "message", message} what the turn says, as Cursor's SDK says it (status, thinking,
//        assistant text, tool calls, a message put in the turn); {ev: "end", status, error?, model?} the turn ended
//        (finished, cancelled, error); {note: "compacted"} the context is a summary now (asked for, or as it filled).
// A turn is the runtime's from a message taken until `session.idle`: what it does meanwhile (a message put in the turn,
// a subagent, a retry) is that turn's, with no deadline of the station's; `session.error` before the idle fails it.
// What a subagent says is not the turn's steps (events with an `agentId`), only its spend is counted.
// A subagent never speaks in a chat: its calls of the tools a session speaks by (`silent`: the station's `SPEAKS`, and
// slack_api where its method writes) are refused by the SDK's pre-tool hook, which the runtime gives the calling agent's
// `agentId` (absent for the session's own agent). The model is not asked: the call never reaches the station.
// It keeps the session's transcript itself (`sessions`/<session id>.jsonl, Cursor's lines, read by read/transcript.ts);
// the runtime's own (session-state/…/events.jsonl) is its format to change.
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { pathToFileURL } from 'node:url'

const write = (message) => process.stdout.write(`${JSON.stringify(message)}\n`)
/// The most of a tool's result kept in the transcript and sent as it is.
const RESULT_CHARS = 64 * 1024
/// The station's tools, by the server's name the station gives them (runtime.ts `TOOL_SERVERS`).
const SERVER = 'stillfail'

const clip = (v) => {
  const text = typeof v === 'string' ? v : JSON.stringify(v ?? null)
  return text.length > RESULT_CHARS ? text.slice(0, RESULT_CHARS) : text
}

/// A call as Cursor's SDK names it: an MCP server's tool as `mcp` with the server and the tool in its args.
export function callOf(start) {
  const args = start?.arguments ?? null
  if (typeof start?.mcpServerName === 'string' && typeof start?.mcpToolName === 'string') {
    return { name: 'mcp', args: { providerIdentifier: start.mcpServerName, toolName: start.mcpToolName, args: args ?? {} } }
  }
  return { name: String(start?.toolName ?? 'tool'), args }
}

/// What a call gave back, as text (its error's message when it failed).
export function resultOf(complete) {
  if (complete?.success === false) return String(complete?.error?.message ?? 'failed')
  const r = complete?.result
  if (typeof r?.content === 'string') return r.content
  if (typeof r?.detailedContent === 'string') return r.detailedContent
  return r === undefined ? '' : JSON.stringify(r)
}

/// A model call's counts as the transcript keeps them (Cursor's names): input apart from the cache's read, which the
/// runtime counts in it as OpenAI's API does.
export function countsOf(usage) {
  const n = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0)
  const read = n(usage?.cacheReadTokens)
  return { inputTokens: Math.max(0, n(usage?.inputTokens) - read), cacheReadTokens: read, cacheWriteTokens: n(usage?.cacheWriteTokens), outputTokens: n(usage?.outputTokens) }
}

/// Whether the pre-tool hook refuses a call: a subagent's (it has an `agentId`) of a tool by which a session speaks.
/// `silent`: {tools: names as the station has them, slackWrites: method prefixes that write}.
export function refusal(input, silent) {
  const agent = input?.agentId
  if (typeof agent !== 'string' || agent === '') return null
  const name = String(input?.toolName ?? '')
  const prefix = `${SERVER}-`
  if (!name.startsWith(prefix)) return null
  const tool = name.slice(prefix.length)
  const instead = 'Nothing was sent or changed. Do not retry, and do not look for another way to do it: finish your task and give what you did or found as your final answer. The agent that started you reads it and posts what people need.'
  if (tool === 'slack_api') {
    const method = typeof input?.toolArgs?.method === 'string' ? input.toolArgs.method.trim() : ''
    if (!(silent?.slackWrites ?? []).some((w) => w !== '' && method.startsWith(w))) return null
    return `Refused: you are a subagent, and writing to Slack (${method.slice(0, 60)}) is only for the agent that started you. Reading Slack with slack_api is fine. ${instead}`
  }
  if (!(silent?.tools ?? []).includes(tool)) return null
  return `Refused: you are a subagent, and ${tool} is only for the agent that started you. A subagent does not post to the chat, end the turn, write to another chat's agent, or open, leave or archive a chat. ${instead}`
}

async function main() {
  // The package's ES module, as its exports say (dist/index.js).
  const dir = process.env.STILLFAIL_COPILOT_SDK ?? ''
  const exported = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))?.exports?.['.']
  const entry = exported?.import?.default ?? exported?.import ?? exported?.default ?? 'dist/index.js'
  const sdk = await import(pathToFileURL(join(dir, entry)).href)

  let client = null
  let session = null
  let transcript = null
  /// The model as the runtime last said it (for the usage), and the one the station last chose.
  let model = null
  let chosen = null
  /// The turn under way: its id (the usage's run) and how it ends; null between turns.
  let turn = null
  /// The model's text or thoughts under way, kept whole once something else comes.
  let said = null
  /// Messages and thoughts said in pieces (their final event then says nothing new).
  const streamed = new Set()
  /// Calls under way, by id: their name and input, for their end.
  const calls = new Map()
  /// The context as the runtime last said it, for the usage lines.
  let context = 0
  let window = 0
  /// Whether the context was said compacted since a compaction was asked for.
  let compacted = false

  const keep = (line) => {
    if (transcript === null) return
    try {
      appendFileSync(transcript, `${JSON.stringify({ time: Date.now(), ...line })}\n`)
    } catch {}
  }
  const flush = () => {
    if (said !== null && said.text !== '') keep(said)
    said = null
  }
  const tell = (message) => write({ ev: 'message', message: { ...message, run_id: turn?.id ?? 'copilot' } })
  const begin = () => {
    if (turn !== null) return
    turn = { id: crypto.randomUUID(), calls: 0, error: null, aborted: false }
    tell({ type: 'status', status: 'RUNNING' })
  }
  const end = (status, error) => {
    if (turn === null) return
    flush()
    calls.clear()
    keep({ type: 'end', status, ...(error ? { error } : {}) })
    write({ ev: 'end', run: turn.id, status, ...(error ? { error } : {}), ...(model ? { model } : {}) })
    turn = null
  }
  const saying = (kind, text) => {
    if (text === '') return
    if (said?.type !== kind) flush()
    said ??= { type: kind, text: '' }
    said.text += text
    if (kind === 'thinking') tell({ type: 'thinking', text })
    else tell({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } })
  }

  const hear = (event) => {
    const data = event?.data ?? {}
    const sub = typeof event?.agentId === 'string' && event.agentId !== ''
    switch (event?.type) {
      case 'assistant.usage': {
        // Every call is spend, a subagent's too.
        if (turn === null) break
        turn.calls += 1
        if (!sub && typeof data.model === 'string') model = data.model
        keep({ type: 'usage', run: turn.calls === 1 ? turn.id : `${turn.id}:${turn.calls}`, model: typeof data.model === 'string' ? data.model : model, usage: countsOf(data), calls: 1, context, window, ...(sub ? { subagent: true } : {}) })
        return
      }
      case 'session.usage_info':
        if (sub) return
        if (typeof data.currentTokens === 'number') context = data.currentTokens
        if (typeof data.tokenLimit === 'number') window = data.tokenLimit
        return
      case 'session.compaction_complete':
        if (!sub && data.success !== false) {
          compacted = true
          write({ note: 'compacted' })
        }
        return
      case 'session.model_change':
        if (!sub && typeof data.newModel === 'string') model = data.newModel
        return
    }
    if (sub) return
    switch (event?.type) {
      case 'user.message':
        // A message put in the running turn (the prompt itself is kept as it is given).
        if (turn !== null && turn.prompt !== data.messageId && data.delivery !== 'idle' && typeof data.content === 'string') {
          flush()
          keep({ type: 'user', text: data.content, steered: true })
          tell({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: data.content }] } })
        }
        return
      case 'assistant.turn_start':
        begin()
        return
      case 'assistant.message_delta':
        begin()
        streamed.add(data.messageId)
        saying('assistant', String(data.deltaContent ?? ''))
        return
      case 'assistant.message':
        begin()
        if (!streamed.delete(data.messageId)) saying('assistant', String(data.content ?? ''))
        return
      case 'assistant.reasoning_delta':
        begin()
        streamed.add(data.reasoningId)
        saying('thinking', String(data.deltaContent ?? ''))
        return
      case 'assistant.reasoning':
        begin()
        if (!streamed.delete(data.reasoningId)) saying('thinking', String(data.content ?? ''))
        return
      case 'tool.execution_start': {
        begin()
        flush()
        const call = { ...callOf(data), startedAt: Date.now() }
        calls.set(data.toolCallId, call)
        tell({ type: 'tool_call', call_id: data.toolCallId, name: call.name, status: 'running', args: call.args })
        return
      }
      case 'tool.execution_complete': {
        begin()
        flush()
        const call = calls.get(data.toolCallId) ?? { name: 'tool', args: null, startedAt: undefined }
        calls.delete(data.toolCallId)
        const status = data.success === false ? 'error' : 'completed'
        const result = clip(resultOf(data))
        keep({ type: 'tool', id: data.toolCallId, name: call.name, status, args: call.args, result, ...(call.startedAt ? { startedAt: call.startedAt } : {}) })
        tell({ type: 'tool_call', call_id: data.toolCallId, name: call.name, status, args: call.args, result })
        return
      }
      case 'abort':
        if (turn !== null) turn.aborted = true
        return
      case 'session.error':
        if (turn !== null) turn.error = { message: String(data.message ?? 'Copilot failed'), code: String(data.errorType ?? data.errorCode ?? '') }
        return
      case 'session.idle':
        if (turn === null) return
        if (turn.aborted || data.aborted === true) end('cancelled')
        else if (turn.error !== null) end('error', turn.error)
        else end('finished')
        return
    }
  }

  const ops = {
    async open(message) {
      if (session !== null) throw new Error('a session is open')
      chosen = typeof message.model === 'string' && message.model !== '' ? message.model : null
      model = chosen
      mkdirSync(message.sessions, { recursive: true })
      const home = join(message.sessions, 'home')
      mkdirSync(home, { recursive: true })
      // (a model provider of its own, `provider` below, is no GitHub account's: no token goes to GitHub then)
      const token = message.provider ? '' : (process.env.STILLFAIL_COPILOT_TOKEN ?? '')
      // The runtime's own process: its environment the station gave this one, and the profile's token alone (never a
      // login of the machine's: `useLoggedInUser` false reads no stored login, `gh`, or token variable).
      client = new sdk.CopilotClient({
        mode: 'coding-agent',
        runtime: sdk.RuntimeConnection.forSpawnedStdio({ baseDirectory: home, env: { ...process.env, STILLFAIL_COPILOT_TOKEN: undefined } }),
        github: { useLoggedInUser: false, ...(token !== '' ? { token } : {}) },
        clientInfo: { applicationName: 'still.fail' },
      })
      const silent = { tools: Array.isArray(message.silent?.tools) ? message.silent.tools : [], slackWrites: Array.isArray(message.silent?.slackWrites) ? message.silent.slackWrites : [] }
      const options = {
        ...(chosen !== null ? { model: chosen } : {}),
        ...(typeof message.effort === 'string' && message.effort !== '' ? { inference: { reasoningEffort: message.effort } } : {}),
        workingDirectory: message.cwd,
        // The station's instructions after the runtime's own; the workspace's skills as a folder of skills.
        systemMessage: { mode: 'append', content: String(message.instructions ?? '') },
        ...(typeof message.skills === 'string' && message.skills !== '' ? { skills: { directories: [message.skills] } } : {}),
        mcp: { servers: { [SERVER]: { type: 'http', url: message.mcpUrl, headers: { Authorization: `Bearer ${process.env.STILLFAIL_MCP_TOKEN ?? ''}` }, tools: ['*'] } } },
        // No approvals, as the station's other runtimes run (the station's tools are its own to refuse).
        permissions: { onRequest: () => ({ kind: 'approve-once' }) },
        hooks: { handlers: { onPreToolUse: (input) => {
          const reason = refusal(input, silent)
          return reason === null ? undefined : { permissionDecision: 'deny', permissionDecisionReason: reason }
        } } },
        events: { streaming: true, includeSubAgentStreamingEvents: false, onEvent: hear },
      }
      // A model provider of its own in place of GitHub's (the SDK's `github.capi` and `inference` options: the tests'
      // local model); none from the station.
      if (message.provider) {
        options.github = { ...options.github, ...message.provider.github }
        options.inference = { ...options.inference, ...message.provider.inference }
      }
      session = message.resume ? await client.resumeSession(message.resume, options) : await client.createSession(options)
      transcript = join(message.sessions, `${session.sessionId}.jsonl`)
      if (!message.resume) keep({ type: 'session', id: session.sessionId, cwd: message.cwd })
      return { session: session.sessionId }
    },
    async prompt({ text, model: name }) {
      if (turn !== null) throw new Error('a turn is already running')
      if (typeof name === 'string' && name !== '' && name !== chosen) {
        await session.setModel(name)
        chosen = name
        model = name
      }
      flush()
      keep({ type: 'user', text })
      begin()
      try {
        turn.prompt = await session.send({ prompt: text })
      } catch (error) {
        const failed = { message: String(error?.message ?? error), ...(error?.code ? { code: String(error.code) } : {}) }
        keep({ type: 'end', status: 'error', error: failed })
        turn = null
        throw Object.assign(new Error(failed.message), { code: failed.code })
      }
      return {}
    },
    async steer({ text }) {
      if (turn === null) return { delivered: false }
      await session.send({ prompt: text, mode: 'immediate' })
      return { delivered: true }
    },
    async cancel() {
      if (turn !== null) turn.aborted = true
      await session.abort()
      return {}
    },
    async retune({ model: name, effort }) {
      if (typeof name !== 'string' || name === '') throw new Error('no model')
      await session.setModel(name, typeof effort === 'string' && effort !== '' ? { reasoningEffort: effort } : undefined)
      chosen = name
      model = name
      return {}
    },
    async compact() {
      if (turn !== null) throw new Error('a turn is already running')
      begin()
      compacted = false
      let result
      try {
        result = await session.rpc.history.compact()
      } catch (error) {
        end('error', { message: String(error?.message ?? error) })
        return {}
      }
      if (result?.success === false) end('error', { message: 'nothing could be compacted' })
      else {
        if (!compacted) write({ note: 'compacted' })
        // (a compaction runs no agent loop: no idle ends it)
        end('finished')
      }
      return {}
    },
  }

  const lines = createInterface({ input: process.stdin })
  lines.on('line', async (line) => {
    let message
    try {
      message = JSON.parse(line)
    } catch {
      return
    }
    const op = ops[message?.op]
    try {
      if (!op) throw new Error(`unknown op ${message?.op}`)
      if (message.op !== 'open' && session === null) throw new Error('no session is open')
      write({ id: message.id, ...(await op(message)) })
    } catch (error) {
      write({ id: message.id, error: String(error?.message ?? error), ...(error?.code ? { code: String(error.code) } : {}) })
    }
  })
  // The station closing stdin ends the process: the session is let go (what the runtime keeps of it stays on disk, to
  // be resumed), then the runtime.
  lines.on('close', async () => {
    try {
      await session?.disconnect()
    } catch {}
    try {
      await client?.stop()
    } catch {}
    process.exit(0)
  })
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) await main()
