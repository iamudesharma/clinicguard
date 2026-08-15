# Exposing the backend to your phone

Only the **FastAPI token endpoint** needs to be reachable from the app. The LiveKit
agent connects **outbound** to LiveKit Cloud, so it needs no tunnel at all.

## Same Wi-Fi (development, simplest)

Run the backend on your Mac and point the app at its LAN IP:

```bash
uv run uvicorn api.main:app --host 0.0.0.0 --port 8000
flutter run --dart-define=API_BASE_URL=http://<your-mac-lan-ip>:8000
```

## Cloudflare Tunnel (free, stable URL — recommended for demos)

Install `cloudflared` (brew install cloudflared), then:

```bash
cloudflared tunnel --url http://localhost:8000
```

Copy the `https://<random>.trycloudflare.com` URL and run the app with:

```bash
flutter run --dart-define=API_BASE_URL=https://<random>.trycloudflare.com
```

The tunnel URL changes on restart; for a persistent URL use a named tunnel
(`cloudflared tunnel create clinicguard` + route DNS).

## Ngrok (alternative)

```bash
ngrok http 8000
```

Free tier: random URL per session, 40 connections/min — fine for a demo.

## Security notes

- The `/token` endpoint has no auth in this demo — anyone with the URL can mint
  room tokens. Fine for a personal demo; add a Supabase JWT check before
  production.
- Run the tunnel only during the demo, or restrict with Cloudflare Access.
