# Fonts

Inter (Regular, Medium, SemiBold) and JetBrains Mono NL Regular, subset to
Latin plus the symbols the page uses (⌘ ⌥ ⇧ ⌫ · × —) and packed as woff2 from the
TTFs the app bundles in `app/NeuralSheet/Resources/Fonts`. Licences: Inter-LICENSE.txt,
JetBrainsMono-OFL.txt (both OFL 1.1).

To regenerate after adding a character the subset lacks:

```sh
pip install fonttools brotli
pyftsubset ../../../app/NeuralSheet/Resources/Fonts/Inter-Regular.ttf \
  --unicodes="U+0000-00FF,U+0152-0153,U+2000-206F,U+2190-2193,U+2212,U+21E7,U+2318,U+2325,U+232B" \
  --layout-features='*' --flavor=woff2 --no-hinting --output-file=Inter-Regular.woff2
```
