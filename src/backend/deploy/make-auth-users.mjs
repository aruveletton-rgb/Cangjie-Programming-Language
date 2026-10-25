#!/usr/bin/env node
// Generates the credential spec consumed by ICT_AUTH_USERS / ICT_AUTH_FILE.
//
// Why a generator: the server stores only salted SHA-256 digests, so an operator
// cannot type a password into a config file. Hand-computing digests is where mistakes
// and plaintext leaks happen, so this script does it and refuses to write anything
// until the caller has supplied explicit account details.
//
// Usage:
//   node src/backend/deploy/make-auth-users.mjs --out auth-users.json \
//     --user worker1:staff:campus-demo:worker-syn-campus-001:SYN_CAMPUS_A \
//     --user student1:student:campus-demo:user-syn-campus-001:SYN_CAMPUS_A
//
// Passwords are read from ICT_AUTH_PASSWORD_<USERNAME> environment variables, never
// from argv (argv is visible in process listings and shell history).
//
// Output shape:
//   { "generatedAt": "...", "users": [ { username, salt, passwordHash, userId, domain, role, area } ] }
// The plaintext password is never written, echoed, or logged.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const specs = []
let outPath = ''

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--out') { outPath = args[++i]; continue }
  if (args[i] === '--user') { specs.push(args[++i]); continue }
  throw new Error(`Unknown argument: ${args[i]}`)
}

if (!outPath) throw new Error('Missing --out <file>')
if (specs.length === 0) throw new Error('At least one --user is required')

const ROLES = new Set(['student', 'resident', 'staff'])
const users = []

for (const spec of specs) {
  const parts = spec.split(':')
  if (parts.length !== 5) {
    throw new Error(`--user must be username:role:domain:userId:area (got ${spec})`)
  }
  const [username, role, domain, userId, area] = parts
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(username)) throw new Error(`Invalid username: ${username}`)
  if (!ROLES.has(role)) throw new Error(`Role must be one of ${[...ROLES].join(', ')}: ${role}`)

  const envKey = `ICT_AUTH_PASSWORD_${username.toUpperCase().replace(/[^A-Z0-9]/g, '_')}`
  const password = process.env[envKey]
  if (!password || password.length < 8) {
    throw new Error(`${envKey} must be set to a password of at least 8 characters`)
  }

  const salt = crypto.randomBytes(16).toString('hex')
  const passwordHash = crypto.createHash('sha256').update(salt + password, 'utf8').digest('hex')
  users.push({ username, salt, passwordHash, userId, domain, role, area })
}

const payload = {
  generatedAt: new Date().toISOString(),
  note: 'passwordHash = sha256(salt + password). Plaintext passwords are never stored.',
  users,
}

fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true })
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n', 'utf8')

// Restrictive mode where the platform supports it; harmless elsewhere.
try { fs.chmodSync(outPath, 0o600) } catch { /* ignore */ }

console.log(JSON.stringify({
  written: path.resolve(outPath),
  users: users.map((u) => ({ username: u.username, role: u.role, domain: u.domain, userId: u.userId })),
  containsPlaintextPassword: false,
}))
