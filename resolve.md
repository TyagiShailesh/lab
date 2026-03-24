# DaVinci Resolve

Mac (editing) sends render jobs to Linux (lab, 192.168.1.10) with RTX 6000.
Resolve sends render instructions, not media — both machines need the same file paths and a shared PostgreSQL database.

**Requirements:** DaVinci Resolve Studio (same version, same plugins/LUTs/fonts on both machines).

---

## Linux Setup

### DaVinci Resolve Studio 20.3.2

Installed at `/opt/resolve`. Cannot launch until NVIDIA driver is installed.

### Xorg + VNC

Xorg installed (no desktop environment). TigerVNC for one-time Resolve config.
Connect from Mac: `vnc://lab:5901` (password: resolve)

### Resolve config (one-time, via VNC)

```bash
vncserver :1 -localhost no -geometry 1920x1080
# Connect from Mac: vnc://lab:5901
DISPLAY=:1 /opt/resolve/bin/resolve
```

In Resolve on Linux:
- Preferences → Memory & GPU → CUDA, select RTX 6000
- Preferences → Media Storage → add `/Volumes/media/video`
- Preferences → Media Storage → cache: `/cache/resolve`
- Connect to PostgreSQL (192.168.1.10, user: resolve)
- Workspace → Remote Rendering → Enable

Kill VNC after:

```bash
vncserver -kill :1
```

### Render service

```bash
systemctl enable --now resolve-render.service
```

---

## Mac Resolve Config

### Working Folders

| Setting | Path |
|---|---|
| Project media location | `/Volumes/media/resolve` |
| Proxy generation location | `/Volumes/media/resolve/ProxyMedia` |
| Cache files location | `/Users/st/DaVinci/CacheClip` |
| Gallery stills location | `/Volumes/media/resolve/.gallery` |

### Color Management (Studio Display XDR, 2000 nits peak)

| Setting | Value |
|---|---|
| Color science | DaVinci YRGB Color Managed |
| Input color space | Canon Cinema Gamut / Canon Log 3 (R5C) |
| Timeline color space | DaVinci WG/Intermediate |
| Working luminance | 2000 nits |
| Output color space | Rec.709 (Scene) for SDR, P3-D65 ST.2084 for HDR |
| Limit output gamut | P3-D65 |
| Input/Output DRT | DaVinci |

HDR and SDR delivery from the same timeline — override output color space per render job in the Deliver page.

---

## Remote Render Workflow

1. Open project on Mac → Deliver page
2. Set output format
3. Add job to Render Queue
4. Select the Linux render node
5. Start render

Mac stays responsive. All effects (NR, color, Fusion, ResolveFX) render on the RTX 6000.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Render node not visible | Same network? Same DB? Restart Resolve on both |
| Media offline on render node | Path mismatch — check `/Volumes/media` symlink |
| Resolve won't start on Linux | DISPLAY=:1 set? Xorg running? NVIDIA driver loaded? |
| glib errors on Ubuntu | Move Resolve's bundled glib to `/opt/resolve/libs/disabled/` |
| SSD thermal throttling | Ensure M.2 heatsinks installed |
