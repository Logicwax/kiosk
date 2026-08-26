// electron-forge drives webpack, and maker-deb produces the .deb that the OS image
// installs. maker-deb also does two things by itself that would otherwise need
// fixing up by hand downstream — it installs to /usr/lib/<name>/ with
// a /usr/bin/<name> symlink, and it ships chrome-sandbox as setuid root (4755),
// without which Electron FATALs at launch.
module.exports = {
  packagerConfig: { asar: true },
  makers: [{ name: '@electron-forge/maker-deb', config: {} }],
  plugins: [
    {
      name: '@electron-forge/plugin-webpack',
      config: {
        mainConfig: './webpack.main.config.js',
        renderer: {
          config: './webpack.renderer.config.js',
          entryPoints: [
            {
              html: './src/index.html',
              js: './src/renderer.js',
              name: 'main_window',
            },
          ],
        },
      },
    },
  ],
}
