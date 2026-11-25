// A model and the station's tools for the Copilot driver's tests (test/copilot.test.ts): an OpenAI-compatible chat
// completions server on 127.0.0.1 whose answers a script gives each request (streamed text, a tool call, a refusal, an
// answer held back), and an HTTP MCP server with the station's tool names whose calls are kept. No network.
import { createServer } from 'node:http'

/// `script(body, n)`: the answer to the n-th request, {text: pieces} | {tool: {id, name, args}} | {status, message}, and
/// `hold`, a promise it waits for first.
export function startModel(script) {
  const requests = []
  const server = createServer(async (req, res) => {
    let body = ''
    for await (const c of req) body += c
    let json = null
    try { json = JSON.parse(body) } catch {}
    requests.push({ url: req.url, body: json })
    if (!req.url.includes('chat/completions')) {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ data: [{ id: 'mock', object: 'model' }] }))
      return
    }
    const reply = script(json, requests.length)
    if (reply.status) {
      res.writeHead(reply.status, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: { message: reply.message ?? 'boom', type: 'server_error' } }))
      return
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' })
    const base = { id: 'c1', object: 'chat.completion.chunk', created: 1, model: json?.model ?? 'mock' }
    const send = (delta, finish = null, usage) => res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta, finish_reason: finish }], ...(usage ? { usage } : {}) })}\n\n`)
    // (held until the test lets it go: a turn under way for a steer or a cancel)
    if (reply.hold) await reply.hold
    for (const t of reply.text ?? []) send({ content: t })
    if (reply.tool) send({ tool_calls: [{ index: 0, id: reply.tool.id ?? 'call1', type: 'function', function: { name: reply.tool.name, arguments: JSON.stringify(reply.tool.args ?? {}) } }] })
    send({}, reply.tool ? 'tool_calls' : 'stop')
    res.write(`data: ${JSON.stringify({ ...base, choices: [], usage: { prompt_tokens: 100, completion_tokens: 7, total_tokens: 107, prompt_tokens_details: { cached_tokens: 40 } } })}\n\n`)
    res.write('data: [DONE]\n\n')
    res.end()
  })
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ server, url: `http://127.0.0.1:${server.address().port}/v1`, requests })))
}

/// `tools`: their names; a call answers `called <name>`.
export function startMcp(tools) {
  const calls = []
  const server = createServer(async (req, res) => {
    let body = ''
    for await (const c of req) body += c
    if (req.method !== 'POST') { res.writeHead(405); res.end(); return }
    const m = JSON.parse(body)
    calls.push({ headers: req.headers, message: m })
    if (m.id === undefined) { res.writeHead(202); res.end(); return }
    let result
    if (m.method === 'initialize') result = { protocolVersion: m.params?.protocolVersion ?? '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'stillfail', version: '1' } }
    else if (m.method === 'tools/list') result = { tools: tools.map((name) => ({ name, description: name, inputSchema: { type: 'object', properties: { text: { type: 'string' } } } })) }
    else if (m.method === 'tools/call') result = { content: [{ type: 'text', text: `called ${m.params.name}` }] }
    else result = {}
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ jsonrpc: '2.0', id: m.id, result }))
  })
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ server, url: `http://127.0.0.1:${server.address().port}/mcp`, calls })))
}
