import { app, BrowserWindow, protocol } from 'electron';
import { URL, fileURLToPath } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const cyroGrfOrigin = 'https://cyro.live/grf/';
const cyroAPIOrigin = 'https://cyro.live/api/';
const bundledCyroAIPath = path.join(__dirname, 'AI', 'USER_AI');
const cyroLocalAIPath = path.resolve(process.env.CYRO_AI_PATH || bundledCyroAIPath);

app.commandLine.appendSwitch('enable-webgl');
app.commandLine.appendSwitch('ignore-gpu-blacklist');
app.commandLine.appendSwitch('disable-raf-throttling');
app.commandLine.appendSwitch('disable-gpu-vsync');
app.commandLine.appendSwitch('disable-frame-rate-limit');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

const projectRoot = path.resolve(__dirname, '..', '..');

// MIME types required for ES module loading — Chromium enforces strict
// MIME checking for <script type="module"> and dynamic import().
const MIME_TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.mjs': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json',
	'.png': 'image/png',
	'.jpg': 'image/jpeg',
	'.gif': 'image/gif',
	'.bmp': 'image/bmp',
	'.svg': 'image/svg+xml',
	'.wav': 'audio/wav',
	'.mp3': 'audio/mpeg',
	'.wasm': 'application/wasm',
	'.tga': 'image/targa',
	'.lub': 'application/octet-stream',
	'.lua': 'application/octet-stream',
	'.spr': 'application/octet-stream',
	'.act': 'application/octet-stream',
	'.grf': 'application/octet-stream'
};

function responseFromFile(filePath, request) {
	const data = fs.readFileSync(filePath);
	const ext = path.extname(filePath).toLowerCase();
	const mimeType = MIME_TYPES[ext] || 'application/octet-stream';
	const range = request?.headers.get('range');

	if (range) {
		const match = /^bytes=(\d*)-(\d*)$/.exec(range);
		if (!match) {
			return new Response('Invalid range', { status: 416 });
		}

		let start = match[1] ? Number(match[1]) : 0;
		let end = match[2] ? Number(match[2]) : data.length - 1;

		if (!match[1] && match[2]) {
			const suffixLength = Number(match[2]);
			start = Math.max(data.length - suffixLength, 0);
			end = data.length - 1;
		}

		if (start >= data.length || end >= data.length || start > end) {
			return new Response('Range not satisfiable', {
				status: 416,
				headers: {
					'Content-Range': `bytes */${data.length}`
				}
			});
		}

		const body = data.subarray(start, end + 1);
		return new Response(body, {
			status: 206,
			headers: {
				'Accept-Ranges': 'bytes',
				'Content-Length': String(body.length),
				'Content-Range': `bytes ${start}-${end}/${data.length}`,
				'Content-Type': mimeType
			}
		});
	}

	return new Response(data, {
		headers: {
			'Accept-Ranges': 'bytes',
			'Content-Length': String(data.length),
			'Content-Type': mimeType
		}
	});
}

function isInsidePath(filePath, rootPath) {
	return filePath === rootPath || filePath.startsWith(rootPath + path.sep);
}

function remoteAssetURL(relativePath, search) {
	return new URL(
		relativePath
			.split('/')
			.map(part => encodeURIComponent(part))
			.join('/') + search,
		cyroGrfOrigin
	);
}

async function handleCyroGrfRequest(relativePath, search, request) {
	const assetPath = relativePath.replace(/^cyro-grf\/+/, '');

	if (assetPath.startsWith('AI/USER_AI/')) {
		const localAIFile = path.normalize(path.join(cyroLocalAIPath, assetPath.replace(/^AI\/USER_AI\/+/, '')));
		if (!isInsidePath(localAIFile, cyroLocalAIPath)) {
			return new Response('Forbidden', { status: 403 });
		}
		if (fs.existsSync(localAIFile) && fs.statSync(localAIFile).isFile()) {
			console.info(`[cyro-grf-cache] local AI ${assetPath}`);
			return responseFromFile(localAIFile, request);
		}
	}

	const cacheRoot = path.join(app.getPath('userData'), 'cyro-grf-cache');
	const cachePath = path.normalize(path.join(cacheRoot, assetPath));
	if (!isInsidePath(cachePath, cacheRoot)) {
		return new Response('Forbidden', { status: 403 });
	}

	if (fs.existsSync(cachePath) && fs.statSync(cachePath).isFile()) {
		console.info(`[cyro-grf-cache] hit ${assetPath}`);
		return responseFromFile(cachePath, request);
	}

	const remoteUrl = remoteAssetURL(assetPath, search);
	console.info(`[cyro-grf-cache] miss ${assetPath}`);

	const response = await fetch(remoteUrl);
	if (!response.ok) {
		return new Response(await response.text(), { status: response.status });
	}

	const buffer = Buffer.from(await response.arrayBuffer());
	fs.mkdirSync(path.dirname(cachePath), { recursive: true });
	fs.writeFileSync(cachePath, buffer);

	return responseFromFile(cachePath, request);
}

async function handleCyroAPIRequest(relativePath, request) {
	const remoteUrl = new URL(relativePath, cyroAPIOrigin);
	const headers = new Headers(request.headers);
	headers.delete('host');
	headers.delete('origin');

	const init = {
		method: request.method,
		headers
	};

	if (request.method !== 'GET' && request.method !== 'HEAD') {
		init.body = Buffer.from(await request.arrayBuffer());
	}

	const response = await fetch(remoteUrl, init);
	const buffer = Buffer.from(await response.arrayBuffer());
	const contentType = response.headers.get('content-type');

	return new Response(buffer, {
		status: response.status,
		headers: contentType ? { 'Content-Type': contentType } : undefined
	});
}

