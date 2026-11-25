// ACP fixture shaped as `agy acp` answers (Antigravity CLI 1.4.12): its initialize, a conversation in --gemini-dir,
// the instructions in _meta.antigravity.systemPrompt.append, session/set_model, a turn's usage in the prompt's answer.
// Without `acp`, its terminal interface signing in as 1.4.12's does (in a terminal, not signed in, not in a remote session):
// how to sign in asked, Google's page printed, the code read back (`bad`: nothing comes of it), its sign-in written to
// $HOME/.gemini/antigravity-cli, and the interface going on until it is stopped; a company's account as 1.5.9 signs it
// in (below). As 1.5.9: told it is a remote session's (SSH_CLIENT, its file kept in a file), it first asks the terminal
// what it is and waits for the answer; with a sign-in in $HOME already it asks nothing and goes straight into its
// interface. FAKE_AGY_TIER: the tier session/new says (`_meta.antigravity.tier`). FAKE_AGY_OFFLINE: how many openings
// (session/new, session/load) of all its processes answer as 1.5.9 does with its backend not reached: no models, and
// every model refused after (counted in FAKE_DUMP.offline). FAKE_AGY_SILENT: initialize never answered (its backend out of
// reach as it starts), nothing written.
import { appendFileSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
const dump = process.env.FAKE_DUMP;
const args = process.argv.slice(2);
const promptAt = args.indexOf('-p');
if (promptAt >= 0 && args[promptAt + 1] === '/usage') await printUsage();
if (args[0] === 'models') renew();
if (args[0] !== 'acp') await signIn();
// `agy models` on a sign-in that ran out: renewed in place, written back with its token and way of signing in alone (as
// a renewal may leave the rest out).
function renew() {
  const path = join(process.env.ANTIGRAVITY_GEMINI_DIR, 'antigravity-cli', 'antigravity-oauth-token');
  const had = JSON.parse(readFileSync(path, 'utf8'));
  writeFileSync(path, JSON.stringify({ token: { ...had.token, access_token: 'renewed', expiry: new Date(Date.now() + 3600_000).toISOString() }, auth_method: had.auth_method }));
  process.stdout.write('gemini-3.5-flash\n');
  process.exit(0);
}
async function printUsage() {
  if (dump) appendFileSync(dump, JSON.stringify({ args, home: process.env.HOME ?? null, geminiDir: process.env.ANTIGRAVITY_GEMINI_DIR ?? null, cloudCodeUrl: process.env.CLOUD_CODE_URL ?? null, key: process.env.GEMINI_API_KEY ?? null, updates: process.env.AGY_CLI_DISABLE_AUTO_UPDATE ?? null, fileTokens: process.env.SSH_CLIENT ?? null, forceFileTokens: process.env.AGY_CLI_FORCE_FILE_TOKEN_STORAGE ?? null }) + '\n');
  if (process.env.FAKE_AGY_SIGNED_OUT) {
    process.stdout.write('Authentication required. Please visit the URL to log in:\n  https://accounts.google.com/o/oauth2/auth\n\nWaiting for authentication (timeout 60s)...\n');
    await new Promise(() => {});
  }
  if (process.env.FAKE_AGY_USAGE_ERROR) {
    const err = process.env.FAKE_AGY_USAGE_ERROR;
    process.stderr.write(`error: ${err}\n`);
    process.stdout.write(JSON.stringify({ conversation_id: '', status: 'ERROR', response: '', error: err }) + '\n');
    process.exit(1);
  }
  const tokenPath = join(process.env.ANTIGRAVITY_GEMINI_DIR ?? join(process.env.HOME ?? '', '.gemini'), 'antigravity-cli', 'antigravity-oauth-token');
  if (!existsSync(tokenPath)) {
    process.stdout.write('Authentication required. Please visit the URL to log in:\n  https://accounts.google.com/o/oauth2/auth\n\nWaiting for authentication (timeout 60s)...\n');
    await new Promise(() => {});
  }
  // A company's account paying as it goes: no windows.
  if (process.env.FAKE_AGY_USAGE_EMPTY) {
    process.stdout.write(JSON.stringify({ conversation_id: '', status: 'SUCCESS', command: { name: 'usage', data: { groups: [] } } }) + '\n');
    process.exit(0);
  }
  process.stdout.write(JSON.stringify({
    conversation_id: '',
    status: 'SUCCESS',
    command: {
      name: 'usage',
      data: {
        groups: [
          {
            name: 'Gemini Models',
            buckets: [
              ...(process.env.FAKE_AGY_USAGE_NO_GEMINI_WEEKLY ? [] : [
                { id: 'gemini-weekly', name: 'Weekly Limit Remaining', window: 'weekly', remaining_fraction: 0.75, reset_time: '2026-11-19T09:14:38Z' },
              ]),
              { id: 'gemini-5h', name: 'Five Hour Limit Remaining', window: '5h', remaining_fraction: 0.9, reset_time: '2026-11-12T14:14:38Z' },
            ],
          },
          {
            name: 'Claude and GPT models',
            buckets: [
              { id: '3p-weekly', name: 'Weekly Limit Remaining', window: 'weekly', remaining_fraction: 0.4, reset_time: '2026-11-19T09:14:38Z' },
              { id: '3p-5h', name: 'Five Hour Limit Remaining', window: '5h', remaining_fraction: 0, reset_time: '2026-11-12T14:14:38Z' },
            ],
          },
        ],
      },
    },
  }) + '\n');
  process.exit(0);
}
async function signIn() {
  if (dump) appendFileSync(dump, JSON.stringify({ args, home: process.env.HOME, remote: process.env.SSH_CONNECTION ?? null, key: process.env.GEMINI_API_KEY ?? null, fileTokens: process.env.SSH_CLIENT ?? null, forceFileTokens: process.env.AGY_CLI_FORCE_FILE_TOKEN_STORAGE ?? null }) + '\n');
  if (!process.stdin.isTTY) { process.stderr.write('not a terminal\n'); process.exit(1); }
  process.stdin.setRawMode(true);
  if (process.env.SSH_CLIENT) {
    process.stdout.write('\u001b[>q\u001b[c\u001b[>c');
    let heard = '';
    await new Promise((resolve) => {
      const take = (chunk) => {
        heard += chunk.toString('utf8');
        if (!heard.includes('\u001b[?1;2c')) return;
        process.stdin.off('data', take);
        resolve();
      };
      process.stdin.on('data', take);
    });
    if (dump) appendFileSync(dump + '.terminal', JSON.stringify(heard) + '\n');
  }
  if (existsSync(join(process.env.HOME, '.gemini', 'antigravity-cli', 'antigravity-oauth-token'))) {
    process.stdout.write('\u001b[2J Welcome to Antigravity CLI!\n');
    await new Promise(() => {});
  }
  const url = 'https://accounts.google.com/o/oauth2/auth?access_type=offline&client_id=1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com&code_challenge=311aMcnjlIZigwJvlJ11zPjRZcH3mLzipvgAYB_hEgc&code_challenge_method=S256&prompt=consent&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback&response_type=code&scope=openid&state=Jn-JRaj4nQfYyaCSr9NcnA';
  process.stdout.write('\u001b[?1049h Welcome to the Antigravity CLI. You are currently not signed in.\n\n Select login method:\n > 1. Google OAuth\n2. Use a Google Cloud project\n');
  let typed = '';
  let step = 'menu';
  const at = join(process.env.HOME, '.gemini', 'antigravity-cli');
  const token = (fields) => {
    mkdirSync(at, { recursive: true });
    writeFileSync(join(at, 'antigravity-oauth-token'), JSON.stringify({ ...fields }));
  };
  let access = '';
  const signedIn = (fields) => {
    token({ token: { access_token: access, token_type: 'Bearer', refresh_token: 'refresh' }, auth_method: 'gcp', id_token_email: 'someone@company.com', ...fields });
    step = 'in';
    process.stdout.write('\u001b[2J Welcome to Antigravity CLI!\n');
  };
  const codeAsked = () => process.stdout.write(` Signing in...Your browser should open automatically. If not:\n\n ${url}\n\n If you aren't automatically redirected, paste the authorization code below:\n\n authorization code...\n`);
  // A company's account (1.5.9): the second way (a Google Cloud project), Continue with Google Cloud; once its code is in,
  // its file written with only its token, then its licences (FAKE_AGY_LICENSES: one, chosen with Enter) or, with none, how
  // to pay (Pay As You Go, the second) and its project asked (`bad-project`: refused).
  // 1.5.14 (FAKE_AGY_VERSION): how to pay asked first (Subscriptions, Enter), then its licences; with none, the project
  // asked, then its region (`Choose region:`, global first), its licence assigned there (FAKE_AGY_SELF_ASSIGN) or none
  // to be had, back (Esc) to the project and how to pay; Pay As You Go asks the project and its region again.
  // FAKE_AGY_STUCK: once its region is chosen it goes no further.
  const newer = process.env.FAKE_AGY_VERSION === '1.5.14';
  let project = '';
  let via = '';
  const billing14 = () => process.stdout.write(' Select billing model:\n > 1. Subscriptions \u2013 Use Antigravity through your Gemini subscription.\n2. Pay As You Go \u2013 Pay only for the tokens you use, billed through Gemini platform.\n');
  const projectAsked = (extra) => process.stdout.write(` Provide Google Cloud project:\n Your Antigravity use will be associated with provided project.\n > my-gcp-project\n${extra}`);
  process.stdin.on('data', (chunk) => {
    if (chunk.toString('utf8') === '\u001b') {
      if (dump) appendFileSync(dump + '.keys', JSON.stringify({ step, esc: true }) + '\n');
      if (step === 'assign') {
        step = 'project-sub';
        projectAsked('');
      } else if (step === 'project-sub') {
        step = 'billing14';
        billing14();
      }
      return;
    }
    typed += chunk.toString('utf8');
    let enter;
    while ((enter = typed.indexOf('\r')) >= 0) {
      const down = typed.slice(0, enter).includes('\u001b[B');
      const line = typed.slice(0, enter).replaceAll('\u001b[B', '').trim();
      typed = typed.slice(enter + 1);
      if (dump) appendFileSync(dump + '.keys', JSON.stringify({ step, down, line }) + '\n');
      if (step === 'menu' && down) {
        step = 'cloud';
        process.stdout.write(' Select Google Cloud sign-in method:\n > 1. Continue with Google Cloud\n 2. Use advanced SSO config\n');
      } else if (step === 'menu') {
        step = 'code';
        codeAsked();
      } else if (step === 'cloud') {
        step = 'gcp-code';
        codeAsked();
      } else if (step === 'code' && line !== 'bad') {
        token({ token: { access_token: `ya29.${line}`, token_type: 'Bearer' }, auth_method: 'oauth', id_token_email: 'someone@gmail.com' });
        step = 'in';
        process.stdout.write('\u001b[2J Welcome to Antigravity CLI!\n');
      } else if (step === 'gcp-code' && line !== 'bad' && newer) {
        access = `ya29.${line}`;
        token({ token: { access_token: access, token_type: 'Bearer', refresh_token: 'refresh' }, auth_method: 'gcp', id_token_email: 'someone@company.com' });
        step = 'billing14';
        billing14();
      } else if (step === 'billing14' && !down) {
        process.stdout.write(' Fetching licenses...\n');
        if (process.env.FAKE_AGY_LICENSES) {
          step = 'license';
          process.stdout.write(' Select available subscription:\n > 1. Gemini Enterprise Ultra (Project: company-project, Location: global)\n2. Can\'t find your subscription? Enter a Google Cloud project\n');
        } else {
          step = 'project-sub';
          projectAsked(' No licenses found. Please enter project ID manually.\n');
        }
      } else if (step === 'billing14') {
        step = 'project-pay';
        projectAsked('');
      } else if ((step === 'project-sub' || step === 'project-pay') && line !== '') {
        [project, via] = [line, step];
        step = 'region';
        const region = ' Choose region:\n > global\nus\n   eu\n For a full list of available locations and deployment endpoints, please refer to the official documentation\n';
        process.stdout.write(region);
        // (drawn again a moment later, after its Enter too, as its spinner redraws it: still one question)
        setTimeout(() => { if (step !== 'stuck') process.stdout.write(region); }, 20);
      } else if (step === 'region' && process.env.FAKE_AGY_STUCK) {
        process.stdout.write(' Setting up your project...\n');
        step = 'stuck';
      } else if (step === 'region' && via === 'project-sub' && process.env.FAKE_AGY_SELF_ASSIGN) {
        signedIn({ project_id: project, region: 'global', user_tier: 'gcp-ge-standard-tier', tier_display_name: 'Gemini Enterprise' });
      } else if (step === 'region' && via === 'project-sub') {
        step = 'assign';
        const none = ' Select subscription:\n Licenses are provided by your organization admin.\n No license available for this project and location. Contact your administrator to setup Gemini Enterprise for this project.\n   esc Back\n';
        process.stdout.write(none);
        // (drawn again, after its Esc too, while it is still on its way back)
        setTimeout(() => { if (step === 'assign' || step === 'project-sub') process.stdout.write(none); }, 20);
      } else if (step === 'region') {
        signedIn({ project_id: project, region: 'global' });
      } else if (step === 'gcp-code' && line !== 'bad') {
        access = `ya29.${line}`;
        token({ token: { access_token: access, token_type: 'Bearer', refresh_token: 'refresh' }, auth_method: 'gcp', id_token_email: 'someone@company.com' });
        process.stdout.write(' Fetching licenses...\n');
        // (as a Google Cloud account that may not list licences: said, and gone on)
        if (!process.env.FAKE_AGY_LICENSES) process.stdout.write(' Could not fetch licenses: Permission denied (403)\n');
        if (process.env.FAKE_AGY_LICENSES) {
          step = 'license';
          process.stdout.write(' Select a license:\n > Gemini Enterprise Ultra (company-project)\n\n Can\'t find your subscription?\n');
        } else {
          step = 'billing';
          process.stdout.write(' How do you want to pay?\n > 1. Subscriptions\n 2. Pay As You Go\n   Pay only for the tokens you use\n');
        }
      } else if (step === 'license' && process.env.FAKE_AGY_AUTH_ERROR) {
        process.stdout.write(' [Auth Error] Failed to select license: 403 PERMISSION_DENIED\n');
      } else if (step === 'license') {
        signedIn({ project_id: 'company-project', region: 'us-central1', user_tier: 'gcp-ge-ultra-tier', tier_display_name: 'Gemini Enterprise Ultra' });
      } else if (step === 'billing' && down) {
        step = 'project';
        process.stdout.write(' Provide Google Cloud project: \n');
      } else if (step === 'project' && line === 'bad-project') {
        process.stdout.write(' Permission denied on project bad-project\n');
      } else if (step === 'project') {
        signedIn({ project_id: line, region: 'global' });
      }
    }
  });
  await new Promise(() => {});
}
const say = (m) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...m }) + '\n');
const reply = (id, result) => say({ id, result });
let sessionId;
let held;
let loaded = false;
let loadReplayCount = 0;
const update = (u) => say({ method: 'session/update', params: { sessionId, update: u } });
const dir = args[args.indexOf('--gemini-dir') + 1];
const conversations = join(dir, 'antigravity-cli', 'conversations');
mkdirSync(conversations, { recursive: true });
if (dump) appendFileSync(dump, JSON.stringify({ args, key: process.env.GEMINI_API_KEY ?? null, adcAuth: process.env.AGY_ADC_AUTH ?? null, project: process.env.GOOGLE_CLOUD_PROJECT ?? null, location: process.env.GOOGLE_CLOUD_LOCATION ?? null, credentials: process.env.GOOGLE_APPLICATION_CREDENTIALS ?? null, updates: process.env.AGY_CLI_DISABLE_AUTO_UPDATE ?? null, fileTokens: process.env.SSH_CLIENT ?? null, forceFileTokens: process.env.AGY_CLI_FORCE_FILE_TOKEN_STORAGE ?? null }) + '\n');
const models = process.env.FAKE_AGY_SUBSCRIPTION
  ? {
      currentModelId: 'gemini-4-carbon-high',
      availableModels: [
        { modelId: 'gemini-4-carbon-low', name: 'Gemini 4 Carbon (Low)' },
        { modelId: 'gemini-4-carbon-medium', name: 'Gemini 4 Carbon (Medium)' },
        { modelId: 'gemini-4-carbon-high', name: 'Gemini 4 Carbon (High)' },
        { modelId: 'claude-opus-5-5-low', name: 'Claude Opus 5.5 (Low)' },
        { modelId: 'claude-opus-5-5-medium', name: 'Claude Opus 5.5 (Medium)' },
        { modelId: 'claude-opus-5-5-high', name: 'Claude Opus 5.5 (High)' },
        { modelId: 'gpt-oss-120b-medium', name: 'GPT-OSS 120B (Medium)' },
        { modelId: 'gemini-pro-orchestrator', name: 'Gemini Pro Orchestrator' },
      ],
    }
  : { currentModelId: 'gemini-3.5-flash', availableModels: [{ modelId: 'gemini-3.5-flash', name: 'Gemini 3.5 Flash' }, { modelId: 'gemini-3.1-pro', name: 'Gemini 3.1 Pro' }] };
