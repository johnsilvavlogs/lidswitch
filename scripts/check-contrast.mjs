import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const css = readFileSync(join(root, 'site/styles.css'), 'utf8');
const MIN_NORMAL_TEXT_CONTRAST = 4.5;

function hexToRgb(hex) {
  const clean = hex.trim().replace('#', '');
  if (!/^[0-9a-f]{6}$/i.test(clean)) {
    throw new Error(`Invalid hex color: ${hex}`);
  }

  return [0, 2, 4].map((offset) => parseInt(clean.slice(offset, offset + 2), 16) / 255);
}

function channelToLinear(value) {
  return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
}

function relativeLuminance(hex) {
  const [red, green, blue] = hexToRgb(hex).map(channelToLinear);
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrastRatio(foreground, background) {
  const foregroundLum = relativeLuminance(foreground);
  const backgroundLum = relativeLuminance(background);
  const lighter = Math.max(foregroundLum, backgroundLum);
  const darker = Math.min(foregroundLum, backgroundLum);
  return (lighter + 0.05) / (darker + 0.05);
}

function assertContrast(label, foreground, background, minimum = MIN_NORMAL_TEXT_CONTRAST) {
  const ratio = contrastRatio(foreground, background);
  if (ratio < minimum) {
    throw new Error(
      `${label} contrast ${ratio.toFixed(2)} is below ${minimum}: ${foreground} on ${background}`
    );
  }
}

function rootVariable(name) {
  const match = css.match(new RegExp(`--${name}:\\s*(#[0-9a-fA-F]{6})\\s*;`));
  if (!match) {
    throw new Error(`Missing CSS variable --${name}`);
  }
  return match[1].toLowerCase();
}

function block(selector) {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = css.match(new RegExp(`${escaped}\\s*\\{([\\s\\S]*?)\\}`));
  if (!match) {
    throw new Error(`Missing CSS block: ${selector}`);
  }
  return match[1];
}

function property(cssBlock, name) {
  const match = cssBlock.match(new RegExp(`${name}:\\s*([^;]+);`));
  if (!match) {
    throw new Error(`Missing CSS property ${name}`);
  }
  return match[1].trim();
}

function resolveColor(value) {
  const trimmed = value.trim().toLowerCase();
  if (trimmed === 'white') return '#ffffff';
  const variable = trimmed.match(/^var\(--([a-z0-9-]+)\)$/);
  if (variable) return rootVariable(variable[1]);
  if (/^#[0-9a-f]{6}$/i.test(trimmed)) return trimmed;
  throw new Error(`Unsupported color value: ${value}`);
}

const cream = rootVariable('cream');
const cream2 = rootVariable('cream-2');
const green = rootVariable('green');
const greenDark = rootVariable('green-dark');
const buttonPrimary = block('.button-primary');
const buttonText = resolveColor(property(buttonPrimary, 'color'));
const buttonBackgroundStops = property(buttonPrimary, 'background').match(/#[0-9a-fA-F]{6}/g) || [];
const ribbon = block('.launch-ribbon');
const ribbonText = resolveColor(property(ribbon, 'color'));

if (buttonBackgroundStops.length < 2) {
  throw new Error('Primary button background must include at least two explicit hex stops.');
}

for (const stop of buttonBackgroundStops) {
  assertContrast('Primary CTA text', buttonText, stop.toLowerCase());
}

assertContrast('Eyebrow text on white', greenDark, '#ffffff');
assertContrast('Eyebrow text on cream', greenDark, cream);
assertContrast('Eyebrow text on cream-2', greenDark, cream2);
assertContrast('Ribbon text on white', ribbonText, '#ffffff');
assertContrast('Ribbon text on light green ribbon', ribbonText, '#e8f9e8');
assertContrast('Step number text', '#ffffff', green);

console.log('contrast check ok');
