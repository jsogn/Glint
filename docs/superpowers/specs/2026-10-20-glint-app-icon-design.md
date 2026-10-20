# Glint App Icon Design

## Direction

The primary mark is a black geometric symbol on a white Icon Composer canvas.
The black symbol is an independent transparent layer so macOS can apply the
system icon shape and appearance treatment without wrapping the artwork in a
second Dock container:

- a text insertion caret identifies the native input context;
- three progressively larger points represent repeated, small learning moments;
- a final four-point glint represents accumulated understanding.

The composition is optically centered rather than centered by individual
element bounds. It contains no text, gradient, shadow, or 3D effect.

## Production Assets

- `App/Glint/AppIcon.icon` is the editable Icon Composer source.
- `App/Glint/AppIcon.icon/Assets/glint-mark.svg` is the transparent foreground.
- `scripts/render_app_icon_preview.sh` renders the current macOS preview.

## Small-Size Rule

The 16px and 32px exports keep the original silhouette. Future menu bar artwork
may use a simplified monochrome variant, but it is a separate asset from the
App icon.

## Constraints

- Keep the white canvas fill and separate black foreground layer.
- Do not bake a rounded-square mask into the foreground artwork.
- Do not add words, letters, stars, neural-network imagery, or AI sparkle
  clusters.
