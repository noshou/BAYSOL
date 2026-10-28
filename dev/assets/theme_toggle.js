// SPDX-License-Identifier: LGPL-3.0-or-later

// A navbar button that flips between the light and the dark theme: a sun in the light
// theme, a crescent moon in the dark one (the icon shows the theme you are in).
// It stores the choice the way Documenter's settings menu does (`documenter-theme` in
// localStorage) and lets Documenter's own `set_theme_from_local_storage` (themeswap.js)
// swap the stylesheets, so the menu and the button always agree. The icon is an inline
// SVG drawn in `currentColor` with no background, so it takes the navbar's link colour
// in both themes.
(function () {
  var SVG_OPEN = '<svg viewBox="0 0 24 24" width="1.15em" height="1.15em" aria-hidden="true">';
  // A radius-9 disc with a radius-8.4 disc cut out of its upper right (a mask, so the
  // background stays transparent): the crescent is 4 units wide at its thickest.
  var MOON =
    SVG_OPEN +
    '<mask id="docs-moon-cut"><rect width="24" height="24" fill="#fff"/>' +
    '<circle cx="14.5" cy="9.5" r="8.4" fill="#000"/></mask>' +
    '<circle cx="12" cy="12" r="9" fill="currentColor" mask="url(#docs-moon-cut)"/></svg>';
  var SUN =
    SVG_OPEN +
    '<circle cx="12" cy="12" r="4.2" fill="currentColor"/>' +
    '<path stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    'd="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8' +
    'M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/></svg>';

  function icon() {
    return isDark() ? MOON : SUN;
  }

  function isDark() {
    var cls = document.documentElement.className;
    if (cls.indexOf("theme--") !== -1) return cls.indexOf("dark") !== -1;
    return window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function toggle(ev) {
    ev.preventDefault();
    var next = isDark() ? "documenter-light" : "documenter-dark";
    try {
      window.localStorage.setItem("documenter-theme", next);
    } catch (e) {}
    set_theme_from_local_storage();
    ev.currentTarget.setAttribute("aria-pressed", String(isDark()));
    ev.currentTarget.innerHTML = icon();
  }

  document.addEventListener("DOMContentLoaded", function () {
    var settings = document.getElementById("documenter-settings-button");
    if (!settings) return;
    var button = document.createElement("a");
    button.className = "docs-navbar-link docs-theme-toggle";
    button.href = "#";
    button.title = "Toggle light/dark theme";
    button.setAttribute("role", "button");
    button.setAttribute("aria-label", "Toggle light/dark theme");
    button.setAttribute("aria-pressed", String(isDark()));
    button.innerHTML = icon();
    button.addEventListener("click", toggle);
    settings.parentNode.insertBefore(button, settings);
  });
})();
