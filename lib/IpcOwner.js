.pragma library

// Who answers `omarchy-shell chaves.omawin …` (primary, open, status…).
//
// Quickshell keeps one IpcHandler per target. One registered while another
// holds the target is ignored for good, and when the holder goes the target
// goes with it ("Target not found"). Every monitor's bar builds its own
// instance of the widget, and a container widget (omarchy-console's rail) can
// host one more, so the first instance used to own the target and the key
// binding died with that monitor's bar. Every instance queues here instead,
// in the one copy of this library the shell's engine shares, and the first
// live one owns the target. When it leaves, the next one is told, and takes
// the target once the old handler is gone. The same scheme as omaseed's.

var queue = []

function alive(widget) {
  try {
    return widget !== null && widget !== undefined && widget.moduleName !== undefined
  } catch (e) {
    return false
  }
}

function elect() {
  queue = queue.filter(alive)
  for (var i = 0; i < queue.length; i++) queue[i].ipcElected(i === 0)
}

function join(widget) {
  if (queue.indexOf(widget) === -1) queue.push(widget)
  elect()
}

function leave(widget) {
  var i = queue.indexOf(widget)
  if (i !== -1) queue.splice(i, 1)
  elect()
}

function first() {
  queue = queue.filter(alive)
  return queue.length > 0 ? queue[0] : null
}
