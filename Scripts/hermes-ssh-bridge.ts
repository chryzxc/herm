// Bundled from Hermes Desktop's MIT-licensed, Electron-free SSH lifecycle.
import { createInterface } from 'node:readline'
import { SshConnection, pickLocalPort, redactSecrets } from '@hermes-desktop/ssh-connection'
import * as posix from '@hermes-desktop/remote-lifecycle'
import { detectRemotePlatform, connectWindowsRemote, terminateOwnedWindowsDashboardForUpdate } from '@hermes-desktop/windows-remote-lifecycle'
import { adoptServedDashboardToken } from '@hermes-desktop/dashboard-token'
import { backendProfileArg } from '@hermes-desktop/profile-id-guard'
import { normalizeSshConfig } from '@hermes-desktop/connection-config'

let ssh: any
let backend: any
let ownershipId: string
const abort = new AbortController()

async function json(base: string, path: string, token: string) {
  const response = await fetch(base + path, { headers: { Authorization: `Bearer ${token}` }, redirect: 'error', signal: AbortSignal.timeout(10_000) })
  if (!response.ok) throw Object.assign(new Error(`Hermes returned HTTP ${response.status}.`), { status: response.status })
  return response.json()
}

async function close() {
  abort.abort()
  if (!ssh) return
  try {
    if (backend?.platform?.os === 'Windows') {
      await terminateOwnedWindowsDashboardForUpdate(ssh, { hermesHome: backend.hermesHome, hermesPath: backend.hermesPath, python: backend.pythonPath }, backend)
    } else {
      await posix.disconnect(ssh, ownershipId)
    }
  } finally { await ssh.close(); ssh = null; backend = null }
}

async function connect(config: any) {
  if (ssh) throw new Error('SSH connection already exists.')
  ownershipId = config.ownershipId
  if (!/^[0-9a-f]{32}$/.test(ownershipId)) throw new Error('Invalid SSH ownership identity.')
  const target = normalizeSshConfig({ ...config, mode: 'ssh', port: config.port === 22 ? undefined : config.port })
  ssh = new SshConnection(target, {
    sshBinary: '/usr/bin/ssh', ownershipId, scope: ownershipId, rememberLog: () => {}
  })
  try {
    await ssh.open({ signal: abort.signal })
    const platform = await detectRemotePlatform(ssh, config.remoteHermesPath || '')
    const lifecycle = platform.os === 'Windows' ? connectWindowsRemote : posix.connect
    backend = await lifecycle({
      ssh, platform, ownershipId, profile: config.remoteProfile || '', remoteHermesPath: config.remoteHermesPath || '',
      forward: (local: number, remote: number) => ssh.forward(local, remote),
      cancelForward: (local: number, remote: number) => ssh.cancelForward(local, remote), pickLocalPort,
      signal: abort.signal, rememberLog: () => {}, adoptServedToken: adoptServedDashboardToken,
      waitForHermes: async (base: string, token: string) => {
        for (let attempt = 0; attempt < 60; attempt++) {
          abort.signal.throwIfAborted()
          try { await json(base, '/api/status', token); return } catch (error) {
            if (attempt === 59 || error.status === 401 || error.status === 403) throw error
            await new Promise(resolve => setTimeout(resolve, 500))
          }
        }
      },
      probeReuseProof: async (base: string, token: string, nonce: string) => {
        try { return posix.classifySshReuseProof(await json(base, '/api/ssh/ownership', token), nonce) }
        catch (error) { if ([401, 403, 404].includes(error.status)) return 'authenticated-stale'; throw error }
      }
    })
    backend.profile = backendProfileArg(config.remoteProfile || '') ?? ''
    return { baseUrl: backend.baseUrl, token: backend.token, version: backend.hermesVersion || '', platform: platform.os }
  } catch (error) { await close().catch(() => {}); throw error }
}

const input = createInterface({ input: process.stdin })
let work = Promise.resolve()
input.on('line', line => {
  work = work.then(async () => {
    let message: any
    try {
      message = JSON.parse(line)
      const result = message.command === 'connect' ? await connect(message.config) : message.command === 'close' ? await close() : (() => { throw new Error('Unsupported SSH command.') })()
      process.stdout.write(JSON.stringify({ id: message.id, result: result || {} }) + '\n')
    } catch (error) {
      process.stdout.write(JSON.stringify({ id: message?.id, error: redactSecrets(String(error.message || 'SSH connection failed.')) }) + '\n')
    }
  })
})
input.on('close', () => { abort.abort(); void work.finally(async () => { await close().catch(() => {}); process.exit() }) })
process.on('SIGTERM', () => { abort.abort(); void close().finally(() => process.exit()) })
