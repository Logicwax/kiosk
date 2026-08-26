const MiniCssExtractPlugin = require('mini-css-extract-plugin')
const SortedModuleChunkIdsPlugin = require('./webpack.chunk-ids')

module.exports = {
  module: {
    rules: [
      {
        test: /\.css$/,
        // CSS is EXTRACTED to a real file rather than injected by style-loader:
        // index.html sets `style-src 'self'`, which blocks the inline <style>
        // tags style-loader creates. Extracting keeps the CSP strict.
        use: [MiniCssExtractPlugin.loader, 'css-loader'],
      },
    ],
  },
  optimization: {
    // See webpack.main.config.js — scope hoisting is not order-independent.
    concatenateModules: false,
    // REPRODUCIBLE BUILDS: webpack shortcuts re-export chains so an importer binds
    // directly to the terminal module instead of hopping through a barrel/index.
    // Whether that shortcut succeeds depends on module processing order, so the same
    // import can resolve two different ways between builds — changing module ids and
    // the emitted call. Measured at a 15% flip rate before this was disabled. Inert
    // for a trivial app with no re-export barrels, but kept so this repo stays a correct
    // starting template. Cost: weaker tree shaking.
    providedExports: false,
  },
  plugins: [
    new MiniCssExtractPlugin(),
    // REPRODUCIBLE BUILDS: order-independent chunk ids. See webpack.chunk-ids.js.
    new SortedModuleChunkIdsPlugin(),
  ],
}
