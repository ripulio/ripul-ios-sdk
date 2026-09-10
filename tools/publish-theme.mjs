#!/usr/bin/env node
import { readFile } from 'node:fs/promises';

const [id, file] = process.argv.slice(2);
if (!id || !file || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(id)) {
  console.error('Usage: node tools/publish-theme.mjs <theme-id> <Theme.json>');
  process.exit(1);
}
const token = process.env.RIPUL_ADMIN_TOKEN;
if (!token) {
  console.error('Set RIPUL_ADMIN_TOKEN to a current Ripul admin session token.');
  process.exit(1);
}
try {
  const body = await readFile(file, 'utf8');
  const document = JSON.parse(body);
  if (!document || typeof document !== 'object' || Array.isArray(document)) throw new Error('Theme must be a JSON object');
  if (Buffer.byteLength(body) > 512 * 1024) throw new Error('Theme exceeds 512 KiB');
  const base = process.env.RIPUL_API_URL || 'https://llm-proxy.ripul.io';
  const response = await fetch(new URL(`/admin/app-themes/${id}`, base), {
    method: 'PUT', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body, signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`Publish failed (${response.status}): ${await response.text()}`);
  const result = await response.json();
  console.log(`Published ${id}: ${new URL(result.url, base)} (${result.etag})`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
