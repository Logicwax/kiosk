'use strict'

const { createHash } = require('crypto')

const PLUGIN = 'SortedModuleChunkIdsPlugin'

/**
 * REPRODUCIBLE BUILDS — deterministic chunk ids that do not depend on build order.
 *
 * The problem this fixes
 * ---------------------
 * webpack's built-in `chunkIds: 'deterministic'` derives an *unnamed* chunk's id by
 * hashing an identifier built like this (lib/ids/IdHelpers.js, getFullChunkName):
 *
 *     const modules = chunkGraph.getChunkRootModules(chunk)
 *     return modules.map((m) => makePathsRelative(context, m.identifier())).join()
 *
 * That list is NOT sorted before being joined. For a chunk with more than one root
 * module the join order can differ between builds, which changes the hash input,
 * which changes the chunk id. A changed id renames the emitted file AND rewrites the
 * `__webpack_require__.e(<id>)` call in every chunk that imports it — so two builds
 * of identical sources produce different bytes. That made the .deb, and the OS image
 * built from it, non-reproducible.
 *
 * Note this is NOT a hash collision: webpack does sort the *chunks* before assigning
 * (compareChunksNatural), and that sort is total for distinct chunks. The instability
 * lives inside the identifier string, upstream of the sort.
 *
 * Naming chunks (`/* webpackChunkName *\/`) avoids it, because a named chunk hits the
 * `if (chunk.name) return chunk.name` early return and hashes a fixed string instead.
 * But most chunks here are not ours to name: they are splitChunks output and dynamic
 * imports inside dependencies.
 *
 * How this fixes it
 * -----------------
 * Assign ids in `beforeChunkIds`, i.e. before webpack's own chunk-id plugin runs,
 * deriving each id from a SORTED list of the chunk's module identifiers. webpack's
 * plugin only assigns ids to chunks where `chunk.id === null` and consults
 * getUsedChunkIds(), so anything left over is still handled by it and our ids are
 * never reused. Chunk composition, splitting and load behaviour are untouched — only
 * the ids (and therefore the filenames of unnamed chunks) are affected.
 *
 * We hash the chunk's full module list rather than just its root modules. Root modules
 * keep ids stabler across source edits, which matters for long-term HTTP caching; this
 * app loads its chunks from local disk, so full-module-list is the better trade: it is
 * strictly more discriminating, so two distinct chunks cannot end up with the same
 * identifier and have their ids decided by a tie-break.
 */
class SortedModuleChunkIdsPlugin {
  constructor(options = {}) {
    // 10 digits: wide enough that the probe loop below effectively never runs.
    this.maxLength = options.maxLength || 10
  }

  apply(compiler) {
    compiler.hooks.compilation.tap(PLUGIN, (compilation) => {
      compilation.hooks.beforeChunkIds.tap(PLUGIN, (chunks) => {
        const { chunkGraph } = compilation
        const context = compiler.context
        const range = 10 ** this.maxLength

        // Ids already taken (entry chunks, anything assigned earlier).
        const used = new Set()
        for (const chunk of compilation.chunks) {
          if (chunk.id !== null && chunk.id !== undefined) used.add(String(chunk.id))
        }

        const pending = []
        for (const chunk of chunks) {
          if (chunk.id !== null && chunk.id !== undefined) continue
          pending.push([chunk, chunkIdent(chunk, chunkGraph, context)])
        }

        // Sort by identifier so the assignment order itself cannot depend on the
        // order webpack happened to walk the chunk graph in.
        pending.sort((a, b) => (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0))

        for (const [chunk, ident] of pending) {
          let salt = 0
          let id
          do {
            id = numberHash(`${ident}#${salt++}`, range)
          } while (used.has(String(id)))
          used.add(String(id))
          chunk.id = id
          chunk.ids = [id]
        }
      })
    })
  }
}

/** Stable identity for a chunk: its name if it has one, else its sorted module list. */
function chunkIdent(chunk, chunkGraph, context) {
  if (chunk.name) return `name:${chunk.name}`
  const ids = []
  for (const module of chunkGraph.getChunkModulesIterable(chunk)) {
    ids.push(relativeIdentifier(context, module.identifier()))
  }
  ids.sort()
  return `modules:${ids.join(',')}`
}

/**
 * Module identifiers embed absolute paths (and can contain loader prefixes, e.g.
 * "/abs/loader.js!/abs/file.ts"), so strip the build directory to keep ids stable
 * regardless of where the tree is checked out or built.
 */
function relativeIdentifier(context, identifier) {
  return context ? identifier.split(context).join('.') : identifier
}

function numberHash(str, range) {
  // 6 bytes = 48 bits, comfortably inside Number.MAX_SAFE_INTEGER.
  return createHash('sha256').update(str).digest().readUIntBE(0, 6) % range
}

module.exports = SortedModuleChunkIdsPlugin
