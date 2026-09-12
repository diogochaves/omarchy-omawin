import { execFileSync, spawn } from 'node:child_process'
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
      DOCKER_STATE: 'active',
      WEB_CODE: '000',
      ...extra
    }
  }).replace(/\n$/, '')
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
