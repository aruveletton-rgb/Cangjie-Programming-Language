// Self-signed TLS reverse proxy for the PAEP-style cloud demo.
//
// Why this exists: src/backend/src/main.cj:24 binds the backend to 127.0.0.1 only.
// The backend therefore cannot be exposed directly, and every external request has to
// come through a TLS terminator on the same host. That is both the deployment shape and
// a deliberate security boundary: the backend never listens on a public interface.
//
// No third-party dependencies. Node 18+.
//
// Environment:
//   TLS_BIND      listen address            default 0.0.0.0
//   TLS_PORT      listen port               default 8443
//   TLS_CERT      certificate PEM path      required
//   TLS_KEY       private key PEM path      required
//   UPSTREAM      backend origin            default http://127.0.0.1:38082
//   TLS_LOG       access log path           default <cwd>/tls-proxy.log

import fs from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import path from 'node:path'

const BIND = process.env.TLS_BIND || '0.0.0.0'
const PORT = Number(process.env.TLS_PORT || 8443)
const CERT = process.env.TLS_CERT
const KEY = process.env.TLS_KEY
const UPSTREAM = process.env.UPSTREAM || 'http://127.0.0.1:38082'
const LOG = process.env.TLS_LOG || path.resolve('tls-proxy.log')

if (!CERT || !KEY) {
  console.error('TLS_CERT and TLS_KEY are required')
  process.exit(2)
}
for (const file of [CERT, KEY]) {
  if (!fs.existsSync(file)) {
    console.error('missing file: ' + file)
    process.exit(2)
  }
}

const upstream = new URL(UPSTREAM)
if (upstream.protocol !== 'http:') {
  console.error('UPSTREAM must be a plain http origin, got ' + upstream.protocol)
  process.exit(2)
}

const logStream = fs.createWriteStream(LOG, { flags: 'a' })
const log = (record) => logStream.write(JSON.stringify({ at: new Date().toISOString(), ...record }) + '\n')

const agent = new http.Agent({ keepAlive: true, maxSockets: 64 })

const server = https.createServer(
  { cert: fs.readFileSync(CERT), key: fs.readFileSync(KEY), minVersion: 'TLSv1.2' },
  (req, res) => {
    const started = Date.now()
    const headers = { ...req.headers }
    delete headers['x-forwarded-proto']
    delete headers['x-forwarded-for']
    delete headers['x-forwarded-host']
    headers.host = upstream.host
    headers['x-forwarded-proto'] = 'https'
    headers['x-forwarded-for'] = req.socket.remoteAddress || ''
    headers['x-forwarded-host'] = req.headers.host || ''

    const proxied = http.request(
      { hostname: upstream.hostname, port: upstream.port || 80, method: req.method, path: req.url, headers, agent },
      (upstreamRes) => {
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers)
        upstreamRes.pipe(res)
        upstreamRes.on('end', () =>
          log({ method: req.method, path: req.url, status: upstreamRes.statusCode, ms: Date.now() - started })
        )
      }
    )

    proxied.on('error', (error) => {
      log({ method: req.method, path: req.url, status: 502, ms: Date.now() - started, error: error.code || error.message })
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json; charset=utf-8' })
      res.end(JSON.stringify({ code: 'UPSTREAM_UNAVAILABLE', message: 'backend unreachable', data: null, traceId: null }))
    })

    req.pipe(proxied)
  }
)

server.on('tlsClientError', (error) => log({ event: 'tls_client_error', error: error.code || error.message }))

server.listen(PORT, BIND, () => {
  console.log(JSON.stringify({ listening: `https://${BIND}:${PORT}`, upstream: UPSTREAM, cert: path.basename(CERT) }, null, 2))
})

const shutdown = () => {
  log({ event: 'shutdown' })
  server.close(() => {
    agent.destroy()
    logStream.end(() => process.exit(0))
  })
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
