import { defineConfig } from 'vite';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import uiCssHmrPlugin from './vite/csshotreload.plugin.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const localAIPath = path.resolve('/home/kivutar/src/chai-robrowser-drop/AI/USER_AI');
const cyroGrfOrigin = 'https://cyro.live/grf/';
const cyroGrfCachePath = path.resolve(__dirname, '.cache/cyro-grf');

const cacheMimeTypes = {
	'.act': 'application/octet-stream',
	'.bmp': 'image/bmp',
	'.gat': 'application/octet-stream',
	'.gnd': 'application/octet-stream',
	'.jpg': 'image/jpeg',
	'.jpeg': 'image/jpeg',
	'.lua': 'text/plain; charset=utf-8',
	'.lub': 'application/octet-stream',
	'.mp3': 'audio/mpeg',
	'.png': 'image/png',
	'.spr': 'application/octet-stream',
	'.str': 'application/octet-stream',
	'.tga': 'image/targa',
	'.wav': 'audio/wav'
};

function sendFile(res, filePath) {
	const ext = path.extname(filePath).toLowerCase();
	res.setHeader('content-type', cacheMimeTypes[ext] || 'application/octet-stream');
	fs.createReadStream(filePath).pipe(res);
}

function localAIPlugin() {
	return {
		name: 'local-ai-files',
		configureServer(server) {
			server.middlewares.use((req, res, next) => {
				const prefix = '/cyro-grf/AI/USER_AI/';
				const url = req.url?.split('?')[0] || '';
				if (!url.startsWith(prefix)) {
					next();
					return;
				}

				const filename = decodeURIComponent(url.slice(prefix.length));
				const filePath = path.resolve(localAIPath, filename);
				if (filePath !== localAIPath && !filePath.startsWith(`${localAIPath}${path.sep}`)) {
					res.statusCode = 403;
					res.end('Forbidden');
					return;
				}

				fs.readFile(filePath, (error, data) => {
					if (error) {
						next();
						return;
					}

					res.setHeader('content-type', 'text/plain; charset=utf-8');
					res.end(data);
				});
			});
		}
	};
}

function cyroGrfCachePlugin() {
	return {
		name: 'cyro-grf-cache',
		configureServer(server) {
			server.middlewares.use(async (req, res, next) => {
				const prefix = '/cyro-grf/';
				const rawUrl = req.url || '';
				const [urlPath, query = ''] = rawUrl.split('?');

				if (req.method !== 'GET' || !urlPath.startsWith(prefix)) {
					next();
					return;
				}

				const relativeUrl = decodeURIComponent(urlPath.slice(prefix.length));
				const cachePath = path.resolve(cyroGrfCachePath, relativeUrl);
				if (cachePath !== cyroGrfCachePath && !cachePath.startsWith(`${cyroGrfCachePath}${path.sep}`)) {
					res.statusCode = 403;
					res.end('Forbidden');
					return;
				}

				if (fs.existsSync(cachePath) && fs.statSync(cachePath).isFile()) {
					console.info(`[cyro-grf-cache] hit ${relativeUrl}`);
					sendFile(res, cachePath);
					return;
				}

				const remoteUrl = new URL(relativeUrl + (query ? `?${query}` : ''), cyroGrfOrigin);
				console.info(`[cyro-grf-cache] miss ${relativeUrl}`);

				try {
					const response = await fetch(remoteUrl);
					if (!response.ok) {
						res.statusCode = response.status;
						res.end(await response.text());
						return;
					}

					const buffer = Buffer.from(await response.arrayBuffer());
					await fs.promises.mkdir(path.dirname(cachePath), { recursive: true });
					await fs.promises.writeFile(cachePath, buffer);

					const contentType = response.headers.get('content-type');
					if (contentType) {
						res.setHeader('content-type', contentType);
					}
					res.end(buffer);
				} catch (error) {
					console.error(`[cyro-grf-cache] ${relativeUrl}`, error);
					next();
				}
			});
		}
	};
}

export default defineConfig({
	plugins: [localAIPlugin(), cyroGrfCachePlugin(), uiCssHmrPlugin()],
	root: './',
	base: './',
	resolve: {
		alias: {
			'jquery': path.resolve(__dirname, 'src/Vendors/jquery-1.9.1.js'),
			App: path.resolve(__dirname, './src/App'),
			Audio: path.resolve(__dirname, './src/Audio'),
			Controls: path.resolve(__dirname, './src/Controls'),
			Core: path.resolve(__dirname, './src/Core'),
			DB: path.resolve(__dirname, './src/DB'),
			Engine: path.resolve(__dirname, './src/Engine'),
			Loaders: path.resolve(__dirname, './src/Loaders'),
			Network: path.resolve(__dirname, './src/Network'),
			Plugins: path.resolve(__dirname, './src/Plugins'),
			Preferences: path.resolve(__dirname, './src/Preferences'),
			Renderer: path.resolve(__dirname, './src/Renderer'),
			UI: path.resolve(__dirname, './src/UI'),
			Utils: path.resolve(__dirname, './src/Utils'),
			Vendors: path.resolve(__dirname, './src/Vendors')
		}
	},
	test: {
		environment: 'jsdom',
		include: ['tests/**/*.test.js'],
		coverage: {  
			provider: 'v8',  
			reporter: ['text', 'html'],  
			include: ['src/**/*.js'],  
			exclude: ['src/Vendors/**']  
		}
	},
	build: {
		outDir: 'dist/Web',
		rollupOptions: {
			input: {
				main: path.resolve(__dirname, 'index.html')
			}
		}
	},
	server: {
		port: 3000,
		open: true,
		proxy: {  
			'/emblem': {  
				target: 'https://cyro.live/api',
				changeOrigin: true,  
			},  
			'/userconfig': {  
				target: 'https://cyro.live/api',
				changeOrigin: true,  
			},
			'/cyro-grf': {
				target: 'https://cyro.live/grf',
				changeOrigin: true,
				rewrite: proxyPath => proxyPath.replace(/^\/cyro-grf/, '')
			}  
		}
	}
});