// Whether this opening is one FAKE_AGY_OFFLINE answers with no models; once one is, the process offers none after.
let offline = false;
const opening = () => {
  const most = Number(process.env.FAKE_AGY_OFFLINE ?? 0);
  if (most === 0) return models;
  const counter = dump + '.offline';
  const seen = existsSync(counter) ? Number(readFileSync(counter, 'utf8')) : 0;
  writeFileSync(counter, String(seen + 1));
  offline = seen < most;
  return offline ? null : models;
};
for await (const line of createInterface({ input: process.stdin })) {
  const m = JSON.parse(line);
  if (dump) appendFileSync(dump + '.rpc', line + '\n');
  if (!m.method) continue;
  const p = m.params;
  if (m.method === 'initialize' && process.env.FAKE_AGY_SILENT) continue;
  if (m.method === 'initialize') reply(m.id, { protocolVersion: 1, authMethods: [{ id: 'oauth-personal' }, { id: 'oauth-business' }, { id: 'gemini-api-key' }, { id: 'agent-platform' }], agentCapabilities: { loadSession: true, _meta: { antigravity: { tier: true, systemPrompt: { append: true } } } }, agentInfo: { name: 'Antigravity ACP Server', version: '1.4.12' } });
  else if (m.method === 'authenticate') reply(m.id, {});
  else if (m.method === 'session/new') {
    if (process.env.FAKE_AGY_SIGNED_OUT) { say({ id: m.id, error: { code: -32000, message: 'Authentication required' } }); continue; }
    sessionId = randomUUID();
    writeFileSync(join(conversations, `${sessionId}.db`), 'conversation');
    reply(m.id, { sessionId, models: opening(), ...(process.env.FAKE_AGY_TIER ? { _meta: { antigravity: { tier: { id: process.env.FAKE_AGY_TIER, name: 'Google AI Ultra' } } } } : {}) });
  } else if (m.method === 'session/load') {
    sessionId = p.sessionId;
    loaded = true;
    if (existsSync(join(conversations, `${sessionId}.db`))) update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'past replay' } });
    reply(m.id, { models: opening() });
  } else if (m.method === 'session/set_model') {
    if (offline || !models.availableModels.some((x) => x.modelId === p.modelId)) say({ id: m.id, error: { code: -32602, message: `Unknown model ID: ${p.modelId}` } });
    else reply(m.id, {});
  } else if (m.method === 'session/cancel') {
    if (held) reply(held, { stopReason: 'cancelled' }); held = null;
  } else if (m.method === 'session/prompt') {
    const dbFile = join(conversations, `${sessionId}.db`);
    if (!existsSync(dbFile) || readFileSync(dbFile, 'utf8') === 'corrupt') { say({ id: m.id, error: { code: -32603, message: `Internal error: Failed to send user message: not_found: trajectory not found: ${sessionId}: not found` } }); continue; }
    const text = p.prompt[0].text;
    const prev = held;
    held = m.id;
    if (prev) {
      reply(prev, { stopReason: 'end_turn', usage: { totalTokens: 510, inputTokens: 500, outputTokens: 10, thoughtTokens: 0, cachedReadTokens: 0 } });
      update({ sessionUpdate: 'user_message_chunk', content: { type: 'text', text } });
    }
    if (text === 'expired') { say({ id: m.id, error: { code: -32603, message: 'Authentication expired. Please log back in.' } }); held = null; continue; }
    if (text === 'verification-required') { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '⚠ Verification Required' } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (text === 'vertex-iam-denied') { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: "⚠ Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/demo-project/locations/global/publishers/google/models/gemini-4-carbon' (or it may not exist)." } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (text === 'verification-required-mid-turn') { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'partial ' } }); update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '\n⚠ Verification Required\n' } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (loaded && Number(process.env.FAKE_AGY_LOAD_REPLAY ?? 0) > loadReplayCount) {
      loadReplayCount++;
      update({ sessionUpdate: 'tool_call', toolCallId: `ghost_t${loadReplayCount}`, title: 'view_file', kind: 'read', status: 'in_progress', rawInput: { AbsolutePath: '/ghost.txt' } });
      update({ sessionUpdate: 'tool_call_update', toolCallId: `ghost_t${loadReplayCount}`, status: 'completed', content: [{ type: 'content', content: { type: 'text', text: 'ghost history output' } }] });
      update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'ghost history replay text' } });
      reply(m.id, { stopReason: 'end_turn' });
      held = null;
      continue;
    }
    if (text === 'no-usage-end') { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'short reply without usage' } }); reply(m.id, { stopReason: 'end_turn' }); held = null; continue; }
    if (text.includes('expire-mid-turn')) { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'partial ' } }); update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '\n⚠ Agent execution terminated due to error.\n' } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (text.includes('unauth-mid-turn')) { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'partial ' } }); update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '\n⚠ UNAUTHENTICATED (code 401): Request had invalid authentication credentials.\n' } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (text === 'quota-said') { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '\n⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 56m33s.\n' } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (text === 'quota-after-calls') { update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Reading it.' } }); update({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'thinking' } }); update({ sessionUpdate: 'tool_call', toolCallId: 'q1', title: 'view_file', kind: 'read', status: 'in_progress', rawInput: { AbsolutePath: '/a.txt' } }); update({ sessionUpdate: 'tool_call_update', toolCallId: 'q1', status: 'completed', content: [{ type: 'content', content: { type: 'text', text: 'file contents' } }] }); update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '\n⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 22m58s.\n' } }); say({ id: m.id, result: { stopReason: 'end_turn' } }); held = null; continue; }
    if (text === 'quota') { say({ id: m.id, error: { code: -32603, message: 'RESOURCE_EXHAUSTED: You have exhausted your capacity on this model. Your quota will reset after 4h.' } }); held = null; continue; }
    update({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'thinking' } });
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'first ' } });
    if (text === 'hold' || text === 'hold-steer' || text.includes('hold-turn')) continue;
    // Held once: the marker is consumed here, so the test sees the hold only after this process read the prompt.
    if (dump && existsSync(dump + '.hold-auth-retry') && text.includes('authentication error')) { try { unlinkSync(dump + '.hold-auth-retry'); } catch {} continue; }
    update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } });
    update({ sessionUpdate: 'tool_call', toolCallId: 't1', title: 'view_file', kind: 'read', status: 'in_progress', rawInput: { AbsolutePath: '/a.txt' } });
    update({ sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'completed', content: [{ type: 'content', content: { type: 'text', text: 'file contents' } }] });
    // A call to the station's tools, as 1.4.12 titles an MCP tool's.
    update({ sessionUpdate: 'tool_call', toolCallId: 'call_1', title: 'Run mcp_stillfail_chat_post', kind: 'other', status: 'in_progress', rawInput: { text: 'reply', toolSummary: 'Post reply' } });
    update({ sessionUpdate: 'tool_call_update', toolCallId: 'call_1', status: 'completed', content: [] });
    update({ sessionUpdate: 'usage_update', used: 5000, size: 1048576 });
    reply(m.id, { stopReason: 'end_turn', usage: { totalTokens: 1700, inputTokens: 1200, outputTokens: 300, thoughtTokens: 100, cachedReadTokens: 200 } });
    held = null;
  } else say({ id: m.id, error: { code: -32601, message: 'Method not found: ' + m.method } });
}