// Register custom protocol so ES modules work without CORS issues.
// file:// blocks <script type="module"> imports; app:// serves them
// with a proper origin and correct MIME types.
protocol.registerSchemesAsPrivileged([
	{
		scheme: 'app',
		privileges: {
			standard: true,
			secure: true,
			supportFetchAPI: true,
			corsEnabled: true
		}
	}
]);

function createWindow() {
	const win = new BrowserWindow({
		title: 'CyRO',
		width: 1024,
		height: 768,
		fullscreen: false,
		frame: true,
		icon: path.join(__dirname, 'icon.png'),
		webPreferences: {
			preload: path.join(__dirname, 'preload.mjs'),
			contextIsolation: true,
			nodeIntegration: false,
			nodeIntegrationInWorker: true,
			sandbox: false
		}
	});

	win.webContents.on('console-message', (_event, level, message, line, sourceId) => {
		console.log(`[renderer:${level}] ${message} (${sourceId}:${line})`);
	});
	win.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
		console.error(`[renderer:load-failed] ${errorCode} ${errorDescription} ${validatedURL}`);
	});
	win.on('page-title-updated', event => {
		event.preventDefault();
		win.setTitle('CyRO');
	});

	if (process.argv.includes('--dev')) {
		process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = 'true';
		win.loadURL('http://localhost:3000/applications/electron/cyro-ai.html');
		win.webContents.openDevTools();
	} else {
		win.loadURL('app://localhost/applications/electron/cyro-ai.html');
	}

	win.on('close', () => {
		app.exit(0);
	});
}

app.whenReady().then(() => {
	// Also emulates Vite's ?raw suffix: when a module imports e.g.
	// './Intro.html?raw', we return a JS module that exports the file
	// content as a string (instead of serving raw HTML/CSS which Chromium
	// rejects as non-JS MIME for module scripts).
	// Handle app:// requests by reading local files with correct MIME types.
	protocol.handle('app', request => {
		const url = new URL(request.url);
		const isRaw = url.searchParams.has('raw');
		const isUrl = url.searchParams.has('url');
		const relativePath = decodeURIComponent(url.pathname).replace(/^\/+/, '');
		const filePath = path.normalize(path.join(projectRoot, relativePath));

		if (relativePath.startsWith('cyro-grf/')) {
			try {
				return handleCyroGrfRequest(relativePath, url.search, request);
			} catch (e) {
				console.error(`[app://] CyRO cache error: ${request.url} →`, e);
				return new Response(e.message, { status: 500 });
			}
		}

		if (relativePath.startsWith('userconfig/') || relativePath.startsWith('emblem/')) {
			try {
				return handleCyroAPIRequest(relativePath, request);
			} catch (e) {
				console.error(`[app://] CyRO API error: ${request.url} →`, e);
				return new Response(e.message, { status: 500 });
			}
		}

		// Prevent path traversal outside project root
		if (!isInsidePath(filePath, projectRoot)) {
			console.error(`[app://] Forbidden (path traversal): ${request.url} → ${filePath}`);
			return new Response('Forbidden', { status: 403 });
		}

		try {
			if (!fs.existsSync(filePath)) {
				console.error(`[app://] 404: ${request.url} → ${filePath}`);
				return new Response('Not Found', { status: 404 });
			}

			const data = fs.readFileSync(filePath);

			// ?url → wrap the underlying file URL in a JS module (Vite compat)
			if (isUrl) {
				const assetUrl = `app://localhost/${relativePath}`;
				const js = `export default ${JSON.stringify(assetUrl)};`;
				return new Response(js, {
					headers: { 'Content-Type': 'text/javascript' }
				});
			}

			// ?raw → wrap file content in a JS module (Vite compat)
			if (isRaw) {
				const text = data.toString('utf-8');
				const escaped = JSON.stringify(text);
				const js = `export default ${escaped};`;
				return new Response(js, {
					headers: { 'Content-Type': 'text/javascript' }
				});
			}

			const ext = path.extname(filePath).toLowerCase();
			const mimeType = MIME_TYPES[ext] || 'application/octet-stream';
			let body = data;

			// Transform JS files to resolve bare specifiers (roBrowser aliases)
			if (mimeType === 'text/javascript' && !isRaw) {
				let content = data.toString('utf8');
				content = content.replace(
					/from\s+['"](Core|Loaders|Utils|Network|DB|Renderer|UI|App|Audio|Controls|Plugins|Preferences|Engine|Vendors)\/(.*?)['"]/g,
					"from '/src/$1/$2'"
				);
				content = content.replace(/from\s+['"]jquery['"]/g, "from '/src/Vendors/jquery-1.9.1.js'");
				body = Buffer.from(content);
			}

			return new Response(body, {
				headers: { 'Content-Type': mimeType }
			});
		} catch (e) {
			console.error(`[app://] Error: ${request.url} →`, e);
			return new Response(e.message, { status: 500 });
		}
	});

	createWindow();
});

app.on('window-all-closed', () => {
	if (process.platform !== 'darwin') {
		app.quit();
		// Fallback: force exit if quit takes too long
		setTimeout(() => process.exit(0), 1000);
	}
});

app.on('activate', () => {
	if (BrowserWindow.getAllWindows().length === 0) {
		createWindow();
	}
});
