// Loads one Desktop plugin (`/plugin/plugin.js`, served from its folder by Herm) with Desktop's
// own plugin context, provider tree and SDK, and renders its page. Herm only replaces the seams
// where Desktop would reach its own window: the gateway, toasts, chat opening and navigation.
import { QueryClientProvider } from '@tanstack/react-query'
import { Component, type ReactNode, Suspense, useEffect } from 'react'
import { createRoot } from 'react-dom/client'
import { HashRouter, useLocation } from 'react-router'

import { contributedRoutes } from '@/app/routes'
import { HapticsProvider } from '@/components/haptics-provider'
import { RootTooltipProvider } from '@/components/ui/tooltip'
import { emitGatewayEvent } from '@/contrib/events'
import { createPluginContext, declaredCapabilities } from '@/contrib/plugin'
import { useContributions } from '@/contrib/react/use-contributions'
import { ProfileI18nProvider } from '@/i18n/profile-provider'
import { queryClient } from '@/lib/query-client'
import { host, ROUTES_AREA } from '@/sdk'
import { $gateway } from '@/store/gateway'
import { $notifications, dismissNotification } from '@/store/notifications'
import { ThemeProvider } from '@/themes/context'

import { call, onGatewayEvent, post } from './bridge'

type GatewayEvent = Parameters<typeof emitGatewayEvent>[0]
type Listener = (event: GatewayEvent) => void

// ── Gateway: Herm's own Hermes connection behind Desktop's client shape ─────────
const gatewayListeners = new Map<string, Set<Listener>>()
const subscribe = (type: string, listener: Listener) => {
  const set = gatewayListeners.get(type) ?? new Set()
  gatewayListeners.set(type, set)
  set.add(listener)
  return () => void set.delete(listener)
}
const noop = () => () => undefined

onGatewayEvent(event => {
  const typed = event as GatewayEvent
  emitGatewayEvent(typed)
  for (const key of [event.type, '*']) gatewayListeners.get(key)?.forEach(listener => listener(typed))
})

// Herm owns the socket; this only answers the members Desktop code reads.
$gateway.set({
  connectionState: 'open',
  request: (method: string, params: Record<string, unknown> = {}) => call('request', { method, params }),
  on: subscribe,
  onAny: (listener: Listener) => subscribe('*', listener),
  onEvent: (listener: Listener) => subscribe('*', listener),
  onRequest: noop,
  onState: noop,
  close: () => undefined,
  invalidate: () => undefined,
  getSeqWatermarks: () => ({}),
  sessionReplayBarrier: () => undefined
} as unknown as Parameters<typeof $gateway.set>[0])

// ── Host doors that would drive Desktop's own window ────────────────────────────
type ProfileRoute = string | { profile?: string } | null | undefined
const routeProfile = (route: ProfileRoute) => (typeof route === 'string' ? route : route?.profile) || undefined

Object.assign(host, {
  requestProfile: (route: ProfileRoute, method: string, params: Record<string, unknown> = {}) =>
    call('request', { method, params, profile: routeProfile(route) }),
  openSession: (storedSessionId: string) => call('openSession', { id: storedSessionId }),
  navigate: (path: string) => {
    window.location.hash = `#${path.startsWith('#') ? path.slice(1) : path}`
  }
})

// Desktop toasts land in Herm's header instead of a toast stack Herm does not draw.
const shown = new Set<string>()
$notifications.subscribe(list => {
  for (const notice of list) {
    if (shown.has(notice.id)) continue
    shown.add(notice.id)
    const message = [notice.title, notice.message].filter(Boolean).join(': ')
    if (message) post('notify', { message, error: notice.kind === 'error' })
    queueMicrotask(() => dismissNotification(notice.id))
  }
})

// ── Page ────────────────────────────────────────────────────────────────────────
class Boundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() {
    return { failed: true }
  }
  componentDidCatch(error: unknown) {
    post('status', { state: 'failed', message: String((error as Error)?.message ?? error) })
  }
  render() {
    return this.state.failed ? null : this.props.children
  }
}

function Page({ home }: { home: string }) {
  const routes = contributedRoutes(useContributions(ROUTES_AREA))
  const { pathname } = useLocation()
  const route = routes.find(candidate => candidate.path === pathname)
  useEffect(() => post('status', { state: 'ready' }), [])
  useEffect(() => {
    if (route) return
    // Desktop pages Herm does not have (settings, chats) stay in Desktop.
    post('notify', { message: 'That page is only in Hermes Desktop.', error: false })
    window.location.replace(`#${home}`)
  }, [route, home])
  return route ? <Suspense fallback={null}>{route.render()}</Suspense> : null
}

function PluginRoot({ children }: { children: ReactNode }) {
  return (
    <QueryClientProvider client={queryClient}>
      <ProfileI18nProvider>
        <ThemeProvider>
          <HapticsProvider>
            <RootTooltipProvider>
              <HashRouter>{children}</HashRouter>
            </RootTooltipProvider>
          </HapticsProvider>
        </ThemeProvider>
      </ProfileI18nProvider>
    </QueryClientProvider>
  )
}

try {
  const pluginID = window.__hermPluginID
  // A runtime specifier: the bundler must not try to resolve the plugin.
  const entry = '/plugin/plugin.js'
  const plugin = (await import(entry)).default
  if (typeof plugin?.register !== 'function') throw new Error('The plugin has no register function.')
  await plugin.register(createPluginContext(pluginID, undefined, declaredCapabilities(plugin)))
  const home = contributedRoutes()[0]?.path
  if (!home) throw new Error('The plugin registered no page.')
  if (!window.location.hash) window.location.replace(`#${home}`)
  createRoot(document.getElementById('root')!).render(
    <Boundary>
      <PluginRoot>
        <Page home={home} />
      </PluginRoot>
    </Boundary>
  )
} catch (error) {
  post('status', { state: 'failed', message: String((error as Error)?.message ?? error) })
}
