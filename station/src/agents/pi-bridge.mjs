// The station's extension inside Pi (`pi -e <this file>`, agents/pi.ts): what a session's process is set up with that
// Pi's files would share between the sessions of a profile, given this one process alone. Its one variable,
// STILLFAIL_PI_SETUP, is JSON:
//   provider?  the profile's provider as Pi's `registerProvider` takes it, registered as "stillfail" (its key read by Pi
//              from STILLFAIL_PI_KEY at each request: `apiKey: "$STILLFAIL_PI_KEY"`)
//   tools      the station's tools: its MCP address, registered as the server "stillfail" with its tools declared to
//              the model (`direct`), so they are named mcp__stillfail__<tool> as every runtime's are; the session's
//              token from STILLFAIL_MCP_TOKEN as a bearer token.
// Plain JavaScript that imports nothing: Pi loads it from the station's directory, where Pi's packages do not resolve.

export default function stillfail(pi) {
  const setup = JSON.parse(process.env.STILLFAIL_PI_SETUP ?? "{}");
  if (setup.provider) pi.registerProvider("stillfail", setup.provider);
  if (setup.tools?.url) {
    pi.registerMcpServer("stillfail", {
      url: setup.tools.url,
      headers: { Authorization: `Bearer ${process.env.STILLFAIL_MCP_TOKEN ?? ""}` },
      exposure: "direct",
      description: "still.fail: this chat and its station (post to the chat, files, other chats, jobs, devices)",
    });
  }
}
