// The stylesheet for alteri.one.
//
// Colour is carried by `raw` rather than by Jaspr's typed CSS bindings. That is
// deliberate: the typed bindings cover `display` and `padding` well and have no binding
// at all for `border-bottom`, `text-decoration` on a link, `overflow-x` or
// `letter-spacing`, which is most of what separates a page from a wall of text.
//
// One light theme. `css.media` in the pinned Jaspr exposes screen width and height
// queries only, so `prefers-color-scheme` is not reachable from here; a dark scheme is a
// recorded follow-up rather than a class nothing toggles.
//
// `package:jaspr/dom.dart` re-exports the styling API (`css`, `StyleRule`, `Styles`,
// `MediaQuery`) and the unit extensions, so this is the only import needed.

import 'package:jaspr/dom.dart';

final List<StyleRule> siteStyles = [
  css('*').styles(raw: {'box-sizing': 'border-box'}),
  css('body').styles(
    raw: {
      'margin': '0 auto',
      'max-width': '46rem',
      'padding': '2.5rem 1.5rem 4rem',
      'background': '#FBFBF9',
      'color': '#14181F',
      'font-family': 'ui-sans-serif, system-ui, -apple-system, sans-serif',
      'font-size': '17px',
      'line-height': '1.65',
      '-webkit-font-smoothing': 'antialiased',
    },
  ),
  css('a').styles(raw: {'color': _accent}),
  css('h1').styles(
    raw: {
      'font-size': '2.4rem',
      'line-height': '1.15',
      'letter-spacing': '-0.02em',
      'margin': '0 0 0.75rem',
    },
  ),
  css('h2').styles(
    raw: {
      'font-size': '1.25rem',
      'margin': '2.5rem 0 0.5rem',
      'padding-bottom': '0.4rem',
      'border-bottom': '1px solid $_rule',
    },
  ),
  css('p').styles(raw: {'margin': '0.75rem 0'}),
  css('p.lede').styles(raw: {'font-size': '1.2rem', 'color': _muted}),
  css('code').styles(
    raw: {
      'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
      'font-size': '0.88em',
      'background': _code,
      'padding': '0.15em 0.35em',
      'border-radius': '4px',
    },
  ),
  css('pre').styles(
    raw: {
      'background': _code,
      'border': '1px solid $_rule',
      'padding': '1rem',
      'border-radius': '8px',
      'overflow-x': 'auto',
      'line-height': '1.45',
    },
  ),
  css(
    'pre code',
  ).styles(raw: {'background': 'none', 'padding': '0', 'font-size': '0.85rem'}),
  css('.callout').styles(
    raw: {
      'border-left': '3px solid $_accent',
      'background': _code,
      'padding': '0.75rem 1rem',
      'border-radius': '0 6px 6px 0',
      'margin': '1.5rem 0',
    },
  ),
  css('.callout p').styles(raw: {'margin': '0'}),
  css('footer').styles(
    raw: {
      'border-top': '1px solid $_rule',
      'margin-top': '3.5rem',
      'padding-top': '1.25rem',
      'color': _muted,
      'font-size': '0.9rem',
    },
  ),
  css.media(MediaQuery.screen(maxWidth: 30.rem), [
    css('h1').styles(raw: {'font-size': '1.9rem'}),
    css('body').styles(raw: {'padding': '1.5rem 1rem 3rem'}),
  ]),
];

// String constants rather than a Color, because every use here is a `raw` value and a
// colour written once is a colour that cannot drift.
const _muted = '#5A6472';
const _code = '#F2F2EE';
const _rule = '#DDDCD6';
const _accent = '#2F6F4F';
