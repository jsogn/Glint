# HUD Material Lab

Development-only visual comparison tool for the Glint HUD background.

Run it with a screenshot of the system candidate bar:

```bash
./Tools/HUDMaterialLab/run.sh \
  --reference /path/to/candidate-bar.png
```

The lab shows:

- native AppKit popover, menu, header, and content-background materials;
- `withinWindow` and `behindWindow` blending;
- white tint strengths over popover material;
- regular Liquid Glass on macOS 26 or later;
- white, gray, split, and colorful test backdrops.

`withinWindow` samples the test backdrop inside the lab. `behindWindow`
samples whatever is behind the lab window, so move the lab over different
documents or desktops when checking that mode.

This target is intentionally separate from the app. It is not included in
`Glint.app`.
