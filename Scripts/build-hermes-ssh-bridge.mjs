import { createRequire } from 'node:module'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readFileSync, writeFileSync } from 'node:fs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = resolve(process.argv[2] || `${process.env.HOME}/.hermes/hermes-agent`)
const require = createRequire(`${source}/package.json`)
const { build } = require('esbuild')
await build({
  entryPoints: [`${root}/Scripts/hermes-ssh-bridge.ts`],
  outfile: `${root}/Sources/Herm/Resources/HermesSSHBridge.mjs`,
  bundle: true, platform: 'node', format: 'esm', target: 'node20', minify: true,
  alias: { '@hermes-desktop': `${source}/apps/desktop/electron` },
  banner: { js: '// Hermes Desktop SSH lifecycle. Copyright (c) 2025 Nous Research. MIT; see HermesSSHBridge.LICENSE.\nimport { createRequire as hermCreateRequire } from "node:module"; const require = hermCreateRequire(import.meta.url);' }
})
writeFileSync(`${root}/Sources/Herm/Resources/HermesSSHBridge.LICENSE`, readFileSync(`${source}/LICENSE`))
