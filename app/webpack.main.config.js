const SortedModuleChunkIdsPlugin = require('./webpack.chunk-ids')

module.exports = {
  entry: './main.js',
  module: { rules: [] },
  optimization: {
    // REPRODUCIBLE BUILDS: webpack's ModuleConcatenationPlugin (scope hoisting)
    // sorts on a single key with no tiebreaker in two places, so modules at equal
    // depth and configurations of equal size keep whatever order they were visited
    // in. A flipped tie changes which modules get concatenated, which changes
    // module ids and chunk contents between otherwise identical builds.
    concatenateModules: false,
    // REPRODUCIBLE BUILDS: webpack shortcuts re-export chains so an importer binds
    // directly to the terminal module instead of hopping through a barrel/index.
    // Whether that shortcut succeeds depends on module processing order, so the same
    // import can resolve two different ways between builds — changing module ids and
    // the emitted call. Measured at a 15% flip rate before this was disabled. Inert
    // for a trivial app with no re-export barrels, but kept so this repo stays
    // a correct starting template. Cost: weaker tree shaking.
    providedExports: false,
  },
  plugins: [
    // REPRODUCIBLE BUILDS: order-independent chunk ids. See webpack.chunk-ids.js.
    new SortedModuleChunkIdsPlugin(),
  ],
}
