import { execFileSync, spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
export const root = path.resolve(import.meta.dirname, '..')
export const fixtures = path.join(root, 'tests/fixtures')

// The QML libs are ".pragma library" files with no module system, the same
// shape chaves.sysmon's tests evaluate. Strip the pragma and run the rest as a
// function body, so the tested source is byte for byte the source QML imports
// and the values it returns are ordinary host objects.
export function load(relative) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8')
    .replace(/^\.pragma library\n/, '')
  const names = [...source.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)]
    .map(match => match[1])
  return new Function(source + '\nreturn {' + names.join(',') + '}')()
}

// The guest disk every fixture carries: 64 GiB of nothing. tests/fixtures/
// generate.sh makes it with truncate and .gitignore keeps it out of the repo
// (git would store all 64 GiB of zeros), so it is created here on demand — a
// fresh clone must not need the generator to run the sampler.
export const DATA_IMAGE_BYTES = 64 * 1024 * 1024 * 1024

export function dataImage(name, bytes = DATA_IMAGE_BYTES) {
  const file = path.join(fixtures, name, 'data.img')
  let size = -1
  try {
    size = fs.statSync(file).size
  } catch {
    size = -1
  }
  if (size !== bytes) {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, '')
    fs.truncateSync(file, bytes)
  }
  return file
}

// Runs the real helpers/vm-state.sh against tests/fixtures/<name>/, with every
// root it reads pointed inside the fixture. DOCKER_STATE and WEB_CODE stand in
// for the two forks so the tests need neither systemd nor a listening port.
export function vmState(name, extra = {}) {
  const dir = path.join(fixtures, name)
  return execFileSync('/bin/bash', ['helpers/vm-state.sh'], {
    cwd: root, encoding: 'utf8', env: {
      ...process.env,
      PROC_ROOT: path.join(dir, 'proc'),
      SYS_ROOT: path.join(dir, 'sys'),
      COMPOSE_FILE: path.join(dir, 'docker-compose.yml'),
      CREDENTIALS_FILE: path.join(dir, 'credentials'),
      DATA_IMAGE: dataImage(name),
      DOCKER_STATE: 'active',
      WEB_CODE: '000',
      ...extra
    }
  }).replace(/\n$/, '')
}

// Runs any of the helpers and hands back both streams and the status, because
// the two configuration helpers say what they refused on stderr and that text
// is what ends up on the card. Never throws on a non-zero status: a refusal is
// what most of these tests are about.
export function helper(script, args = [], env = {}, input = undefined) {
  const result = spawnSync('/bin/bash', [path.join('helpers', script), ...args], {
    cwd: root, encoding: 'utf8', input,
    env: { ...process.env, LC_ALL: 'C', ...env }
  })
  return {
    status: result.status,
    out: (result.stdout || '').replace(/\n$/, ''),
    err: (result.stderr || '').replace(/\n$/, '')
  }
}

// Runs the real helpers/rdp-probe.sh and resolves to its exit status. It has
// to be async: the test servers answer from this very event loop, so a
// blocking spawnSync would deadlock against the probe waiting for a reply.
export function rdpProbe(port, extra = {}) {
  const child = spawn('/bin/bash', ['helpers/rdp-probe.sh'], {
    cwd: root, stdio: 'ignore', env: {
      ...process.env, RDP_HOST: '127.0.0.1', RDP_PORT: String(port), ...extra
    }
  })
  return new Promise((resolve, reject) => {
    child.on('error', reject)
    child.on('close', code => resolve(code))
  })
}
