// https://inst.linux.yun on Cloudflare Workers. Every file is a static asset
// (dist/, built by tools/build-site.mjs); only "/" reaches this code (see
// assets.run_worker_first in wrangler.jsonc), so that the short commands
//   curl -fsSL https://inst.linux.yun | sh
//   irm https://inst.linux.yun | iex
// get the matching entry script while browsers get the landing page.

/** Entry script for a User-Agent, or null for browsers (landing page). */
export function entryFor(userAgent) {
  const ua = userAgent || '';
  // Windows PowerShell 5.1 sends "WindowsPowerShell/5.1...", PowerShell 7 "PowerShell/7...".
  if (/PowerShell\//i.test(ua)) return '/install.ps1';
  if (/^Mozilla\//.test(ua)) return null;
  return '/install.sh'; // curl, wget, fetch, empty User-Agent, ...
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const root = url.pathname === '/';
    const entry = root ? entryFor(request.headers.get('User-Agent')) : null;
    const asset = await env.ASSETS.fetch(entry ? new Request(new URL(entry, url), request) : request);
    if (!root) return asset;
    const response = new Response(asset.body, asset);
    response.headers.append('Vary', 'User-Agent');
    if (entry) {
      response.headers.set('Content-Type', 'text/plain; charset=utf-8');
      response.headers.set('X-Content-Type-Options', 'nosniff');
    }
    return response;
  },
};
