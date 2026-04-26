import { defineConfig } from 'vite';
import type { Plugin } from 'vite';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Wails dev proxies GETs to Vite first; only 404/405 triggers the Go AssetHandler.
 * SPA-style HTML fallback can return 200 + index.html for unknown paths, so we force
 * 404 for these routes so artwork/media always fall through to Go.
 */
function wailsSafeRoutes404(): Plugin {
  return {
    name: 'wails-safe-routes-404',
    enforce: 'pre',
    configureServer(server) {
      const handler = (req: IncomingMessage, res: ServerResponse, next: () => void) => {
        const pathname = req.url?.split('?')[0] ?? '';
        if (pathname.startsWith('/safe-artwork') || pathname.startsWith('/safe-media')) {
          res.statusCode = 404;
          res.end();
          return;
        }
        next();
      };
      // Connect: first layer runs first — prepend so this runs before Vite's HTML fallback.
      const mw = server.middlewares as { stack?: { route: string; handle: typeof handler }[]; use: (fn: typeof handler) => void };
      if (Array.isArray(mw.stack)) {
        mw.stack.unshift({ route: '', handle: handler });
      } else {
        mw.use(handler);
      }
    },
  };
}

export default defineConfig({
  root: __dirname,
  base: './',
  plugins: [wailsSafeRoutes404()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: resolve(__dirname, 'index.html'),
    },
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
