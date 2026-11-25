// A stand-in for the Copilot driver's bridge (assets/agents/copilot-bridge.mjs) where what the station gives it is what
// is tested: its environment and its `open` written to FAKE_DUMP (named in the open's `dump`), then a session named;
// a prompt's turn ends at once. No SDK.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const write = (m) => process.stdout.write(`${JSON.stringify(m)}\n`)
createInterface({ input: process.stdin }).on('line', (line) => {
  const m = JSON.parse(line)
  if (m.op === 'open') {
    appendFileSync(m.dump, `${JSON.stringify({ env: process.env, open: m })}\n`)
    write({ id: m.id, session: 'fake-session' })
  } else if (m.op === 'prompt') {
    write({ ev: 'message', message: { type: 'assistant', message: { content: [{ type: 'text', text: 'ok' }] }, run_id: 'r' } })
    write({ id: m.id })
    write({ ev: 'end', run: 'r', status: 'finished' })
  } else write({ id: m.id })
}).on('close', () => process.exit(0))
