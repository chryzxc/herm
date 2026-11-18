// The page's only door to Herm: a closed set of ops answered by DesktopPluginBridge.swift.
// Herm replies through window.__herm.reply and pushes events and theme through __herm.event and
// __herm.theme. Loaded as its own module before host.js so `window.hermesDesktop` exists before
// any Desktop module reads it.
import { BROWSER_BRIDGE_STUBS } from '@/lib/browser-bridge-stubs'
import type { HermesApiRequest } from '@/global'

type Pending = { resolve: (value: unknown) => void; reject: (error: Error) => void }
type GatewayEvent = { type: string; payload?: unknown; session_id?: string }

declare global {
  interface Window {
    __hermPluginID: string
    __herm: {
      reply(id: number, ok: boolean, value: unknown): void
      event(event: GatewayEvent): void
      theme(vars: Record<string, string>): void
    }
    webkit: { messageHandlers: { herm: { postMessage(message: string): void } } }
  }
}

const pending = new Map<number, Pending>()
const listeners = new Set<(event: GatewayEvent) => void>()
let nextID = 0

export function call<T = unknown>(op: string, args: Record<string, unknown> = {}): Promise<T> {
  const id = ++nextID
  return new Promise<T>((resolve, reject) => {
    pending.set(id, { resolve: resolve as (value: unknown) => void, reject })
    window.webkit.messageHandlers.herm.postMessage(JSON.stringify({ id, op, args }))
  })
}

let settled = false

/** Fire-and-forget op (status reports, notices). */
export function post(op: string, args: Record<string, unknown> = {}) {
  if (op === 'status') settled = true
  window.webkit.messageHandlers.herm.postMessage(JSON.stringify({ id: 0, op, args }))
}

// Until the page reports, an uncaught error (such as host.js failing to link) is the reason it
// never will. Afterwards a plugin's stray errors stay in its console. Rejections are left alone:
// host.js catches its own, and Desktop's background ones are not fatal.
const failEarly = (error: unknown) => {
  if (!settled) post('status', { state: 'failed', message: String((error as Error)?.message ?? error) })
}
window.addEventListener('error', event => failEarly(event.error ?? event.message))

/** Gateway events, shaped like Desktop's `{ type, session_id, payload }`. */
export function onGatewayEvent(listener: (event: GatewayEvent) => void) {
  listeners.add(listener)
  return () => void listeners.delete(listener)
}

window.__herm = {
  reply(id, ok, value) {
    const waiting = pending.get(id)
    if (!waiting) return
    pending.delete(id)
    if (ok) waiting.resolve(value)
    else waiting.reject(new Error(String(value)))
  },
  event(event) {
    for (const listener of [...listeners]) {
      try {
        listener(event)
      } catch (error) {
        console.error(error)
      }
    }
  },
  // Herm's skin as `!important` custom properties: they outlast Desktop's ThemeProvider, which
  // repaints its own seeds inline whenever its mode resolves.
  theme(vars) {
    let style = document.getElementById('herm-theme')
    if (!style) {
      style = document.createElement('style')
      style.id = 'herm-theme'
      document.head.append(style)
    }
    const rules = Object.entries(vars).map(([name, value]) => `${name}:${value} !important;`)
    style.textContent = `:root{${rules.join('')}}`
  }
}

/** The plugin's own REST namespace, `/api/plugins/<id>/…`; Herm re-confines the suffix natively. */
function api(request: HermesApiRequest): Promise<unknown> {
  // Desktop's pluginRest builds this prefix from the raw id.
  const prefix = `/api/plugins/${window.__hermPluginID}`
  const path = String(request.path ?? '')
  if (path !== prefix && !path.startsWith(`${prefix}/`) && !path.startsWith(`${prefix}?`)) {
    return Promise.reject(new Error(`${path.split('?', 1)[0]} is not available in Herm.`))
  }
  if (request.upload) return Promise.reject(new Error('File uploads are not available in Herm.'))
  return call('rest', { path: path.slice(prefix.length) || '/', method: request.method ?? 'GET', body: request.body ?? null })
}

// Desktop's own browser-host answers for native-only members, plus what Herm really provides.
// Members left undefined are the ones Desktop already feature-tests with `?.`.
window.hermesDesktop = {
  ...BROWSER_BRIDGE_STUBS,
  api,
  selectSavePath: options => call<null | string>('pickSavePath', options ?? {}),
  writeClipboard: async text => {
    try {
      await navigator.clipboard.writeText(String(text))
      return true
    } catch {
      return false
    }
  },
  // Herm's web view hands http(s) windows to the default browser.
  openExternal: async url => {
    window.open(url, '_blank')
  }
} as unknown as Window['hermesDesktop']
