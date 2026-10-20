# Glint Design Assets

`../App/Glint/AppIcon.icon` is the editable Icon Composer source of truth for
the macOS app icon. It uses a white canvas fill with one transparent foreground
layer containing the black mark. Icon Composer and the system apply the icon
shape and appearance treatment.

The mark combines a text insertion caret, three progressively larger points of
light, and one final glint. It represents two ideas at once:

- Glint works beside the native text input cursor.
- Small moments of English learning accumulate into a brighter result.

Render the current macOS preview after changing the source:

```bash
./scripts/render_app_icon_preview.sh
```
