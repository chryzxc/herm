// Builds Herm's Desktop plugin host from a Hermes Desktop checkout, so plugins link against
// Desktop's real `@hermes/plugin-sdk`, React and stylesheet rather than a stand-in.
//   bun Scripts/desktop-plugin-host/build.ts <hermes-agent>/apps/desktop
// Writes Sources/Herm/Resources/DesktopPluginHost/sdk (git-ignored). Never writes into the checkout.
import { cpSync, mkdtempSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import path from 'node:path'

const desktop = path.resolve(process.argv[2] ?? '')
const src = path.join(desktop, 'src')
if (!process.argv[2] || !(await Bun.file(path.join(src, 'sdk/index.ts')).exists())) {
  console.error('usage: bun build.ts <hermes-agent>/apps/desktop')
  process.exit(2)
}
const repo = path.resolve(import.meta.dir, '../..')
const out = path.join(repo, 'Sources/Herm/Resources/DesktopPluginHost/sdk')
const require = createRequire(path.join(desktop, 'package.json'))
const entries = realpathSync(mkdtempSync(path.join(tmpdir(), 'herm-plugin-host-')))

// ── Entries ─────────────────────────────────────────────────────────────────────
// CommonJS packages have no static ESM names, so list them from the real module.
const wrap = (mod: string) => {
  const names = Object.keys(require(mod)).filter(n => n !== 'default' && /^[A-Za-z_$][\w$]*$/.test(n))
  return `import * as M from '${mod}'\nexport default M\nexport const { ${names.join(', ')} } = M\n`
}
writeFileSync(path.join(entries, 'react.ts'), wrap('react'))
writeFileSync(path.join(entries, 'jsx-runtime.ts'), wrap('react/jsx-runtime'))
writeFileSync(path.join(entries, 'react-dom-client.ts'), wrap('react-dom/client'))
writeFileSync(path.join(entries, 'sdk.ts'), `export * from '@/sdk'\n`)
cpSync(path.join(import.meta.dir, 'herm'), entries, { recursive: true })

// ── Bundle with Desktop's own Vite and resolve aliases ──────────────────────────
// Same bundler and aliases as Desktop's renderer build, so `?raw`, `?url`, `import.meta.glob`
// and `@/` behave exactly as in Desktop. (Bun's code splitting dropped declarations here.)
const vite = await import(require.resolve('vite'))
// The `runner` loader evaluates the config in memory instead of writing a temp file beside it.
const loaded = await vite.loadConfigFromFile(
  { command: 'build', mode: 'production' },
  path.join(desktop, 'vite.config.ts'),
  desktop,
  'silent',
  undefined,
  'runner'
)
const input = Object.fromEntries(
  readdirSync(entries)
    .filter(f => /^(sdk|react|jsx-runtime|react-dom-client|bridge|host)\.tsx?$/.test(f))
    .map(f => [f.replace(/\.tsx?$/, ''), path.join(entries, f)])
)
const bundles = await vite.build({
  configFile: false,
  root: entries,
  base: '/sdk/',
  publicDir: false,
  logLevel: 'error', // Desktop's own directive and dynamic-import notes are not Herm's to fix
  mode: 'production',
  resolve: { alias: loaded?.config.resolve?.alias },
  css: { postcss: { plugins: [] } },
  plugins: [
    {
      // Herm's entries live outside the checkout; resolve their packages as Desktop's own files do.
      name: 'herm-entries',
      enforce: 'pre',
      async resolveId(source: string, importer: string | undefined) {
        if (!importer?.startsWith(entries) || /^[./]/.test(source)) return null
        return this.resolve(source, path.join(src, 'main.tsx'), { skipSelf: true })
      }
    }
  ],
  build: {
    outDir: out,
    emptyOutDir: true,
    target: 'safari17',
    modulePreload: false,
    cssCodeSplit: false,
    chunkSizeWarningLimit: 1e9,
    reportCompressedSize: false,
    rolldownOptions: {
      input,
      preserveEntrySignatures: 'strict',
      output: {
        // Desktop's own vendor grouping: tens of chunks instead of one per Shiki grammar.
        advancedChunks: loaded?.config.build?.rolldownOptions?.output?.advancedChunks,
        entryFileNames: '[name].js',
        chunkFileNames: 'chunk-[hash].js',
        assetFileNames: (asset: { names?: string[] }) =>
          asset.names?.some(n => n.endsWith('.css')) ? 'host.css' : 'asset-[hash][extname]'
      }
    }
  }
})
rmSync(entries, { recursive: true, force: true })

// ── Licenses: Hermes Agent's, then every package that ended up in the bundle ────
const packages = new Map<string, string>()
const addPackage = (file: string) => {
  const dir = file.match(/^(.*\/node_modules\/(?:@[^/]+\/)?[^/]+)\//)?.[1]
  if (dir && !packages.has(dir)) packages.set(dir, require(path.join(dir, 'package.json')).name)
}
for (const bundle of [bundles].flat())
  for (const chunk of bundle.output)
    for (const id of Object.keys(chunk.type === 'chunk' ? chunk.modules : {})) addPackage(id)

// ── Stylesheet: Desktop's own Tailwind over Desktop's own source ────────────────
const tailwind = await import(require.resolve('@tailwindcss/node'))
const oxide = await import(
  createRequire(realpathSync(require.resolve('@tailwindcss/node'))).resolve('@tailwindcss/oxide')
)
const compiler = await tailwind.compile(await Bun.file(path.join(src, 'styles.css')).text(), {
  base: src,
  onDependency: () => {}
})
const scanner = new oxide.Scanner({ sources: [{ base: src, pattern: '**/*', negated: false }, ...compiler.sources] })
let css: string = compiler.build(scanner.scan())

// Fonts referenced from the stylesheet ship beside it; anything unresolvable is dropped by WebKit.
const fonts = new Map<string, string>()
css = css.replace(/url\((['"]?)([^'")]+)\1\)/g, (match, _q, ref: string) => {
  if (/^(data:|https?:|#)/.test(ref)) return match
  const bare = ref.split(/[?#]/, 1)[0]
  let file: string | undefined
  for (const base of [src, path.join(src, 'fonts')]) {
    try {
      file = bare.startsWith('.') ? require.resolve(path.join(base, bare)) : require.resolve(bare)
      break
    } catch {}
  }
  if (!file) {
    try {
      file = require.resolve(path.join(path.dirname(require.resolve('katex')), 'fonts', path.basename(bare)))
    } catch {
      try {
        file = path.join(path.dirname(require.resolve('@vscode/codicons/package.json')), 'dist', path.basename(bare))
        if (!Bun.file(file).size) file = undefined
      } catch {}
    }
  }
  if (!file) return match
  const name = `fonts/${path.basename(file)}`
  fonts.set(name, file)
  addPackage(file)
  return `url(./${name})`
})
for (const [name, file] of fonts) cpSync(file, path.join(out, name))
await Bun.write(path.join(out, 'desktop.css'), css)
// Herm draws a plugin's codicon in its sidebar; this map spares it parsing the whole stylesheet.
const codicons = Object.fromEntries(
  [...css.matchAll(/\.codicon-([\w-]+):before\s*\{\s*content:\s*"\\([0-9a-fA-F]+)"/g)].map(m => [m[1], m[2].toLowerCase()])
)
await Bun.write(path.join(out, 'codicons.json'), JSON.stringify(codicons))
const notices = [
  `Hermes Agent (apps/desktop), including its JetBrains Mono fonts (SIL Open Font License 1.1)\n\n` +
    (await Bun.file(path.join(desktop, '../../LICENSE')).text())
]
for (const [dir, name] of [...packages].sort((a, b) => a[1].localeCompare(b[1]))) {
  const file = readdirSync(dir).find(f => /^(licen[cs]e|copying)/i.test(f))
  const { version, license } = require(path.join(dir, 'package.json'))
  notices.push(`${name}@${version} (${license ?? 'see package'})\n\n${file ? await Bun.file(path.join(dir, file)).text() : ''}`)
}
await Bun.write(path.join(out, 'LICENSE'), notices.join(`\n${'─'.repeat(80)}\n\n`))

// ── Manifest: exactly what the built SDK exports, read back from the bundle ─────
const exports = new Bun.Transpiler({ loader: 'js' }).scan(await Bun.file(path.join(out, 'sdk.js')).text()).exports
await Bun.write(
  path.join(repo, 'Sources/Herm/Resources/DesktopPluginHost/sdk-exports.json'),
  JSON.stringify(exports.filter(name => name !== 'default').sort(), null, 2) + '\n'
)
const commit = (await Bun.$`git -C ${desktop} rev-parse HEAD`.text()).trim()
await Bun.write(path.join(out, 'SOURCE'), `Built from Hermes Agent ${commit} (apps/desktop)\n`)

console.log(
  `sdk: ${readdirSync(out, { recursive: true }).length} files, ${exports.length} SDK names, ${fonts.size} fonts, ` +
    `css ${(css.length / 1024).toFixed(0)} KB, from ${commit.slice(0, 10)}`
)
